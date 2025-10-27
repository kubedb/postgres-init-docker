#!/usr/bin/env bash

# Safe PGDATA backup function
# Usage: safe_pgdata_backup
# This function safely backs up PGDATA before wiping it
# Returns 0 on success, 1 on failure

safe_pgdata_backup() {
    local pgdata_path="$PGDATA"
    local pgdata_size=0
    local var_pv_avail=0
    local tmp_avail=0
    local backup_location=""

    # Check if PGDATA exists and has content
    if [[ ! -d "$pgdata_path" ]] || [[ -z "$(ls -A "$pgdata_path" 2>/dev/null)" ]]; then
        echo "PGDATA is empty or doesn't exist, no backup needed"
        return 0
    fi

    # Calculate PGDATA size in KB using du (available in all distros)
    pgdata_size=$(du -sk "$pgdata_path" 2>/dev/null | awk '{print $1}')
    if [[ -z "$pgdata_size" ]] || [[ "$pgdata_size" -eq 0 ]]; then
        echo "Could not determine PGDATA size, proceeding with caution"
        pgdata_size=1048576  # Assume 1GB if we can't determine
    fi

    echo "PGDATA size: $((pgdata_size / 1024)) MB"

    # Calculate required space: 2 times PGDATA size + 1GB (in KB)
    local required_space=$((pgdata_size * 2 + 1048576))

    # Check /var/pv available space (df -k is POSIX compliant)
    var_pv_avail=$(df -Pk /var/pv 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$var_pv_avail" ]]; then
            var_pv_avail=0
    fi

    echo "/var/pv available space: $((var_pv_avail / 1024)) MB"
    echo "Required space: $((required_space / 1024)) MB"

    # Strategy 1: Try to backup to /var/pv/backup
    if [[ "$var_pv_avail" -gt "$required_space" ]]; then
        echo "Sufficient space in /var/pv, backing up PGDATA to /var/pv/backup"
        backup_location="/var/pv/backup/pgdata.backup.$(date +%s)"
        mkdir -p "$(dirname "$backup_location")"

        if mv "$pgdata_path" "$backup_location"; then
            echo "PGDATA backed up to $backup_location"
            # Create empty PGDATA directory
            mkdir -p "$pgdata_path"
            chmod 0700 "$pgdata_path"

            # Store backup location for cleanup after successful basebackup
            echo "$backup_location" > /tmp/pgdata_backup_location.txt
            return 0
        else
            echo "Failed to move PGDATA to $backup_location"
            return 1
        fi
    fi

    // TODO: Try to retun 1 and see if that fails the pipeline

    # Strategy 2: Try to backup to /tmp
    tmp_avail=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$tmp_avail" ]]; then
          tmp_avail=0
    fi

    echo "/tmp available space: $((tmp_avail / 1024)) MB"

    # For /tmp, we need at least PGDATA size (not 2x since it's different mount)
    if [[ "$tmp_avail" -gt "$pgdata_size" ]]; then
        echo "Sufficient space in /tmp, backing up PGDATA to /tmp/pgdata.backup"
        backup_location="/tmp/pgdata.backup.$(date +%s)"

        if mv "$pgdata_path" "$backup_location"; then
            echo "PGDATA backed up to $backup_location"
            # Create empty PGDATA directory
            mkdir -p "$pgdata_path"
            chmod 0700 "$pgdata_path"

            # Store backup location for cleanup after successful basebackup
            echo "$backup_location" > /tmp/pgdata_backup_location.txt
            return 0
        else
            echo "Failed to move PGDATA to $backup_location"
            return 1
        fi
    fi

    # No suitable backup location found
    echo "ERROR: Not enough disk space to safely backup PGDATA"
    echo "Required: $((required_space / 1024)) MB in /var/pv OR $((pgdata_size / 1024)) MB in /tmp"
    echo "Available: $((var_pv_avail / 1024)) MB in /var/pv, $((tmp_avail / 1024)) MB in /tmp"
    return 1
}

# Cleanup backup after successful operation
cleanup_pgdata_backup() {
    local backup_file="/tmp/pgdata_backup_location.txt"

    if [[ -f "$backup_file" ]]; then
        local backup_location=$(cat "$backup_file")
        if [[ -n "$backup_location" ]] && [[ -d "$backup_location" ]]; then
            echo "Basebackup successful, processing old PGDATA backup"

            # If backup is in /var/pv, check age before moving to /tmp
            if [[ "$backup_location" == /var/pv/* ]]; then
                # Get the modification time of the backup directory in seconds since epoch
                local backup_mtime=$(stat -c %Y "$backup_location" 2>/dev/null || stat -f %m "$backup_location" 2>/dev/null)
                local current_time=$(date +%s)
                local age_seconds=$((current_time - backup_mtime))
                local one_day_seconds=86400

                if [[ "$age_seconds" -gt "$one_day_seconds" ]]; then
                    echo "Backup is older than 1 day (age: $((age_seconds / 3600)) hours), moving to /tmp"
                    local tmp_backup="/tmp/pgdata.old.$(date +%s)"
                    if mv "$backup_location" "$tmp_backup" 2>/dev/null; then
                        echo "Old PGDATA moved to $tmp_backup"
                    else
                        echo "Could not move backup to /tmp, removing it"
                        rm -rf "$backup_location"
                    fi
                else
                    echo "Backup is less than 1 day old (age: $((age_seconds / 3600)) hours), keeping in /var/pv/backup"
                    echo "Backup will remain at: $backup_location"
                fi
            else
                echo "Backup already in /tmp at $backup_location"
            fi
        fi
        rm -f "$backup_file"
    fi
}

# Export functions if script is sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f safe_pgdata_backup
    export -f cleanup_pgdata_backup
fi
