#!/bin/bash

# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/backup.lock"
exec 99> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance working on backup, exit"; exit 1; }

# main variables
ARCHIVE="$1"
URI_DB="/usr/local/etc/xray/URI_DB"
TR_DB_M="/var/log/xray/TR_DB_M"
TR_DB_Y="/var/log/xray/TR_DB_Y"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check xray
run_lock_check uri_db
run_lock_check tr_db

# read and write conf check
read_and_write_check "$URI_DB" "console"
read_and_write_check "$TR_DB_M" "console"
read_and_write_check "$TR_DB_Y" "console"
read_and_write_check "$XRAY_CONFIG" "console"

# argument check
if [[ -z $ARCHIVE || $# -ne 1 || "$ARCHIVE" == "--help" ]]; then
    echo "Use for restore backup"
    echo "$0 archive_path"
    exit 0
fi

# make absolute path
if [[ "$ARCHIVE" != /* ]]; then
    ARCHIVE="$(realpath "$ARCHIVE")"
fi

# check path
read_check "$ARCHIVE"

# help function
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# unpack function
unpack_archive() {
    tar -xzf "$ARCHIVE" -C / || return 1
}

# set permission and owners function
chmod_out_file() {
    chmod 660 "$URI_DB" || return 1
    chown root:telegram-gateway "$URI_DB" || return 1

    chmod 660 "$TR_DB_M" || return 1
    chown root:telegram-gateway "$TR_DB_M" || return 1

    chmod 660 "$TR_DB_Y" || return 1
    chown root:telegram-gateway "$TR_DB_Y" || return 1

    chmod 660 "$XRAY_CONFIG" || return 1
    chown root:xray_config_group "$XRAY_CONFIG" || return 1
}

# main logic start here
run_and_check "unpack archive and copy files" unpack_archive
run_and_check "set permissions to files" chmod_out_file
echo "✅ Success: backup restored"

exit 0