#!/bin/bash
# script for xray backup via cron 23:00 night time last day month
# all errors are logged in journald, see journalctl -t xray_backup
# 0 23 28-31 * * root [ "$(date -v+1d +\%d)" = "01" ] && "/usr/local/bin/service/xray_backup.sh"
# exit codes work to tell Cron about success

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# main variables
ONLY_ARCHIVE="$1"
RC_F=1
readonly LOCK_FILE="/run/lock/backup.lock"
readonly FILES=("$XRAY_CONFIG" "$URI_DB" "$TR_DB_M" "$TR_DB_Y")
readonly FILE_NAME="xray_backup_$(hostname)_$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
readonly FILE_PATH="/tmp/${FILE_NAME}"

# umask for not allow anyone read backup
umask 077

# enable logging
exec > >(systemd-cat -t xray_backup -p info) 2> >(systemd-cat -t xray_backup -p err) 5> >(systemd-cat -t xray_backup -p notice)

# start logging message
echo "backup started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit"; exit 1; } >&2

# check arguments
if [[ "$ONLY_ARCHIVE" != 1 && "$ONLY_ARCHIVE" != 0 ]]; then
    echo "Use for backup xray, run: $0 0|1"
    echo "0 - for auto backup with message"
    echo "1 - for only archive to Telegram, no message"
    exit 0
fi

# make tmp directory
TMPDIR="$(mktemp -d)"

# exit logging message function
# shellcheck disable=SC2329
on_exit() {
    if [[ "$RC_F" -eq "0" ]]; then
        echo "backup ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "backup failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp_config() {
    echo "cleaning start - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -rf "$TMPDIR" "$FILE_PATH" > /dev/null; then
        echo "Success: delete tmp files"
        echo "cleaning ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "Error: delete tmp files" >&2
        echo "cleaning failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log and cleanup
trap 'on_exit; rm_tmp_config;' EXIT

# check another instanсe of the script is not running
exec 99> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n 99 || { echo "Error: another instance working on backup, exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
run_lock_retry_check "xray"
run_lock_retry_check "tr_db"
run_lock_retry_check "uri_db"

# read permission check
read_check "$XRAY_CONFIG"
read_check "$URI_DB"
read_check "$TR_DB_M"
read_check "$TR_DB_Y"

# source Telegram func library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# helper func
# shellcheck disable=SC2329
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "Success: $action"
    else
        echo "Error: $action, exit" >&2
        exit 1
    fi
}

# main logic start here
# copy each file from arrray to temp directory
# save parents directory sctucture
for file in "${FILES[@]}"; do
    run_and_check "copy $file to tmp directory" cp --parents -f "$file" "$TMPDIR/"
done

# packed
run_and_check "packed backup archive" tar -C "$TMPDIR" -czf "$FILE_PATH" .

# send message and file or just file
if [[ "$ONLY_ARCHIVE" == 1 ]]; then
    telegram_file
else
    # start collecting message
    MESSAGE="📢<b> Scheduled backup</b> 

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
💾 <b>Backup log:</b> journalctl -t xray_backup"

    # logging message
    echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "$MESSAGE"

    # send message
    telegram_message
    
    # send file
    telegram_file
fi

exit $RC_F