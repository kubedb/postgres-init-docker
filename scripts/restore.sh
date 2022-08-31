#!/bin/bash
wal-g backup-fetch /var/pv/data LATEST
touch /var/pv/data/recovery.signal



# setup postgresql.conf
touch /tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "shared_buffers = $SHARED_BUFFERS" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

echo "wal_keep_size = 64" >>/tmp/postgresql.conf

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
echo "restore_command = '/scripts/wal-g wal-fetch %f %p'" >>/tmp/postgresql.conf
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
pg_ctl -D "$PGDATA" -w start &
sleep 10
echo "hey bro i am here................................*****************************......................................."
while [ -e /var/pv/data/postmaster.pid ] | [ ! -e /var/pv/data/restore.done]; do
    "restoring..."
    sleep 1
done

# stop server
pg_ctl -D "$PGDATA" -m fast -w stop