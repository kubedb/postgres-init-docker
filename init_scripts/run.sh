#!/bin/bash

set -euo pipefail
rm -rf /run_scripts/*
cp /tmp/scripts/* /scripts
# need to set the chmod to 0700 for running postgres server in single user mode
if [[ -e /var/pv/data/PG_VERSION ]]; then
    chmod 0700 /var/pv/data
fi

if [[ $STANDALONE == "true" ]]; then
    mkdir -p /run_scripts/role
    cp -r /tmp/role_scripts/$MAJOR_PG_VERSION/primary/* /run_scripts/role/
else
    cp -r /tmp/role_scripts/$MAJOR_PG_VERSION/* /role_scripts/
fi

if [[ $MAJOR_PG_VERSION -gt 11 ]]; then
    rm -rf /scripts/config_recovery.conf.sh /scripts/do_pg_recovery_cleanup.sh
fi
if [ "${SSL:-0}" = "ON" ]; then
    cp -R /certs/ /tls/
    chmod 0600 /tls/certs/server/*
    chmod 0600 /tls/certs/client/*
    chmod 0600 /tls/certs/exporter/*
fi
