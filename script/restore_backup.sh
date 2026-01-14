#!/bin/bash

# root checking
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: you are not the root user, exit"
    exit 1
else
    echo "✅ Success: you are root user, continued"
fi

# check another instanсe of the script is not running
readonly LOCK_FILE_5="/run/lock/backup.lock"
exec 99> "$LOCK_FILE_5" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_5', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance working on backup, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 8 || { echo "❌ Error: another instance working on xray config, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE_2="/run/lock/uri_db.lock"
exec 9> "$LOCK_FILE_2" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_2', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on URI_DB, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE_3="/run/lock/tr_db.lock"
exec 10> "$LOCK_FILE_3" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_3', exit"; exit 1; }
flock -n 10 || { echo "❌ Error: another instance working on TR_DB, exit"; exit 1; }

ARCHIVE="$1"

if [[ -z $ARCHIVE || $# -gt 1 ]]; then
    echo "Use"
    echo "$0 archive_path"
    exit 1
fi

run_and_check() {
    local action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
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