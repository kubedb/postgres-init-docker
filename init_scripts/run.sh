#!/bin/bash

set -euo pipefail
rm -rf /run_scripts/*
cp /tmp/scripts/* /scripts
chmod 0777 /var/pv
if [[ $MAJOR_PG_VERSION -gt 11 ]]; then
    rm -rf /scripts/config_recovery.conf.sh /scripts/do_pg_recovery_cleanup.sh
fi
if [ "${SSL:-0}" = "ON" ]; then
    cp -R /certs/ /tls/
    chmod 0600 /tls/certs/server/*
    chmod 0600 /tls/certs/client/*
    chown -R $DB_UID:$DB_GID /tls/certs
fi
