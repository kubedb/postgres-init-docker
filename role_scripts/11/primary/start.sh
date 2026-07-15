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

# echo "wal_keep_segments = 1024" >>/tmp/postgresql.conf
if [ ! -z "${WAL_RETAIN_PARAM:-}" ] && [ ! -z "${WAL_RETAIN_AMOUNT:-}" ]; then
    echo "${WAL_RETAIN_PARAM}=${WAL_RETAIN_AMOUNT}" >>/tmp/postgresql.conf
else
  echo "wal_keep_segments = 160" >>/tmp/postgresql.conf
fi
echo "max_replication_slots = 90" >>/tmp/postgresql.conf
echo "wal_log_hints = on" >>/tmp/postgresql.conf
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

if [[ "$CLIENT_AUTH_MODE" = "scram" ]]; then
    echo "password_encryption = scram-sha-256" >>/tmp/postgresql.conf
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

# alter postgres superuser
"${psql[@]}" --username postgres <<-EOSQL
    $op USER "$POSTGRES_USER" WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';
EOSQL
echo

psql+=(--username "$POSTGRES_USER" --dbname "$POSTGRES_DB")
echo

# pg_tde principal-key bootstrap. Runs once on first initialization, after the
# database and superuser exist and before any encrypted table or the
# default_table_access_method flip can be used. Idempotent on retries.
if [[ "${TDE_ENABLED:-false}" == "true" && "${BOOTSTRAP}" == "true" ]]; then
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
            psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
                "SELECT pg_tde_add_global_key_provider_vault_v2('${TDE_PROVIDER_NAME}','${TDE_VAULT_ADDR}','${TDE_VAULT_MOUNT}','${TDE_VAULT_TOKEN_PATH}','${TDE_VAULT_CA_PATH}');" || true
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
        PGOPTIONS="-c pg_tde.cipher=${TDE_CIPHER:-aes_128}" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_database_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create principal key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_key_using_database_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || { echo "pg_tde FATAL: failed to set database principal key '${TDE_KEY_NAME}'"; exit 1; }
    else
        PGOPTIONS="-c pg_tde.cipher=${TDE_CIPHER:-aes_128}" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_global_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create principal key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_key_using_global_key_provider('${TDE_KEY_NAME}','${TDE_PROVIDER_NAME}');" \
            || { echo "pg_tde FATAL: failed to set global principal key '${TDE_KEY_NAME}'"; exit 1; }
    fi

    # If WAL encryption is requested, create + set the server (WAL) key too (global only).
    if [[ "${TDE_ENCRYPT_WAL:-false}" == "true" ]]; then
        PGOPTIONS="-c pg_tde.cipher=${TDE_CIPHER:-aes_128}" psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_create_key_using_global_key_provider('${TDE_KEY_NAME}-wal','${TDE_PROVIDER_NAME}');" \
            || echo "pg_tde: create WAL server key returned non-zero (may already exist), continuing to set"
        psql -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
            "SELECT pg_tde_set_server_key_using_global_key_provider('${TDE_KEY_NAME}-wal','${TDE_PROVIDER_NAME}');" \
            || { echo "pg_tde FATAL: failed to set WAL server key '${TDE_KEY_NAME}-wal'"; exit 1; }
    fi
fi

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
    elif [[ "$CLIENT_AUTH_MODE" = "scram" ]]; then
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
