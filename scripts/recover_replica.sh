#!/usr/bin/env bash

export PGPASSWORD=$POSTGRES_PASSWORD
export PGDATA=/var/pv/data
export SSL=${SSL:-0}
touch /var/pv/MAINTENANCE
mv /run_scripts/role/run.sh /run_scripts/role/run.sh.bc
pg_ctl stop -D $PGDATA
rm -rf /var/pv/data

if [[ "${SSL:-0}" == "ON" ]]; then
    pg_basebackup -Xs -c fast --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" &>/dev/null
else
    pg_basebackup -Xs -c fast --no-password --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD" &>/dev/null
fi

touch /var/pv/data/standby.signal
mv /run_scripts/role/run.sh.bc /run_scripts/role/run.sh
rm /var/pv/MAINTENANCE