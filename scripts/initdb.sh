#!/bin/bash

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

# Copyright The KubeDB Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export POSTGRES_INITDB_ARGS=${POSTGRES_INITDB_ARGS:-}
# Create the transaction log directory before initdb is run

if [[ "$MAJOR_PG_VERSION" == "9" ]]; then
    export POSTGRES_INITDB_XLOGDIR=${POSTGRES_INITDB_XLOGDIR:-}
    if [ "$POSTGRES_INITDB_XLOGDIR" ]; then
        mkdir -p "$POSTGRES_INITDB_XLOGDIR"
        chmod 700 "$POSTGRES_INITDB_XLOGDIR"

        export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --xlogdir $POSTGRES_INITDB_XLOGDIR"
    fi
else
    export POSTGRES_INITDB_WALDIR=${POSTGRES_INITDB_WALDIR:-}
    if [ "$POSTGRES_INITDB_WALDIR" ]; then
        mkdir -p "$POSTGRES_INITDB_WALDIR"
        chmod 700 "$POSTGRES_INITDB_WALDIR"

        export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --waldir $POSTGRES_INITDB_WALDIR"
    fi
fi


distro=$(grep '^ID' /etc/os-release)
distro=${distro#"ID="}
if [[ "$distro" == "debian" ]]; then
    export LD_PRELOAD="$(find /usr/lib/ -name libnss_wrapper.so)"
    touch /tmp/tmp.nss_passwd /tmp/tmp.nss_grp
    export NSS_WRAPPER_PASSWD="/tmp/tmp.nss_passwd"
    export NSS_WRAPPER_GROUP="/tmp/tmp.nss_grp"
    echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA:/bin/false" >"$NSS_WRAPPER_PASSWD"
    echo "postgres:x:$(id -g):" >"$NSS_WRAPPER_GROUP"
fi

initdb $POSTGRES_INITDB_ARGS --pgdata="$PGDATA" --username=postgres
# unset "nss_wrapper" bits
if [[ "$distro" == "debian" ]]; then
    unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
fi