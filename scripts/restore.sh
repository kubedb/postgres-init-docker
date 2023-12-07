#!/bin/bash

mkdir -p $PGDATA
chmod 0700 "$PGDATA"

# remove raft wal
rm -rf /var/pv/raftwal && rm -rf /var/pv/raftsnapshot

if [[ "${WALG_BASE_BACKUP_NAME:-0}" != "0" ]]; then
    echo "starting to restore from basebackup $WALG_BASE_BACKUP_NAME ..."
    wal-g backup-fetch $PGDATA $WALG_BASE_BACKUP_NAME
fi

## ****************** Recovery config 11 **************************
#touch /tmp/recovery.conf
#echo "restore_command = 'wal-g wal-fetch %f %p'" >>/tmp/recovery.conf
#echo "standby_mode = on" >>/tmp/recovery.conf
#echo "trigger_file = '/run_scripts/tmp/pg-failover-trigger'" >>/tmp/recovery.conf # [ name whose presence ends recovery]
##echo "recovery_target_timeline = 'latest'" >>/tmp/recovery.conf
##echo "recovery_target = 'immediate'" >>/tmp/recovery.conf
#echo "recovery_target_action = 'promote'" >>/tmp/recovery.conf
#mv /tmp/recovery.conf "$PGDATA/recovery.conf"
#
## setup postgresql.conf
#touch /tmp/postgresql.conf
#echo "wal_level = replica" >>/tmp/postgresql.conf
#echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS
#
#echo "wal_keep_segments = 64" >>/tmp/postgresql.conf
#
#echo "wal_log_hints = on" >>/tmp/postgresql.conf

# ****************** Recovery config 12, 13, 14 **************************
touch $PGDATA/recovery.signal

# setup postgresql.conf
touch /tmp/postgresql.conf
echo "restore_command = 'wal-g wal-fetch %f %p'" >>/tmp/postgresql.conf
#echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
if [[ "${PITR_TIME:-0}" != "latest" ]]; then
    echo "recovery_target_time = '$PITR_TIME'" >>/tmp/postgresql.conf
else
    echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
fi
echo "recovery_target_action = 'promote'" >>/tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

echo "wal_keep_size = 64" >>/tmp/postgresql.conf
echo "hot_standby = on" >>/tmp/postgresql.conf
echo "wal_log_hints = on" >>/tmp/postgresql.conf

# ****************** Recovery config 12 **************************
# we are not doing any archiving by default but it's better to have this config in our postgresql.conf file in case of customization.
echo "archive_mode = always" >>/tmp/postgresql.conf
echo "archive_command = '/bin/true'" >>/tmp/postgresql.conf

cat /run_scripts/role/postgresql.conf >>/tmp/postgresql.conf
mv /tmp/postgresql.conf "$PGDATA/postgresql.conf"

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
while [[ -e /var/pv/data/recovery.signal && -e /var/pv/data/postmaster.pid ]]; do
    echo "restoring..."
    cluster_state=$(pg_controldata | grep "Database cluster state" | awk '{print $4, $5}')
    if [[ $cluster_state == "in production" ]]; then
        echo "database succefully recovered...."
        rm -rf /var/pv/data/recovery.signal
    fi
    sleep 1
done

sleep 10

if [[ ! -e /var/pv/data/recovery.signal ]]; then
    exit 0
else
    exit 1
fi
