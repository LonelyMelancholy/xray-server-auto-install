#!/bin/bash
# script for restore server backup from archive

# main variables
ARCHIVE="$1"

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# argument checking
if [[ $# -ne 1 || "$ARCHIVE" == "--help" ]]; then
    echo "Use for restore backup"
    echo "run: $0 archive_path"
    exit 0
fi

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "uri_db" "console"
run_lock_check "tr_db" "console"

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
# shellcheck disable=SC2329
unpack_archive() {
    tar -xzf "$ARCHIVE" -C / || return 1
}

# set permission and owners function
# shellcheck disable=SC2329
chmod_out_file() {
    chmod 660 "$URI_DB" || return 1
    chown root:telegram_gateway "$URI_DB" || return 1

    chmod 660 "$TR_DB_M" || return 1
    chown root:telegram_gateway "$TR_DB_M" || return 1

    chmod 660 "$TR_DB_Y" || return 1
    chown root:telegram_gateway "$TR_DB_Y" || return 1

    chmod 660 "$XRAY_CONFIG" || return 1
    chown root:xray_read_write_group "$XRAY_CONFIG" || return 1
}

# main logic start here
# make absolute path
if [[ "$ARCHIVE" != /* ]]; then
    ARCHIVE="$(realpath "$ARCHIVE")"
fi

# check path
read_check "$ARCHIVE" "console"

run_and_check "unpack archive and copy files" unpack_archive
run_and_check "set permissions to files" chmod_out_file
echo "✅ Success: backup restored"

exit 0
