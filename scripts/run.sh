#!/usr/bin/env bash
RECOVERY_DONE_FILE="/var/pv/"$PITR_UNIX_TIME"_recovery.done"
PITR_RS=${PITR_REPLICATION_STRATEGY:-none}
STOP=false
# don't restart postgres on SIGTERM (eg, pod deleted)
# ref: https://opensource.com/article/20/6/bash-trap
trap \
    "{ STOP=true; }" \
    SIGINT SIGTERM EXIT

if [[ "$PITR_RESTORE" == "true" ]]; then
    while true; do
      sleep 2
      echo "Point In Time Recovery In Progress. Waiting for $RECOVERY_DONE_FILE file"
      if [[ -e "$RECOVERY_DONE_FILE" ]]; then
        echo "$RECOVERY_DONE_FILE found."
        break
      fi
    done
fi

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

    if [[ "$ARCHIVER_ENABLED" == "true" && ! -d "$ARCHIVE_STATUS_PATH" && "$ARCHIVE_STATUS_PATH" != "" ]];then
      mkdir -m 0750 -p "$ARCHIVE_PATH"
      mkdir -m 0750 -p "$ARCHIVE_STATUS_PATH"
      mkdir -m 0750 -p "$LAST_ARCHIVED_FILE_INFO_DIR"
    fi

    if [[ -e /run_scripts/role/run.sh ]] && [[ "$STOP" = false ]]; then
        echo "running the initial script ..."
        if [[ $REMOTE_REPLICA == "true" ]]; then
            /run_scripts/role/remote-replica.sh
        elif [[ ! -f "/var/split-brain/SPLIT_BRAIN" ]]; then
            /run_scripts/role/run.sh
        elif [[ -f "/var/split-brain/SPLIT_BRAIN" ]]; then
            echo "Split brain detected. Not starting the database server."
        fi

        if [[ $STANDALONE == "false" ]]; then
            echo "removing the initial scripts as server is not running ..."
            rm -rf /run_scripts/*
        fi
    fi
    sleep 1
done
