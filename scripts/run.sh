#!/bin/sh
set -eo pipefail

echo "helloooo........"
 rm -rf /run_scripts/*
if [ -e /run_scripts ]; then
    echo "deleting role based run_scripts"
fi
if [ "$SSL_MODE" == "ON" ]; then
    ls -la certs/
    cat certs/server/ca.crt
#     chmod -r 0700 certs/*
    whoami
    cp -R /certs/ /tls/
    ls -la /tls/certs
    cat /tls/certs/server/ca.crt
    chmod 0600 /tls/certs/server/*
    chmod 0600 /tls/certs/client/*
    chown -R 70:70 /tls/certs/server
    chown -R 70:70 /tls/certs/client
    cat /tls/certs/server/ca.crt
    ls -la /tls/certs
fi