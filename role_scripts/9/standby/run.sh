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

if [[ ! -e "$PGDATA/PG_VERSION" ]]; then
    echo "take base basebackup..."
    # get basebackup
    mkdir -p "$PGDATA"
    rm -rf "$PGDATA"/*
    chmod 0700 "$PGDATA"
    if [[ "${SSL:-0}" == "ON" ]]; then
        pg_basebackup -X fetch --pgdata "$PGDATA" --username=postgres --host="$PRIMARY_HOST" -d "sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key"
    else
        pg_basebackup -X fetch --no-password --pgdata "$PGDATA" --username=postgres --host="$PRIMARY_HOST"
    fi
else
    /run_scripts/role/warm_stanby.sh
fi

export PGWAL="$PGDATA/pg_xlog"

# setup recovery.conf
/scripts/config_recovery.conf.sh

# setup postgresql.conf
touch /tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
echo "wal_keep_segments = 1024" >>/tmp/postgresql.conf

echo "wal_log_hints = on" >>/tmp/postgresql.conf

echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf

if [ "$STANDBY" == "hot" ]; then
    echo "hot_standby = on" >>/tmp/postgresql.conf
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

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

# setup pg_hba.conf
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>tmp/pg_hba.conf
if [[ "${SSL:-0}" == "ON" ]]; then
    if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
        #*******************client auth with client.crt and key**************

        { echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            cert clientcert=1'; } >>tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 cert clientcert=1'; } >>tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            cert clientcert=1'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 cert clientcert=1'; } >>tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               cert clientcert=1'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               cert clientcert=1'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    cert clientcert=1'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    cert clientcert=1'; } >>tmp/pg_hba.conf
    else
        { echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            md5'; } >>tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 md5'; } >>tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            md5'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 md5'; } >>tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               md5'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               md5'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    md5'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    md5'; } >>tmp/pg_hba.conf
    fi

else
    { echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
    { echo 'host         all             all             127.0.0.1/32            trust'; } >>tmp/pg_hba.conf
    { echo '# IPv6 local connections:'; } >>tmp/pg_hba.conf
    { echo 'host         all             all             ::1/128                 trust'; } >>tmp/pg_hba.conf

    { echo 'local        replication     all                                     trust'; } >>tmp/pg_hba.conf
    { echo 'host         replication     all             127.0.0.1/32            md5'; } >>tmp/pg_hba.conf
    { echo 'host         replication     all             ::1/128                 md5'; } >>tmp/pg_hba.conf

    { echo 'host         all             all             0.0.0.0/0               md5'; } >>tmp/pg_hba.conf
    { echo 'host         replication     postgres        0.0.0.0/0               md5'; } >>tmp/pg_hba.conf
    { echo 'host         all             all             ::/0                    md5'; } >>tmp/pg_hba.conf
    { echo 'host         replication     postgres        ::/0                    md5'; } >>tmp/pg_hba.conf
fi

mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

exec postgres
