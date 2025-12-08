#!/usr/bin/env bash

# Copyright AppsCode Inc. and Contributors
#
# Licensed under the AppsCode Free Trial License 1.0.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://github.com/appscode/licenses/raw/1.0.0/AppsCode-Free-Trial-1.0.0.md
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

echo "Running as Primary"
BOOTSTRAP="false"
# set password ENV
export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

export PGWAL="$PGDATA/pg_wal"

export ARCHIVE=${ARCHIVE:-}
if [ ! -e "$PGDATA/PG_VERSION" ]; then
    if [[ ! -e "/var/pv/IGNORE_FILESYSTEM_MOUNT_CHECK" ]]; then
      pv_df_output=$(df -hP 2>&1)
      # Fail if kernel reports a broken FUSE mount anywhere
      if echo "$pv_df_output" | grep -qi "Transport endpoint is not connected"; then
          echo "ERROR: /var/pv mount not healthy (Transport endpoint is not connected)."
          exit 1
      fi
      # Ensure /var/pv is actually mounted (present in df output)
      if ! echo "$pv_df_output" | awk '{print $NF}' | grep -qx "/var/pv"; then
          echo "ERROR: /var/pv is not mounted (not listed in df)."
          exit 1
      fi
      # Ensure the mountpoint is accessible
      if ! ls /var/pv >/dev/null 2>&1; then
          echo "ERROR: /var/pv is not accessible."
          exit 1
      fi
    fi
    mkdir -p "$PGDATA"
    rm -rf "$PGDATA"/*
    chmod 0700 "$PGDATA"
    /scripts/initdb.sh
    BOOTSTRAP="true"

fi
/run_scripts/role/start.sh $BOOTSTRAP

if [[ -e /var/pv/data/postgresql.conf ]]; then
  cp /var/pv/data/postgresql.conf /var/pv/postgresql.conf
fi

exec postgres
