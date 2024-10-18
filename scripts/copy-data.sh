#!/usr/bin/env bash

ROOT_DIR="$ROOT_DIR"
TOTAL_DIR_TO_COPY="$TOTAL_DIR_TO_COPY"

for (( i = 1; i <= $TOTAL_DIR_TO_COPY; i++ ));do
  cp -r $ROOT_DIR/* "$ROOT_DIR$i"/
  if [[ $? -ne 0 ]]; then
    echo "Error occurred while copying to $ROOT_DIR$i"
    exit 1
  fi
done

exit 0