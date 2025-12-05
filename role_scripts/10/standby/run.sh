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

set -eou pipefail

echo "Running as Replica"

# set password ENV
export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

# Waiting for running Postgres
while true; do
    echo "Attempting pg_isready on primary"

    if [[ "${SSL:-0}" == "ON" ]]; then
        if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
            if [[ $SSL_MODE = "verify-full" || $SSL_MODE = "verify-ca" ]]; then
                pg_isready --host="$PRIMARY_HOST" -d "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" --username=postgres --timeout=2 &>/dev/null && break
            else
                pg_isready --host="$PRIMARY_HOST" -d "sslmode=$SSL_MODE sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" --username=postgres --timeout=2 &>/dev/null && break
            fi
        else
            if [[ $SSL_MODE = "verify-full" || $SSL_MODE = "verify-ca" ]]; then
                pg_isready --host="$PRIMARY_HOST" -d "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt" --username=postgres --timeout=2 &>/dev/null && break
            else
                pg_isready --host="$PRIMARY_HOST" --username=postgres --timeout=2 &>/dev/null && break
            fi
        fi
    else
        pg_isready --host="$PRIMARY_HOST" --username=postgres --timeout=2 &>/dev/null && break
    fi

    # check if current pod became leader itself
    if [[ -e "/run_scripts/tmp/pg-failover-trigger" ]]; then
        echo "Postgres promotion trigger_file found. Running primary run script"
        /run_scripts/role/run.sh
    fi
    sleep 2
done

while true; do
    echo "Attempting query on primary"
    if [[ "${SSL:-0}" == "ON" ]]; then
        psql -h "$PRIMARY_HOST" --username=postgres "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" --command="select now();" &>/dev/null && break
    else
        psql -h "$PRIMARY_HOST" --username=postgres --no-password --command="select now();" &>/dev/null && break
    fi
    # check if current pod became leader itself
    if [[ -e "/run_scripts/tmp/pg-failover-trigger" ]]; then
        echo "Postgres promotion trigger_file found. Running primary run script"
        /run_scripts/role/run.sh
    fi
    sleep 2
done

if [[ "$WAL_LIMIT_POLICY" == "ReplicationSlot" ]]; then
  CLEAN_HOSTNAME="${HOSTNAME//[^[:alnum:]]/}"
  while true; do
      echo "Create replication slot on primary"
      if [[ "${SSL:-0}" == "ON" ]]; then
          output=$(psql -h "$PRIMARY_HOST" --username=postgres "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" --command="SELECT pg_create_physical_replication_slot('${CLEAN_HOSTNAME}', true);" 2>&1 || true)
      else
          output=$(psql -h "$PRIMARY_HOST" --username=postgres --no-password --command="SELECT pg_create_physical_replication_slot('${CLEAN_HOSTNAME}', true);" 2>&1 || true)
      fi
      # check if current pod became leader itself

      if [[ $output == *"(1 row)"* || $output == *"already exists"* ]]; then
        break
      fi

      if [[ -e "/run_scripts/tmp/pg-failover-trigger" ]]; then
          echo "Postgres promotion trigger_file found. Running primary run script"
          /run_scripts/role/run.sh
      fi
      sleep 2
  done
fi


if [[ ! -e "$PGDATA/PG_VERSION" ]]; then
    if [[ ! -e "/var/pv/IGNORE_FILESYSTEM_MOUNT_CHECK" ]]; then
      # Robust /var/pv mount availability check before any destructive operation or basebackup
      pv_df_output=$(df -hP 2>&1)
      if echo "$pv_df_output" | grep -qi "Transport endpoint is not connected"; then
          echo "ERROR: /var/pv mount not healthy (Transport endpoint is not connected). Aborting basebackup."
          exit 1
      fi
      if ! echo "$pv_df_output" | awk '{print $NF}' | grep -qx "/var/pv"; then
          echo "ERROR: /var/pv is not mounted (not listed in df). Aborting basebackup."
          echo "$pv_df_output"
          exit 1
      fi
      if ! ls /var/pv >/dev/null 2>&1; then
          echo "ERROR: /var/pv is not accessible. Aborting basebackup."
          exit 1
      fi
    fi
    touch /var/pv/BOOTSTRAP_INITIALIZATION_STARTED
    echo "take base basebackup..."
    # get basebackup
    mkdir -p "$PGDATA"
    rm -rf "$PGDATA"/*
    chmod 0700 "$PGDATA"
    if [[ "${SSL:-0}" == "ON" ]]; then
        pg_basebackup -Xs -c fast --pgdata "$PGDATA" --max-rate=1024M --username=postgres --progress --host="$PRIMARY_HOST" -d "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key"
    else
        pg_basebackup -Xs -c fast --no-password --max-rate=1024M --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST"
    fi
    touch $PGDATA/recovery.conf
else
    /run_scripts/role/warm_stanby.sh
fi

export PGWAL="$PGDATA/pg_wal"

# setup recovery.conf
/scripts/config_recovery.conf.sh

# setup postgresql.conf
touch /tmp/postgresql.conf

if [[ "${TUNING_ENABLED:-}" == "true" ]]; then
  echo "include_if_exists = '${TUNING_FILE_PATH:-/etc/tune/user.conf}'" >>/tmp/postgresql.conf
fi

echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
#echo "wal_keep_segments = 1024" >>/tmp/postgresql.conf
if [ ! -z "${WAL_RETAIN_PARAM:-}" ] && [ ! -z "${WAL_RETAIN_AMOUNT:-}" ]; then
    echo "${WAL_RETAIN_PARAM}=${WAL_RETAIN_AMOUNT}" >>/tmp/postgresql.conf
else
  echo "wal_keep_segments = 160" >>/tmp/postgresql.conf
fi

echo "wal_log_hints = on" >>/tmp/postgresql.conf

echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf
echo "shared_preload_libraries = 'pg_stat_statements'" >>/tmp/postgresql.conf
echo "max_replication_slots = 90" >>/tmp/postgresql.conf
if [ "$STANDBY" == "hot" ]; then
    echo "hot_standby = on" >>/tmp/postgresql.conf
else
    echo "hot_standby = off" >>/tmp/postgresql.conf
fi
if [[ "$STREAMING" == "synchronous" ]]; then
    # setup synchronous streaming replication
    echo "synchronous_commit = remote_write" >>/tmp/postgresql.conf

    # https://stackoverflow.com/a/44092231/244009
    self_idx=$(echo $HOSTNAME | grep -Eo '[0-9]+$')
    echo "$self_idx"

    shopt -s extglob
    sts_prefix=${HOSTNAME%%+([0-9])}
    names=""
    for ((i = 0; i < $REPLICAS; i++)); do
        if [[ $self_idx == $i ]]; then
            echo "skip $i"
        else
            names+="\"$sts_prefix$i\","
        fi
    done
    names=$(echo "$names" | rev | cut -c2- | rev)
    echo "synchronous_standby_names = 'ANY 1 ("$names")'" >>/tmp/postgresql.conf
fi
if [[ "${SSL:-0}" == "ON" ]]; then
    echo "ssl = on" >>/tmp/postgresql.conf

    echo "ssl_cert_file = '/tls/certs/server/server.crt'" >>/tmp/postgresql.conf
    echo "ssl_key_file = '/tls/certs/server/server.key'" >>/tmp/postgresql.conf
    echo "ssl_ca_file = '/tls/certs/server/ca.crt'" >>/tmp/postgresql.conf
fi

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

# setup pg_hba.conf
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>/tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>/tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>/tmp/pg_hba.conf
if [[ "${SSL:-0}" == "ON" ]]; then
    if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
        #*******************client auth with client.crt and key**************

        { echo '# IPv4 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            cert clientcert=1'; } >>/tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 cert clientcert=1'; } >>/tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            cert clientcert=1'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 cert clientcert=1'; } >>/tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               cert clientcert=1'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               cert clientcert=1'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    cert clientcert=1'; } >>/tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    cert clientcert=1'; } >>/tmp/pg_hba.conf
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
    fi

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
fi

mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

if [[ -e /var/pv/BOOTSTRAP_INITIALIZATION_STARTED ]]; then
  rm /var/pv/BOOTSTRAP_INITIALIZATION_STARTED
fi

if [[ -e /var/pv/data/postgresql.conf ]]; then
  cp /var/pv/data/postgresql.conf /var/pv/postgresql.conf
fi

exec postgres
