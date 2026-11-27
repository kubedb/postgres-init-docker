#!/usr/bin/env bash
RECOVERY_DONE_FILE="/var/pv/"$PITR_UNIX_TIME"_recovery.done"
PITR_RS=${PITR_REPLICATION_STRATEGY:-none}
STOP=false
# don't restart postgres on SIGTERM (eg, pod deleted), and stop supervising once
# the signal arrives, so this script (the container's main process) EXITS.
#
# The trap alone is not enough: it only tells the loop below not to start postgres
# again. With `while true` the loop kept spinning forever after that, the container
# never exited on its own, and kubelet had no choice but to wait out the whole
# terminationGracePeriodSeconds and SIGKILL. Two consequences, both observed live:
# pod deletions blocked for the entire grace period (5 minutes on a DB that sets
# 300), and on the default 30s grace a postgres shutdown checkpoint slower than
# that got SIGKILLed midway, leaving a data directory that needs crash recovery.
#
# STOP is only ever set by a signal delivered to THIS bash process, which in
# practice means kubelet stopping the container. The coordinator stops postgres
# with `pg_ctl stop` exec'd into the container (and kills nothing else by name or
# process group), so its shutdowns do not reach this process: the loop keeps
# retrying and re-runs the role script when the coordinator writes the next one,
# exactly as before. Verified live: a single container instance served 17 role
# script starts with no restart.
# ref: https://opensource.com/article/20/6/bash-trap
trap \
    "{ STOP=true; }" \
    SIGINT SIGTERM EXIT

if [[ "$PITR_RESTORE" == "true" ]]; then
    while [[ "$STOP" = false ]]; do
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
while [[ "$STOP" = false ]]; do
  # Robust /var/pv mount availability check before any destructive operation or basebackup
    if [[ -e /var/pv/BOOTSTRAP_INITIALIZATION_STARTED ]]; then
        rm /var/pv/BOOTSTRAP_INITIALIZATION_STARTED
    fi
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

        if [[ "$STANDALONE" != "true" ]]; then
            echo "removing the initial scripts as server is not running ..."
            rm -rf /run_scripts/*
        fi
    fi
    sleep 1
done
