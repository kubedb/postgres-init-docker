#!/bin/bash

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

BOOTSTRAP=${1}

# setup postgresql.conf
touch /tmp/postgresql.conf

if [[ "${TUNING_ENABLED:-}" == "true" ]]; then
  echo "include_if_exists = '${TUNING_FILE_PATH:-/etc/config/pgtune.conf}'" >>/tmp/postgresql.conf
fi

echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

# echo "wal_keep_size = 2560" >>/tmp/postgresql.conf
if [ ! -z "${WAL_RETAIN_PARAM:-}" ] && [ ! -z "${WAL_RETAIN_AMOUNT:-}" ]; then
    echo "${WAL_RETAIN_PARAM}=${WAL_RETAIN_AMOUNT}" >>/tmp/postgresql.conf
else
  echo "wal_keep_size = 2560" >>/tmp/postgresql.conf
fi

echo "wal_log_hints = on" >>/tmp/postgresql.conf
echo "max_replication_slots = 90" >>/tmp/postgresql.conf
# we are not doing any archiving by default but it's better to have this config in our postgresql.conf file in case of customization.
echo "archive_mode = always" >>/tmp/postgresql.conf
if [[ "${WAL_BACKUP_TYPE:-0}" == "WALG" ]]; then
    echo "archive_command = 'cp %p /var/pv/wal_archive/%f'" >>/tmp/postgresql.conf
else
    echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf
fi

PRELOAD="pg_stat_statements"
if [[ "${TDE_ENABLED:-false}" == "true" ]]; then
    PRELOAD="${TDE_EXTENSION:-pg_tde},${PRELOAD}"
fi
echo "shared_preload_libraries = '${PRELOAD}'" >>/tmp/postgresql.conf

if [[ "${SSL:-0}" == "ON" ]]; then
    echo "ssl =on" >>/tmp/postgresql.conf
    echo "ssl_cert_file ='/tls/certs/server/server.crt'" >>/tmp/postgresql.conf
    echo "ssl_key_file ='/tls/certs/server/server.key'" >>/tmp/postgresql.conf
    echo "ssl_ca_file ='/tls/certs/server/ca.crt'" >>/tmp/postgresql.conf
fi

if [[ "$CLIENT_AUTH_MODE" == "md5" ]]; then
    echo "password_encryption = md5" >>/tmp/postgresql.conf
fi

if [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
    echo "password_encryption = scram-sha-256" >>/tmp/postgresql.conf
fi

# ****************** Recovery config **************************
echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
# primary_conninfo is used for streaming replication
CONNINFO_DBNAME=""
if [[ "$WAL_LIMIT_POLICY" == "ReplicationSlot" ]]; then
    CONNINFO_DBNAME=" dbname=postgres"
fi

if [[ "${SSL:-0}" == "ON" ]]; then
    if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
        echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key$CONNINFO_DBNAME'" >>/tmp/postgresql.conf
    else
        echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt$CONNINFO_DBNAME'" >>/tmp/postgresql.conf
    fi
else
    echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD$CONNINFO_DBNAME'" >>/tmp/postgresql.conf
fi

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

# setup pg_hba.conf for initial start. this one is just for initialization
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>/tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>/tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>/tmp/pg_hba.conf
{ echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
{ echo 'host         all             all             127.0.0.1/32            trust'; } >>/tmp/pg_hba.conf
mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

# start postgres
pg_ctl -D "$PGDATA" -w start

export POSTGRES_USER=${POSTGRES_USER:-postgres}
export POSTGRES_DB=${POSTGRES_DB:-$POSTGRES_USER}
export POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-postgres}

psql=(psql -v ON_ERROR_STOP=1)

# If standby.signal is present, postgres started in recovery above (this node was a standby being
# promoted). Promote it NOW to fork a NEW timeline BEFORE any write below. This is essential for the
# remote-replica -> standalone-HA transition: without promoting from recovery the node comes up on
# the SAME timeline as its former source cluster, which on failback forces a full pg_basebackup
# instead of pg_rewind. Promotion ends recovery, increments the timeline, and removes standby.signal.
# A normal primary start (no standby.signal) skips this block, so fresh bootstrap and the live-standby
# fast-failover path (which promotes via the coordinator, not start.sh) are unaffected.
if [[ -f "/var/pv/data/standby.signal" ]]; then
    echo "standby.signal present -> promoting to fork a new timeline before writes"
    pg_ctl -D "$PGDATA" promote || true
    # Wait until recovery has ended using pg_controldata (no DB connection / role dependency, so a
    # missing or renamed superuser role can never stall this loop). State goes from
    # "in archive recovery" to "in production" once promotion completes.
    for _ in $(seq 1 120); do
        state=$(pg_controldata "$PGDATA" 2>/dev/null | grep "Database cluster state" | sed 's/.*:[[:space:]]*//')
        if [[ "$state" == "in production" ]]; then
            echo "promotion complete; node is now primary on a new timeline"
            break
        fi
        sleep 1
    done
fi

# create database with specified name
if [ "$POSTGRES_DB" != "postgres" ]; then
    "${psql[@]}" --username postgres <<-EOSQL
CREATE DATABASE "$POSTGRES_DB" ;
EOSQL
    echo
fi

if [ "$POSTGRES_USER" = "postgres" ]; then
    op="ALTER"
else
    op="CREATE"
fi

if [[ -f "/var/pv/data/standby.signal" ]];then
  rm /var/pv/data/standby.signal
fi

# alter postgres superuser
"${psql[@]}" --username postgres <<-EOSQL
    BEGIN;
    SET LOCAL synchronous_commit TO OFF;
    $op USER "$POSTGRES_USER" WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';
    COMMIT;
EOSQL
echo

psql+=(--username "$POSTGRES_USER" --dbname "$POSTGRES_DB")
echo

# pg_tde principal-key bootstrap. Runs once on first initialization, after the
# database and superuser exist and before any encrypted table or the
# default_table_access_method flip can be used. Idempotent on retries.
if [[ "${TDE_ENABLED:-false}" == "true" && "${BOOTSTRAP}" == "true" ]]; then
    # Run every pg_tde key operation in this block at the configured cipher. The
    # post-bootstrap config that carries pg_tde.cipher is not loaded yet, so without
    # this the principal key would be created (and validated) at the wrong length.
    export PGOPTIONS="-c pg_tde.cipher=${TDE_CIPHER:-aes_128}"
    # tde_bootstrap_fatal aborts a failed first-time TDE bootstrap loudly. This runs
    # only during initial initialization (BOOTSTRAP=true), so there is no user data
    # yet; wipe the half-initialized data dir and exit non-zero. That forces a full
    # re-bootstrap on the next start instead of falling through to a keyless boot
    # (which would silently disable encryption). The pod crash-loops visibly until
    # the key provider is reachable.
    tde_bootstrap_fatal() {
        echo "pg_tde FATAL: $1"
        pg_ctl -D "$PGDATA" -m immediate -w stop || true
        rm -rf "${PGDATA:?}"/* || true
        exit 1
    }
    # Enable the extension in the default databases. template1 makes it the
    # default for future databases.
    for TDE_DB in template1 "$POSTGRES_DB"; do
        psql -U postgres -d "$TDE_DB" -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS ${TDE_EXTENSION:-pg_tde};
SQL
    done

    # Register the key provider (global preferred; file is standalone only).
    case "${TDE_PROVIDER_KIND:-}" in
        vault)
            # pg_tde_add_global_key_provider_vault_v2 has a 5-arg form and a 6-arg
            # form that also takes a Vault Enterprise namespace. Pass the namespace
            # (spec.tde.keyProvider.vault.namespace -> TDE_VAULT_NAMESPACE) only when
            # it is set, so the common namespace-less case keeps the 5-arg form; the
            # namespace was otherwise accepted in the CRD but silently dropped here.
            if [[ -n "${TDE_VAULT_NAMESPACE:-}" ]]; then
                psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                    "SELECT pg_tde_add_global_key_provider_vault_v2('${TDE_PROVIDER_NAME}','${TDE_VAULT_ADDR}','${TDE_VAULT_MOUNT}','${TDE_VAULT_TOKEN_PATH}','${TDE_VAULT_CA_PATH}','${TDE_VAULT_NAMESPACE}');" || true
            else
                psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                    "SELECT pg_tde_add_global_key_provider_vault_v2('${TDE_PROVIDER_NAME}','${TDE_VAULT_ADDR}','${TDE_VAULT_MOUNT}','${TDE_VAULT_TOKEN_PATH}','${TDE_VAULT_CA_PATH}');" || true
            fi
            ;;
        kmip)
            psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                "SELECT pg_tde_add_global_key_provider_kmip('${TDE_PROVIDER_NAME}','${TDE_KMIP_ADDR}',${TDE_KMIP_PORT},'${TDE_KMIP_CLIENT_CERT_PATH}','${TDE_KMIP_CLIENT_KEY_PATH}','${TDE_KMIP_CA_PATH}');" || true
            ;;
        file)
            psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                "SELECT pg_tde_add_database_key_provider_file('${TDE_PROVIDER_NAME}','${TDE_FILE_PATH}');" || true
            ;;
    esac

    # Create then set the per-database principal key. pg_tde requires the key to
    # exist before it can be set as principal, so create precedes set. The setter
    # matches the provider scope (file is database-scoped, vault/kmip are global).
    # Key setup is strict: a failure fails the bootstrap loudly rather than booting
    # with no principal key, which would silently break encrypted-table creation.
    if [[ "${TDE_PROVIDER_KIND:-}" == "file" ]]; then
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_database_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create principal key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_key_using_database_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || tde_bootstrap_fatal "failed to set database principal key '${TDE_KEY_NAME}'"
    else
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_global_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create principal key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_key_using_global_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || tde_bootstrap_fatal "failed to set global principal key '${TDE_KEY_NAME}'"

        # Set a server-wide DEFAULT principal key so databases created later inherit
        # encryption. pg_tde stores the principal key per database OID and CREATE
        # DATABASE does NOT copy it (a key set in template1 is not carried to its
        # clones), so without a server default the first encrypted CREATE TABLE in a
        # newly created database fails "principal key not configured". This only
        # matters when new tables are encrypted by default or enforced cluster-wide,
        # so gate it on TDE_DEFAULT_AM/TDE_ENFORCE (mirroring how the WAL block below
        # gates on TDE_ENCRYPT_WAL): a plain opt-in-per-table cluster does not need a
        # server default and should not take the strict-set crash-loop risk for it.
        # The default key is a global-provider feature; the file keyring (standalone,
        # database-scoped) has no server default, so this applies to vault/kmip only.
        # Create precedes set, and the set is strict like the principal-key set above.
        if [[ "${TDE_DEFAULT_AM:-false}" == "true" || "${TDE_ENFORCE:-false}" == "true" ]]; then
            psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                "SELECT pg_tde_create_key_using_global_key_provider('${TDE_KEY_NAME}-default','${TDE_PROVIDER_NAME}');" \
                || echo "pg_tde: create default key returned non-zero (may already exist), continuing to set"
            psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                "SELECT pg_tde_set_default_key_using_global_key_provider('${TDE_KEY_NAME}-default','${TDE_PROVIDER_NAME}');" \
                || tde_bootstrap_fatal "failed to set default principal key '${TDE_KEY_NAME}-default'"
        fi
    fi

    # WAL encryption is global-only: the file keyring is a database-scoped
    # provider and cannot back a server key. The operator webhook already rejects
    # this combination, so this is a fail-closed backstop with a clear message
    # (instead of a swallowed error that crash-loops on the misleading set-key fatal).
    if [[ "${TDE_ENCRYPT_WAL:-false}" == "true" && "${TDE_PROVIDER_KIND:-}" == "file" ]]; then
        tde_bootstrap_fatal "WAL encryption requires a global (vault or kmip) key provider; the file keyring cannot back WAL encryption"
    fi
    # If WAL encryption is requested, create + set the server (WAL) key too (global only).
    if [[ "${TDE_ENCRYPT_WAL:-false}" == "true" ]]; then
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_global_key_provider('${TDE_KEY_NAME}-wal','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create WAL server key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_server_key_using_global_key_provider('${TDE_KEY_NAME}-wal','${TDE_PROVIDER_NAME}');" \
            || tde_bootstrap_fatal "failed to set WAL server key '${TDE_KEY_NAME}-wal'"
    fi
fi

unset PGOPTIONS

if [[ "$BOOTSTRAP" == "true" ]];then
  # initialize database
  for f in "$INITDB"/*; do
      case "$f" in
          *.sh)
              echo "$0: running $f"
              . "$f"
              ;;
          *.sql)
              echo "$0: running $f"
              "${psql[@]}" -f "$f"
              echo
              ;;
          *.sql.gz)
              echo "$0: running $f"
              gunzip -c "$f" | "${psql[@]}"
              echo
              ;;
          *) echo "$0: ignoring $f" ;;
      esac
      echo
  done
fi

# stop server
pg_ctl promote
pg_ctl -D "$PGDATA" -m fast -w stop

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

        { echo 'hostssl    all             all             0.0.0.0/0               cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             0.0.0.0/0               cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::/0                    cert clientcert=verify-full'; } >>/tmp/pg_hba.conf
    elif [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 scram-sha-256'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
    else
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::/0                    md5'; } >>/tmp/pg_hba.conf
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

        { echo 'host         all             all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             0.0.0.0/0               scram-sha-256'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             ::/0                    scram-sha-256'; } >>/tmp/pg_hba.conf
    else
        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             127.0.0.1/32            trust'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::1/128                 trust'; } >>/tmp/pg_hba.conf

        { echo 'local        replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             127.0.0.1/32            md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             ::1/128                 md5'; } >>/tmp/pg_hba.conf

        { echo 'host         all             all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'host         all             all             ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     postgres        ::/0                    md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             0.0.0.0/0               md5'; } >>/tmp/pg_hba.conf
        { echo 'host         replication     all             ::/0                    md5'; } >>/tmp/pg_hba.conf
    fi

fi

mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

touch /tmp/postgresql.conf
# pg_tde runtime GUCs. Authored in the post-bootstrap rewrite, after the
# extension and principal key exist, so default_table_access_method is safe.
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
    echo "synchronous_commit = ${SYNC_COMMIT_LEVEL:-remote_write}" >>/tmp/postgresql.conf

    if [[ "${SYNC_USE_WILDCARD:-false}" == "true" ]]; then
        names="*"
    elif [[ -n "${SYNC_STANDBY_NAMES:-}" ]]; then
        names=""
        IFS=',' read -ra _standby_list <<< "$SYNC_STANDBY_NAMES"
        for _name in "${_standby_list[@]}"; do
            names+="\"${_name}\"",
        done
        names="${names%,}"
    else
        # https://stackoverflow.com/a/44092231/244009
        self_idx=${HOSTNAME##*[!0-9]}
        echo "$self_idx"

        shopt -s extglob
        sts_prefix=${HOSTNAME%%+([0-9])}
        names=""
        for ((i = 0; i < $REPLICAS; i++)); do
            if [[ $self_idx == $i ]]; then
                echo "skip $i"
            else
                names+="\"$sts_prefix$i\"",
            fi
        done
        names=${names%,}
    fi
    echo "synchronous_standby_names = '${SYNC_REPLICATION_MODE:-ANY} ${NUM_SYNC_REPLICAS:-1} ("$names")'" >>/tmp/postgresql.conf
fi

# ref: https://superuser.com/a/246841/985093
cat /tmp/postgresql.conf $PGDATA/postgresql.conf >"/tmp/postgresql.conf.tmp" && mv "/tmp/postgresql.conf.tmp" "$PGDATA/postgresql.conf"
