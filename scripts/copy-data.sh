#!/usr/bin/env bash

ROOT_DIR="$ROOT_DIR"
TOTAL_DIR_TO_COPY="$TOTAL_DIR_TO_COPY"
DATA_DIR="$DATA_DIR"

if [ -z "$ROOT_DIR" ] || [ -z "$TOTAL_DIR_TO_COPY" ]; then
    echo "ROOT_DIR and TOTAL_DIR_TO_COPY must be set."
    exit 1
fi
Size1=$(du -s "$ROOT_DIR/$DATA_DIR" | cut -f1)
echo "DATA DIRECTORY SIZE: ", $Size1
for ((i = 1; i <= $TOTAL_DIR_TO_COPY; i++)); do
    if [[ -d "$ROOT_DIR$i/$DATA_DIR" ]]; then
        Size2=$(du -s "$ROOT_DIR$i/$DATA_DIR" | cut -f1)
        echo $Size1, " ", $Size2
        if [[ "$Size1" == "$Size2" ]]; then
            continue
        fi
    fi
    # not deleting any data
    # because the sole purpose of this script is to copy the data
    # rm -rf "$ROOT_DIR$i"/*
    cp -rvL "$ROOT_DIR/"* "$ROOT_DIR$i"/
    if [[ $? -ne 0 ]]; then
        echo "Error occurred while copying to $ROOT_DIR$i"
        exit 1
    fi
done

exit 0
