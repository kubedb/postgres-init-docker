#!/bin/bash

set -euo pipefail
rm -rf /run_scripts/*
cp /tmp/scripts/* /scripts
# need to set the chmod to 0700 for running postgres server in single user mode
if [[ -e /var/pv/data/PG_VERSION ]]; then
    chmod 0700 /var/pv/data
fi
if [[ "${OLD_SHARE_DIR:-"null"}" != "null" ]]; then
    # Need to set global permission so that all user have the read write permission. Need this one for upgrade in Ops req
    chmod 0777 $OLD_SHARE_DIR
    chmod 0777 $OLD_LIB_DIR
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
