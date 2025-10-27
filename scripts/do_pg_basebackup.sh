#!/usr/bin/env bash

set -eou pipefail

# Source the safe backup function
source /scripts/safe_pgdata_backup.sh

# Safely backup existing PGDATA if it exists
if ! safe_pgdata_backup; then
    echo "Failed to safely backup PGDATA, aborting basebackup operation"
    exit 1
fi

# get basebackup
mkdir -p "$PGDATA"
chmod 0700 "$PGDATA"
echo "attempting pg_basebackup..."

if [[ "${SSL:-0}" == "ON" ]]; then
    if pg_basebackup -X fetch --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD sslmode=$SSL_MODE sslrootcert=/tls/certs/client/ca.crt sslcert=/tls/certs/client/client.crt sslkey=/tls/certs/client/client.key" &>/dev/null; then
        echo "pg_basebackup completed successfully"
        cleanup_pgdata_backup
    else
        echo "pg_basebackup failed, backup remains available for recovery"
        exit 1
    fi
else
    if pg_basebackup -X fetch --no-password --pgdata "$PGDATA" --username=postgres --progress --host="$PRIMARY_HOST" -d "password=$POSTGRES_PASSWORD" &>/dev/null; then
        echo "pg_basebackup completed successfully"
        cleanup_pgdata_backup
    else
        echo "pg_basebackup failed, backup remains available for recovery"
        exit 1
    fi
fi
