#!/usr/bin/env bash

STOP=false
# don't restart postgres on SIGTERM (eg, pod deleted)
# ref: https://opensource.com/article/20/6/bash-trap
trap \
    "{ STOP=true; }" \
    SIGINT SIGTERM EXIT

#going to change this with the check of process id
rm -f "$PGDATA"/postmaster.pid
echo "waiting for the role to be decided ..."
while true; do
    if [[ -d $PGDATA ]];then
      DIR="$PGDATA"
      CURRENT_PERMS=$(stat -c "%a" "$DIR")
      if [ "$CURRENT_PERMS" -gt 700 ]; then
          echo "Permissions are greater than 0700. Updating to 0700."
          chmod 0700 "$DIR"
      fi
    fi

    if [[ -e /run_scripts/role/run.sh ]] && [[ "$STOP" = false ]]; then
        echo "running the initial script ..."
        if [[ $REMOTE_REPLICA == "true" ]]; then
            /run_scripts/role/remote-replica.sh
        else
            /run_scripts/role/run.sh
        fi

        if [[ $STANDALONE == "false" ]]; then
            echo "removing the initial scripts as server is not running ..."
            rm -rf /run_scripts/*
        fi
    fi
    sleep 1
done
