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

# setup postgresql.conf
touch /tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

echo "wal_keep_segments = 1024" >>/tmp/postgresql.conf

echo "wal_log_hints = on" >>/tmp/postgresql.conf

# we are not doing any archiving by default but it's better to have this config in our postgresql.conf file in case of customization.
echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf

if [[ "${SSL:-0}" == "ON" ]]; then
    echo "ssl =on" >>/tmp/postgresql.conf
    echo "ssl_cert_file ='/tls/certs/server/server.crt'" >>/tmp/postgresql.conf
    echo "ssl_key_file ='/tls/certs/server/server.key'" >>/tmp/postgresql.conf
    echo "ssl_ca_file ='/tls/certs/server/ca.crt'" >>/tmp/postgresql.conf
fi

if [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
    echo "password_encryption = scram-sha-256" >>/tmp/postgresql.conf
fi
# ****************** Recovery config **************************
echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
# primary_conninfo is used for streaming replication
if [[ "${SSL:-0}" == "ON" ]]; then
    if [[ "$CLIENT_AUTH_MODE" == "cert" ]]; then
        echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key'" >>/tmp/postgresql.conf
    else
        echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt'" >>/tmp/postgresql.conf
    fi
else
    echo "primary_conninfo = 'application_name=$HOSTNAME host=$PRIMARY_HOST user=$POSTGRES_USER password=$POSTGRES_PASSWORD'" >>/tmp/postgresql.conf
fi

echo "promote_trigger_file = '/run_scripts/tmp/pg-failover-trigger'" >>/tmp/postgresql.conf # [ name whose presence ends recovery]

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

# setup pg_hba.conf for initial start. this one is just for initialization
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>tmp/pg_hba.conf
{ echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
{ echo 'host         all             all             127.0.0.1/32            trust'; } >>tmp/pg_hba.conf
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

# stop server
pg_ctl -D "$PGDATA" -m fast -w stop

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
    elif [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
        { echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             127.0.0.1/32            scram-sha-256'; } >>tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::1/128                 scram-sha-256'; } >>tmp/pg_hba.conf

        { echo 'local      replication     all                                     trust'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             127.0.0.1/32            scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     all             ::1/128                 scram-sha-256'; } >>tmp/pg_hba.conf

        { echo 'hostssl    all             all             0.0.0.0/0               scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        0.0.0.0/0               scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'hostssl    all             all             ::/0                    scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'hostssl    replication     postgres        ::/0                    scram-sha-256'; } >>tmp/pg_hba.conf
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
    if [[ "$CLIENT_AUTH_MODE" == "scram" ]]; then
        { echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
        { echo 'host         all             all             127.0.0.1/32            trust'; } >>tmp/pg_hba.conf
        { echo '# IPv6 local connections:'; } >>tmp/pg_hba.conf
        { echo 'host         all             all             ::1/128                 scram-sha-256'; } >>tmp/pg_hba.conf

        { echo 'local        replication     all                                     scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'host         replication     all             127.0.0.1/32            scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'host         replication     all             ::1/128                 scram-sha-256'; } >>tmp/pg_hba.conf

        { echo 'host         all             all             0.0.0.0/0               scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'host         replication     postgres        0.0.0.0/0               scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'host         all             all             ::/0                    scram-sha-256'; } >>tmp/pg_hba.conf
        { echo 'host         replication     postgres        ::/0                    scram-sha-256'; } >>tmp/pg_hba.conf
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

fi

mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

touch /tmp/postgresql.conf
if [ "$STANDBY" == "hot" ]; then
    echo "hot_standby = on" >>/tmp/postgresql.conf
fi

if [[ "$STREAMING" == "synchronous" ]]; then
    # setup synchronous streaming replication
    echo "synchronous_commit = remote_write" >>/tmp/postgresql.conf
    echo "synchronous_standby_names = '*'" >>/tmp/postgresql.conf
fi

# ref: https://superuser.com/a/246841/985093
cat /tmp/postgresql.conf $PGDATA/postgresql.conf >"/tmp/postgresql.conf.tmp" && mv "/tmp/postgresql.conf.tmp" "$PGDATA/postgresql.conf"
