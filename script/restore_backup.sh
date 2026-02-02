#!/bin/bash

# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/backup.lock"
exec 99> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance working on backup, exit"; exit 1; }

source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
xray_lock
uri_db_lock
tr_db_lock

ARCHIVE="$1"

if [[ -z $ARCHIVE || $# -gt 1 ]]; then
    echo "Use"
    echo "$0 archive_path"
    exit 1
fi

run_and_check() {
    action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# make absolute path
if [[ "$ARCHIVE" != /* ]]; then
    ARCHIVE="$(pwd)/$ARCHIVE"
fi

# check path
[[ -f "$ARCHIVE" ]] || { echo "❌ Error: file not found: $ARCHIVE, exit"; exit 1; }
[[ -r "$ARCHIVE" ]] || { echo "❌ Error: you do not have read permissions: $ARCHIVE, exit"; exit 1; }

# unpack
unpack_archive() {
    tar -xzf "$ARCHIVE" -C / || return 1
}
run_and_check "unpack archive" unpack_archive

# set permission and owners
chmod_out_file() {
    chmod 600 "/usr/local/etc/xray/URI_DB" || return 1
    chown telegram-gateway:telegram-gateway "/usr/local/etc/xray/URI_DB" || return 1

    chmod 600 "/var/log/xray/TR_DB_M" || return 1
    chown telegram-gateway:telegram-gateway "/var/log/xray/TR_DB_M" || return 1

    chmod 600 "/var/log/xray/TR_DB_Y" || return 1
    chown telegram-gateway:telegram-gateway "/var/log/xray/TR_DB_Y" || return 1

    chmod 660 "/usr/local/etc/xray/config.json" || return 1
    chown xray:telegram-gateway "/usr/local/etc/xray/config.json" || return 1
}
run_and_check "set permissions on files" chmod_out_file

echo "✅ Success: backup restored"
exit 0