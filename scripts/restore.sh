#!/bin/bash

INSIDE="false"
IN_MIDDLE_OF_BB="false"
DONE_FILE="var/pv/done.txt"
LOG_DIR="$PGDATA"/log
PATTERN1="recovery stopping"
PATTERN2="pausing at the end of recovery"
PATTERN3="Execute pg_wal_replay_resume()"
PATTERN4="recovery has paused"
PATTERN5="requested recovery stop point is before consistent recovery point"
LOG_FILE_PATTERN="postgresql-*.log"
RECOVERY_FILE="$PGDATA"/recovery.signal
mkdir -p $PGDATA
chmod 0700 "$PGDATA"

# remove raft wal
rm -rf /var/pv/raftwal && rm -rf /var/pv/raftsnapshot

if [[ "${WALG_BASE_BACKUP_NAME:-0}" != "0" ]]; then
    echo "starting to restore from basebackup $WALG_BASE_BACKUP_NAME ..."
    wal-g backup-fetch $PGDATA $WALG_BASE_BACKUP_NAME
fi

# check postgresql veriosn
if [[ "$PITR_LSN" != "" ]]; then
  echo "Trying to restore upto lsn: $PITR_LSN commit-time: $PITR_TIME"
else
  echo "Trying to restore in time: "$PITR_TIME
fi

if [[ "$PG_MAJOR" == "11" ]]; then
    RECOVERY_FILE="$PGDATA"/recovery.conf
    # ****************** Recovery config 11 **************************
    touch /tmp/recovery.conf
    echo "restore_command = 'wal-g wal-fetch %f %p'" >>/tmp/recovery.conf
    echo "standby_mode = on" >>/tmp/recovery.conf
    echo "trigger_file = '/run_scripts/tmp/pg-failover-trigger'" >>/tmp/recovery.conf # [ name whose presence ends recovery]
    if [[ "${PITR_TIME:-0}" != "latest" ]]; then
        echo "recovery_target_time = '$PITR_TIME'" >>/tmp/recovery.conf
    else
        echo "recovery_target_timeline = 'latest'" >>/tmp/recovery.conf
    fi
    echo "recovery_target_action = 'pause'" >>/tmp/recovery.conf
    mv /tmp/recovery.conf "$PGDATA/recovery.conf"

    # setup postgresql.conf
    touch /tmp/postgresql.conf
    echo "wal_level = replica" >>/tmp/postgresql.conf
    echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

    echo "wal_keep_segments = 160" >>/tmp/postgresql.conf
    echo "wal_log_hints = on" >>/tmp/postgresql.conf
else
    # ****************** Recovery config 12, 13, 14 **************************
    touch $PGDATA/recovery.signal

    # setup postgresql.conf
    touch /tmp/postgresql.conf
    echo "restore_command = 'wal-g wal-fetch %f %p'" >>/tmp/postgresql.conf
    if [[ "${PITR_TIME:-0}" != "latest" ]]; then
      if [[ "$PITR_LSN" != "" ]]; then
        echo "recovery_target_lsn = '$PITR_LSN'" >>/tmp/postgresql.conf
      else
        echo "recovery_target_time = '$PITR_TIME'" >>/tmp/postgresql.conf
      fi
    else
        echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
    fi
    echo "recovery_target_action = 'pause'" >>/tmp/postgresql.conf
    echo "wal_level = replica" >>/tmp/postgresql.conf
    echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

    if [[ "$PG_MAJOR" == "12" ]]; then
      echo "wal_keep_segments = 160" >>/tmp/postgresql.conf
    else
      echo "wal_keep_size = 2560" >>/tmp/postgresql.conf
    fi
    echo "hot_standby = on" >>/tmp/postgresql.conf
    echo "wal_log_hints = on" >>/tmp/postgresql.conf
fi

# ****************** Recovery config 12 **************************
# we are not doing any archiving by default but it's better to have this config in our postgresql.conf file in case of customization.
echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf
echo "logging_collector = on" >>/tmp/postgresql.conf
cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"
echo "max_replication_slots = 90" >>/tmp/postgresql.conf
# setup pg_hba.conf for initial start. this one is just for initialization
touch /tmp/pg_hba.conf
{ echo '#TYPE      DATABASE        USER            ADDRESS                 METHOD'; } >>tmp/pg_hba.conf
{ echo '# "local" is for Unix domain socket connections only'; } >>tmp/pg_hba.conf
{ echo 'local      all             all                                     trust'; } >>tmp/pg_hba.conf
{ echo '# IPv4 local connections:'; } >>tmp/pg_hba.conf
{ echo 'host         all             all             127.0.0.1/32            trust'; } >>tmp/pg_hba.conf
mv /tmp/pg_hba.conf "$PGDATA/pg_hba.conf"

# start postgres
pg_ctl -D "$PGDATA" -w start &
sleep 10
#  | [[ ! -e /var/pv/data/restore.done]]
while [[ -e "$RECOVERY_FILE" && -e /var/pv/data/postmaster.pid ]]; do
    echo "restoring..."
    INSIDE="true"
    cluster_state=$(pg_controldata | grep "Database cluster state" | awk '{print $4, $5}')
    if [[ $cluster_state == "in production" ]]; then
        rm -rf "$RECOVERY_FILE"
    fi

    if grep -rq "$PATTERN1" "$LOG_DIR" && (grep -rq "$PATTERN2" "$LOG_DIR" ||  grep -rq "$PATTERN4" "$LOG_DIR") && grep -rq "$PATTERN3" "$LOG_DIR"; then
        echo "Recovery was paused."
        rm -rf "$RECOVERY_FILE"
    fi

    if [[ -e "$DONE_FILE" ]]; then
        echo "Recovery was Stopped in the presence of $DONE_FILE file."
        rm -rf "$RECOVERY_FILE"
    fi

    sleep 1
done

sleep 8
# Find and output all log files matching the pattern
for log_file in "$LOG_DIR"/$LOG_FILE_PATTERN; do
    echo "---------------------------------------"
    echo "Outputting contents of: $log_file"
    cat "$log_file"
    echo "---------------------------------------"
    if grep -rq "$PATTERN5" "$log_file"; then
      IN_MIDDLE_OF_BB="true"
    fi
done

if [[ "$IN_MIDDLE_OF_BB" != "false" ]];then
  echo "PITR Restore timestamp might fall in between a base backup."
  echo "Consider choosing a point that do not lies in between a base backup."
  echo "Hints: decrease the PITR time or increase it in case you have another base backup taken after current PITR time"
fi

if [[ ! -e "$RECOVERY_FILE" && "$INSIDE" == "true" ]]; then
    echo "database successfully recovered...."
    pg_ctl stop -D "$PGDATA" -w >/dev/null 2>&1 || echo "Warning: PostgreSQL stop command failed but ignoring..."
    exit 0
else
    exit 1
fi
