#!/bin/bash

# set -xe

HOSTNAME=pg-bah-0

echo $HOSTNAME

# https://stackoverflow.com/a/44092231/244009
self_idx=$(echo $HOSTNAME | grep -Eo '[0-9]+$')

# https://stackoverflow.com/a/44090126/244009
shopt -s extglob
sts_prefix=${HOSTNAME%%+([0-9])}
# https://unix.stackexchange.com/a/104887/42136
sts_prefix=${sts_prefix//-/}

if [ $self_idx -eq 0 ]; then
    echo "synchronous_standby_names = 'ANY 1 (${sts_prefix}1, ${sts_prefix}2)'"
elif [ $self_idx -eq 1 ]; then
    echo "synchronous_standby_names = 'ANY 1 (${sts_prefix}0, ${sts_prefix}2)'"
else
    echo "synchronous_standby_names = 'ANY 1 (${sts_prefix}0, ${sts_prefix}1)'"
fi
