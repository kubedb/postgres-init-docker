#!/bin/sh
# Bring a hard-killed STANDBY ("in archive recovery") to a clean "shut down in recovery" state
# without writing any WAL. Runs inside the postgres container; pg-coordinator executes it from
# /scripts (copied there by the init container) before it would otherwise run single-user mode.
#
#   standby_clean_stop.sh [<pgdata> [<pg-major> [<consistency-timeout-seconds>]]]
#
# Defaults: $PGDATA (else /var/pv/data), the major version in <pgdata>/PG_VERSION, 300 s.
# It must stay POSIX sh: /bin/sh is busybox ash on alpine, dash on debian, bash on stream9.
#
# The server is started in standby mode with every upstream disabled (no primary_conninfo,
# no slot, no restore_command, no promote trigger) and with hot_standby=off, so no client
# can connect and the parameter checks of hot standby cannot block startup. It replays the
# WAL already in pg_wal. We wait until the log says "consistent recovery state reached"
# (logged with or without hot standby) or the timeout passes, then stop it with -m fast.
# A fast stop of a server in recovery writes a restartpoint and marks the control file
# "shut down in recovery"; it never writes WAL. If consistency was not reached in time,
# minRecoveryPoint stays in pg_control and the next standby start still enforces it.
#
# This replaces single-user crash recovery for standbys. Single-user mode removes standby
# mode, replays as a PRIMARY (crash recovery ignores minRecoveryPoint), and writes its own
# shutdown checkpoint (and, with archiving on, a WAL switch) on the shared timeline.
#
# Output contract (last lines): CONSISTENT=<0|1> STARTED=<0|1> STATE=<pg_control state>
set -u
PGDATA_DIR="${1:-${PGDATA:-/var/pv/data}}"
MAJOR="${2:-$(cut -d. -f1 "$PGDATA_DIR/PG_VERSION" 2>/dev/null)}"
TMO="${3:-300}"
LOG=/tmp/pgc-standby-clean-stop.log
: >"$LOG"

# an arbitrary uid with no passwd entry needs nss_wrapper (same as single-user mode); the
# library is under /usr/lib on alpine, /usr/lib/<triplet> on debian and /usr/lib64 on EL
if ! id -un >/dev/null 2>&1; then
  NSS="$(find /usr/lib/ /usr/lib64/ -name libnss_wrapper.so 2>/dev/null | head -1)"
  if [ -n "$NSS" ]; then
    export LD_PRELOAD="$NSS" NSS_WRAPPER_PASSWD=/tmp/tmp.nss_passwd NSS_WRAPPER_GROUP=/tmp/tmp.nss_grp
    echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA_DIR:/bin/false" >"$NSS_WRAPPER_PASSWD"
    echo "postgres:x:$(id -g):" >"$NSS_WRAPPER_GROUP"
  fi
fi
if [ ! -f "$PGDATA_DIR/postgresql.conf" ] && [ -f /var/pv/postgresql.conf ]; then
  cp /var/pv/postgresql.conf "$PGDATA_DIR/postgresql.conf"
fi

OPTS="-c hot_standby=off"
if [ "$MAJOR" -ge 12 ]; then
  touch "$PGDATA_DIR/standby.signal"
  rm -f "$PGDATA_DIR/recovery.signal"
  OPTS="$OPTS -c primary_conninfo='' -c primary_slot_name='' -c restore_command='' -c recovery_end_command='' -c archive_cleanup_command=''"
  # promote_trigger_file exists in 12-15 only; KubeDB points it at /run_scripts/tmp/pg-failover-trigger
  if [ "$MAJOR" -le 15 ]; then OPTS="$OPTS -c promote_trigger_file='/nonexistent/pgc-standby-clean-stop'"; fi
else
  # <12: the standby settings live in recovery.conf, which is not a GUC file; write a minimal one
  printf "standby_mode = 'on'\nrecovery_target_timeline = 'latest'\n" >"$PGDATA_DIR/recovery.conf"
fi

STARTED=0; CONSISTENT=0
# with hot_standby=off, pg_ctl -w returns once recovery has started
if pg_ctl -D "$PGDATA_DIR" -l "$LOG" -o "$OPTS" -w -t 120 start >/dev/null 2>&1; then
  STARTED=1
  i=0
  while [ "$i" -lt "$TMO" ]; do
    if grep -q "consistent recovery state reached" "$LOG"; then CONSISTENT=1; break; fi
    pg_ctl -D "$PGDATA_DIR" status >/dev/null 2>&1 || break
    sleep 1; i=$((i + 1))
  done
fi
if pg_ctl -D "$PGDATA_DIR" status >/dev/null 2>&1; then
  pg_ctl -D "$PGDATA_DIR" -w -t 600 stop -m fast >/dev/null 2>&1 ||
    pg_ctl -D "$PGDATA_DIR" -w -t 60 stop -m immediate >/dev/null 2>&1
fi
tail -n 20 "$LOG"
echo "CONSISTENT=$CONSISTENT"
echo "STARTED=$STARTED"
echo "STATE=$(pg_controldata "$PGDATA_DIR" | sed -n 's/^Database cluster state: *//p')"
