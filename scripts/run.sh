#!/usr/bin/env bash

#going to change this with the check of process id
rm -f "$PGDATA"/postmaster.pid
echo "waiting for the role to be decided ..."
while true; do
    if [[ -e /run_scripts/role/run.sh ]]; then
        echo "running the initial script ..."
        /run_scripts/role/run.sh
        if [[ $STANDALONE == "false" ]]; then
            echo "removing the initial scripts as server is not running ..."
            rm -rf /run_scripts/*
        fi
    fi
    sleep 1
done
