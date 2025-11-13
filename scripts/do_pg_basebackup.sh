#!/usr/bin/env bash

set -eou pipefail

# get basebackup
mkdir -p "$PGDATA"
rm -rf "$PGDATA"/*
chmod 0700 "$PGDATA"
echo "attempting pg_basebackup..."

if [[ "${SSL:-0}" == "ON" ]]; then
    pg_basebackup -Xs -c fast --pgdata "$PGDATA" --max-rate=1024M --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" &>/dev/null
else
    pg_basebackup -Xs -c fast --no-password --max-rate=1024M --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD" &>/dev/null
fi
