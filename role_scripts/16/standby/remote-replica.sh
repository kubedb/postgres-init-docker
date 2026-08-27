#!/usr/bin/env bash

# Copyright AppsCode Inc. and Contributors
#
# Licensed under the AppsCode Free Trial License 1.0.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://github.com/appscode/licenses/raw/1.0.0/AppsCode-Free-Trial-1.0.0.md
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export PASSWORD
set -eou pipefail
export PRIMARY_PORT=${PRIMARY_PORT:-5432}

echo "Running as Remote Replica"

# ---------------------------------------------------------------------------
# Upstream selection: cascading replication for a multi-replica remote replica.
#
# Ordinal 0 is the only pod that talks to the external source. Every other pod
# streams from ordinal 0 instead, so exactly one base backup and one WAL stream
# cross the WAN to the client's database rather than one per replica.
#
# The topology is also the one we want after cutover: promoting ordinal 0 turns
# the existing cascade into an ordinary primary-with-standbys tree, with no
# re-seed of the followers.
# ---------------------------------------------------------------------------
POD_ORDINAL="${HOSTNAME##*-}"
UPSTREAM_HOST="$PRIMARY_HOST"
UPSTREAM_PORT="$PRIMARY_PORT"
UPSTREAM_USER="$PRIMARY_USER_NAME"
UPSTREAM_PASSWORD="${PRIMARY_PASSWORD:-}"
UPSTREAM_SSL="${SOURCE_SSL:-OFF}"
UPSTREAM_SSL_MODE="${SOURCE_SSL_MODE:-disable}"
UPSTREAM_TLS_DIR="/tls/certs/remote"

if [[ "${REPLICAS:-1}" -gt 1 && "$POD_ORDINAL" != "0" ]]; then
    PETSET_BASE="${HOSTNAME%-*}"
    # GOVERNING_SERVICE_DNS is supplied by the operator; the fallback keeps this
    # script working against an operator that predates it.
    UPSTREAM_HOST="${PETSET_BASE}-0.${GOVERNING_SERVICE_DNS:-${PETSET_BASE}-pods.${NAMESPACE}.svc}"
    UPSTREAM_PORT="5432"
    # Ordinal 0's catalog is a byte copy of the source's, so the credentials the
    # operator gave us -- which must match the source's -- authenticate there too.
    UPSTREAM_USER="${POSTGRES_USER:-postgres}"
    UPSTREAM_PASSWORD="${POSTGRES_PASSWORD:-}"
    # Peer-to-peer inside the cluster presents our own certs, not the source's.
    UPSTREAM_SSL="${SSL:-OFF}"
    UPSTREAM_SSL_MODE="${SSL_MODE:-disable}"
    UPSTREAM_TLS_DIR="/tls/certs/client"
    echo "cascade: ordinal $POD_ORDINAL follows $UPSTREAM_HOST:$UPSTREAM_PORT (not the external source)"
else
    echo "cascade: ordinal $POD_ORDINAL follows the external source $UPSTREAM_HOST:$UPSTREAM_PORT"
fi

# set password ENV
export PGPASSWORD=${UPSTREAM_PASSWORD:-}

# Waiting for running Postgres
while true; do
    echo "Attempting pg_isready on primary"

    if [[ "${UPSTREAM_SSL:-0}" == "ON" ]]; then
        pg_isready --host="$UPSTREAM_HOST" --port="$UPSTREAM_PORT" -d "sslmode=$UPSTREAM_SSL_MODE sslrootcert=${UPSTREAM_TLS_DIR}/ca.crt sslcert=${UPSTREAM_TLS_DIR}/client.crt sslkey=${UPSTREAM_TLS_DIR}/client.key" --username=$UPSTREAM_USER --timeout=2 &>/dev/null && break
    else
        pg_isready --host="$UPSTREAM_HOST" --port="$UPSTREAM_PORT" --username=$UPSTREAM_USER --timeout=2 &>/dev/null && break
    fi
    sleep 2
done

while true; do
    echo "Attempting query on primary"
    if [[ "${UPSTREAM_SSL:-0}" == "ON" ]]; then
        psql -h "$UPSTREAM_HOST" -p "$UPSTREAM_PORT" --username=$UPSTREAM_USER -d "dbname=postgres sslmode=$UPSTREAM_SSL_MODE sslrootcert=${UPSTREAM_TLS_DIR}/ca.crt sslcert=${UPSTREAM_TLS_DIR}/client.crt sslkey=${UPSTREAM_TLS_DIR}/client.key" --command="select now();" &>/dev/null && break
    else
        psql -h "$UPSTREAM_HOST" -p "$UPSTREAM_PORT" --username=$UPSTREAM_USER -d postgres --no-password --command="select now();" &>/dev/null && break
    fi

    sleep 2
done

if [[ ! -e "$PGDATA/PG_VERSION" ]]; then
      pv_df_output=$(cat /proc/mounts)
      # Ensure /var/pv is actually mounted (present in df output)
      pv_mounted=false
      while IFS= read -r line; do
        last_field=$(echo "$line" | awk '{print $2}')
        if [[ "$last_field" == "/var/pv" ]]; then
          pv_mounted=true
          break
        fi
      done <<< "$pv_df_output"
      if [[ "$pv_mounted" != "true" ]]; then
          echo "ERROR: /var/pv is not mounted (not listed in df)."
          exit 1
      fi
    # Ensure the mountpoint is accessible
    if ! ls /var/pv >/dev/null 2>&1; then
        echo "ERROR: /var/pv is not accessible."
        exit 1
    fi
    echo "taking base basebackup..."
    mkdir -p "$PGDATA"
    rm -rf "$PGDATA"/*
    chmod 0700 "$PGDATA"
    BASEBACKUP=pg_basebackup
    [[ "${TDE_ENABLED:-false}" == "true" ]] && BASEBACKUP=pg_tde_basebackup
    echo "pg_tde: seeding standby with '$BASEBACKUP' (TDE_ENABLED=${TDE_ENABLED:-false})"
    if [[ "${UPSTREAM_SSL:-0}" == "ON" ]]; then
        "$BASEBACKUP" -Xs --pgdata "$PGDATA" --username=$UPSTREAM_USER --progress --host="$UPSTREAM_HOST" --port="$UPSTREAM_PORT" -d "sslmode=$UPSTREAM_SSL_MODE sslrootcert=${UPSTREAM_TLS_DIR}/ca.crt sslcert=${UPSTREAM_TLS_DIR}/client.crt sslkey=${UPSTREAM_TLS_DIR}/client.key"
    else
        "$BASEBACKUP" -Xs --no-password --pgdata "$PGDATA" --username=$UPSTREAM_USER --progress --host="$UPSTREAM_HOST" --port="$UPSTREAM_PORT"
    fi

    # pg_basebackup copies the upstream's postgresql.auto.conf verbatim, and
    # Postgres reads that file AFTER postgresql.conf -- so anything ALTER
    # SYSTEM'd upstream silently overrides the recovery configuration written
    # below, including the primary_conninfo and primary_slot_name an external
    # manager such as repmgr or patroni leaves there. We pass no -R, so nothing
    # we depend on lives in that file: start from empty.
    if [[ -s "$PGDATA/postgresql.auto.conf" ]]; then
        echo "clearing inherited postgresql.auto.conf; it contained:"
        sed 's/^/  | /' "$PGDATA/postgresql.auto.conf"
    fi
    : >"$PGDATA/postgresql.auto.conf"
fi

# setup postgresql.conf
touch /tmp/postgresql.conf

if [[ "${TUNING_ENABLED:-}" == "true" ]]; then
  echo "include_if_exists = '${TUNING_FILE_PATH:-/etc/config/pgtune.conf}'" >>/tmp/postgresql.conf
fi

echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
echo "max_replication_slots = 90" >>/tmp/postgresql.conf
# echo "wal_keep_size = 64" >>/tmp/postgresql.conf #it was  "wal_keep_segments" in earlier version. changed in version 13
if [ ! -z "${WAL_RETAIN_PARAM:-}" ] && [ ! -z "${WAL_RETAIN_AMOUNT:-}" ]; then
    echo "${WAL_RETAIN_PARAM}=${WAL_RETAIN_AMOUNT}" >>/tmp/postgresql.conf
else
  echo "wal_keep_size = 2560" >>/tmp/postgresql.conf
fi
if [[ "$WAL_LIMIT_POLICY" == "ReplicationSlot" ]]; then
  CLEAN_HOSTNAME="${HOSTNAME//[^[:alnum:]]/}"
  echo "primary_slot_name = "$CLEAN_HOSTNAME"" >>/tmp/postgresql.conf
fi

echo "wal_log_hints = on" >>/tmp/postgresql.conf

# we are not doing any archiving by default but it's better to have this config in our postgresql.conf file in case of customization.
echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf

PRELOAD="pg_stat_statements"
if [[ "${TDE_ENABLED:-false}" == "true" ]]; then
    PRELOAD="${TDE_EXTENSION:-pg_tde},${PRELOAD}"
fi
echo "shared_preload_libraries = '${PRELOAD}'" >>/tmp/postgresql.conf
if [[ "${TDE_ENABLED:-false}" == "true" ]]; then
    [[ "${TDE_ENCRYPT_WAL:-false}" == "true" ]] && echo "pg_tde.wal_encrypt = on" >>/tmp/postgresql.conf
    [[ "${TDE_ENFORCE:-false}" == "true" ]] && echo "pg_tde.enforce_encryption = on" >>/tmp/postgresql.conf
    [[ "${TDE_DEFAULT_AM:-false}" == "true" ]] && echo "default_table_access_method = tde_heap" >>/tmp/postgresql.conf
    echo "pg_tde.cipher = '${TDE_CIPHER:-aes_128}'" >>/tmp/postgresql.conf
fi

if [ "$STANDBY" == "hot" ]; then
    echo "hot_standby = on" >>/tmp/postgresql.conf
else
    echo "hot_standby = off" >>/tmp/postgresql.conf
fi

if [[ "$STREAMING" == "synchronous" ]]; then
    # setup synchronous streaming replication
    echo "synchronous_commit = remote_write" >>/tmp/postgresql.conf
    echo "synchronous_standby_names = '*'" >>/tmp/postgresql.conf
fi

if [[ "${SSL:-0}" == "ON" ]]; then
    echo "ssl = on" >>/tmp/postgresql.conf

    echo "ssl_cert_file = '/tls/certs/server/server.crt'" >>/tmp/postgresql.conf
    echo "ssl_key_file = '/tls/certs/server/server.key'" >>/tmp/postgresql.conf
    echo "ssl_ca_file = '/tls/certs/server/ca.crt'" >>/tmp/postgresql.conf
fi

if [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
    echo "password_encryption = scram-sha-256" >>/tmp/postgresql.conf
fi

# ****************** Recovery config **************************
echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
# primary_conninfo is used for streaming replication
if [[ "${UPSTREAM_SSL:-0}" == "ON" ]]; then
    echo "primary_conninfo = 'application_name=$HOSTNAME host=$UPSTREAM_HOST port=$UPSTREAM_PORT user=$UPSTREAM_USER password=$UPSTREAM_PASSWORD sslmode=$UPSTREAM_SSL_MODE sslrootcert=${UPSTREAM_TLS_DIR}/ca.crt sslcert=${UPSTREAM_TLS_DIR}/client.crt sslkey=${UPSTREAM_TLS_DIR}/client.key'" >>/tmp/postgresql.conf
else
    echo "primary_conninfo = 'application_name=$HOSTNAME host=$UPSTREAM_HOST port=$UPSTREAM_PORT user=$UPSTREAM_USER password=$UPSTREAM_PASSWORD'" >>/tmp/postgresql.conf
fi

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

touch "$PGDATA/standby.signal"

# setup pg_hba.conf
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>/tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>/tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>/tmp/pg_hba.conf

if [[ "${SSL:-0}" == "ON" ]]; then
    if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
        #*******************client auth with client.crt and key**************

        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 cert clientcert=verify-full'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 cert clientcert=verify-full'; } >>/tmp/pg_hba.conf

        # KubeDB: user-supplied pg_hba rules (configSecret key: user_hba.conf).
        # They go before the catch-all rules below (pg_hba.conf is first-match-wins)
        # and after the local/loopback rules above, so custom rules can override the
        # defaults but cannot lock out the operator's own scripts.
        # include_if_exists (PostgreSQL 16+): secret updates apply on config reload.
        { echo 'include_if_exists "/etc/config/user_hba.conf"'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
    elif [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        # KubeDB: user-supplied pg_hba rules (configSecret key: user_hba.conf).
        # They go before the catch-all rules below (pg_hba.conf is first-match-wins)
        # and after the local/loopback rules above, so custom rules can override the
        # defaults but cannot lock out the operator's own scripts.
        # include_if_exists (PostgreSQL 16+): secret updates apply on config reload.
        { echo 'include_if_exists "/etc/config/user_hba.conf"'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
    else
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        # KubeDB: user-supplied pg_hba rules (configSecret key: user_hba.conf).
        # They go before the catch-all rules below (pg_hba.conf is first-match-wins)
        # and after the local/loopback rules above, so custom rules can override the
        # defaults but cannot lock out the operator's own scripts.
        # include_if_exists (PostgreSQL 16+): secret updates apply on config reload.
        { echo 'include_if_exists "/etc/config/user_hba.conf"'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    md5'; } >>/tmp/pg_hba.conf
    fi

else
    if [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             127.0.0.1/32            trust'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        { echo 'local        replication     all                                     scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             127.0.0.1/32            scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        # KubeDB: user-supplied pg_hba rules (configSecret key: user_hba.conf).
        # They go before the catch-all rules below (pg_hba.conf is first-match-wins)
        # and after the local/loopback rules above, so custom rules can override the
        # defaults but cannot lock out the operator's own scripts.
        # include_if_exists (PostgreSQL 16+): secret updates apply on config reload.
        { echo 'include_if_exists "/etc/config/user_hba.conf"'; } >>/tmp/pg_hba.conf

        { echo 'host         all             all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
    else
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             127.0.0.1/32            trust'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::1/128                 trust'; } >>/tmp/pg_hba.conf

        { echo 'local        replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        # KubeDB: user-supplied pg_hba rules (configSecret key: user_hba.conf).
        # They go before the catch-all rules below (pg_hba.conf is first-match-wins)
        # and after the local/loopback rules above, so custom rules can override the
        # defaults but cannot lock out the operator's own scripts.
        # include_if_exists (PostgreSQL 16+): secret updates apply on config reload.
        { echo 'include_if_exists "/etc/config/user_hba.conf"'; } >>/tmp/pg_hba.conf

        { echo 'host         all             all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        ::/0                    md5'; } >>/tmp/pg_hba.conf
    fi

fi

mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"
exec postgres
