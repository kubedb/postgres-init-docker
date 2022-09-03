#!/bin/bash
mkdir -p $PGDATA
wal-g backup-fetch $PGDATA LATEST



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



# ****************** Recovery config 12 **************************
touch $PGDATA/recovery.signal

# setup postgresql.conf
touch /tmp/postgresql.conf
echo "restore_command = 'wal-g wal-fetch %f %p'" >>/tmp/postgresql.conf
echo "recovery_target_timeline = 'latest'" >>/tmp/postgresql.conf
 echo "recovery_target_action = 'promote'" >>/tmp/postgresql.conf
echo "wal_level = replica" >>/tmp/postgresql.conf
echo "max_wal_senders = 90" >>/tmp/postgresql.conf # default is 10.  value must be less than max_connections minus superuser_reserved_connections. ref: https://www.postgresql.org/docs/11/runtime-config-replication.html#GUC-MAX-WAL-SENDERS

echo "wal_keep_size = 64" >>/tmp/postgresql.conf

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
echo "hey bro i am here................................*****************************.......................................  | [[ ! -e /var/pv/data/restore.done]]"
#  | [[ ! -e /var/pv/data/restore.done]]
while [[ -e /var/pv/data/postmaster.pid ]]; do
    echo "restoring..."
    sleep 1
done

# stop server
pg_ctl -D "$PGDATA" -m fast -w stop