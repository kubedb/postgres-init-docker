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
# It only ever signals the server it started itself (tagged with cluster_name, stopped by PID).
# A server someone else runs in the data directory is left alone and reported as
# OTHER_RUNNING=1; the caller then sees a state other than "shut down in recovery" and retries.
#
# Output contract (last lines): CONSISTENT=<0|1> STARTED=<0|1> OTHER_RUNNING=<0|1> STATE=<pg_control state>
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

MARK=pgc-standby-clean-stop
OPTS="$OPTS -c cluster_name=$MARK"

# A process is "alive" if it exists and is not a zombie.
alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    [ "$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" != Z ]
}
pidfile_pid() { head -n 1 "$PGDATA_DIR/postmaster.pid" 2>/dev/null; }
# Our server is the one started with cluster_name=$MARK (its command line or, once the
# title is rewritten, its process title carries the mark).
ours() { alive "$1" && grep -q "$MARK" "/proc/$1/cmdline" 2>/dev/null; }

STARTED=0
CONSISTENT=0
OTHER_RUNNING=0
OURPID=""
report() {
    tail -n 20 "$LOG"
    echo "CONSISTENT=$CONSISTENT"
    echo "STARTED=$STARTED"
    echo "OTHER_RUNNING=$OTHER_RUNNING"
    echo "STATE=$(pg_controldata "$PGDATA_DIR" | sed -n 's/^Database cluster state: *//p')"
}

# Never touch a server this script did not start: if one is running, do nothing.
if alive "$(pidfile_pid)"; then
    OTHER_RUNNING=1
    report
    exit 0
fi

# with hot_standby=off, pg_ctl -w returns once recovery has started
pg_ctl -D "$PGDATA_DIR" -l "$LOG" -o "$OPTS" -w -t 120 start >/dev/null 2>&1
P="$(pidfile_pid)"
if ours "$P"; then
    STARTED=1
    OURPID="$P"
elif alive "$P"; then
    OTHER_RUNNING=1 # someone else's server took the data directory first
fi

if [ -n "$OURPID" ]; then
    i=0
    while [ "$i" -lt "$TMO" ]; do
        if grep -q "consistent recovery state reached" "$LOG"; then
            CONSISTENT=1
            break
        fi
        alive "$OURPID" || break
        sleep 1
        i=$((i + 1))
    done
    # Stop OUR postmaster by PID (SIGINT = fast shutdown) and wait for THAT process, not for
    # the pid file: another server may write a new pid file the moment ours exits. A fast
    # shutdown in recovery only writes a restartpoint, so the wait is generous; immediate
    # (SIGQUIT) is a last resort, and also only for our own PID.
    if alive "$OURPID"; then
        kill -INT "$OURPID" 2>/dev/null
        i=0
        while alive "$OURPID" && [ "$i" -lt 600 ]; do
            sleep 1
            i=$((i + 1))
        done
        if alive "$OURPID"; then
            kill -QUIT "$OURPID" 2>/dev/null
            i=0
            while alive "$OURPID" && [ "$i" -lt 60 ]; do
                sleep 1
                i=$((i + 1))
            done
        fi
    fi
    if alive "$(pidfile_pid)"; then OTHER_RUNNING=1; fi
fi
report
