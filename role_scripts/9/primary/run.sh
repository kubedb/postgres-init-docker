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

# set password ENV
export PGPASSWORD=${POSTGRES_PASSWORD:-postgres}

export PGWAL="$PGDATA/pg_xlog"

export ARCHIVE=${ARCHIVE:-}
if [ ! -e "$PGDATA/PG_VERSION" ]; then
    mkdir -p "$PGDATA"
    rm -rf "$PGDATA"/*
    chmod 0700 "$PGDATA"
    /scripts/initdb.sh

fi
/run_scripts/role/start.sh
exec postgres
