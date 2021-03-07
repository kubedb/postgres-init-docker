#!/bin/sh
set -eo pipefail

rm -rf /run_scripts/*
if [[ "${SSL:-0}" = "ON" ]]; then
    cp -R /certs/ /tls/
    chmod 0600 /tls/certs/server/*
    chmod 0600 /tls/certs/client/*
    chown -R 70:70 /tls/certs
fi