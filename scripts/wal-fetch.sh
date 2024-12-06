#!/usr/bin/env bash

WAL_FILE=$1
DEST_FILE=$2
RETRY_INTERVAL=6
MAX_RETRIES=100

for ((i=1; i<=MAX_RETRIES; i++))
do
  wal-g wal-fetch $WAL_FILE $DEST_FILE
  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 0 ]; then
    # Successfully fetched the WAL file
    exit 0
  elif [ $EXIT_CODE -ne 74 ]; then
    # Any error other than 74 should stop PostgreSQL recovery
    exit $EXIT_CODE
  fi

  # Wait before retrying
  sleep $RETRY_INTERVAL
done

# If the script reaches here, it means we exhausted all retries
echo "Failed to fetch WAL file: $WAL_FILE after $MAX_RETRIES attempts."
exit 74
