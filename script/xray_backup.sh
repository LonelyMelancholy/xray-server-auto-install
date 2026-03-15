#!/bin/bash
# script for xray backup via systemd timer every first day month, 0:03 night time
# all errors are logged in journald, see journalctl -t xray_backup
# exit codes work to tell systemd about success sending file

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# restart script for target user if have sudo without password
if [ "$(id -un)" != "$TARGET_USER" ]; then
    if ! exec sudo -n -u "$TARGET_USER" -- "$0" "$@"; then
        echo "❌ Error: failed to restart the script as user '$TARGET_USER'"
        exit 1
    fi
fi

# umask for not allow anyone read backup or file copy
umask 077

# enable logging
exec > >(systemd-cat -t xray_backup -p info) 2> >(systemd-cat -t xray_backup -p err) 5> >(systemd-cat -t xray_backup -p notice)

# start logging message
echo "backup started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC_F" -eq "0" ]]; then
        echo "backup ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "backup failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    echo "cleaning start - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -rf "$TMPDIR" "$BACKUP_FILE_PATH" > /dev/null; then
        echo "Success: delete tmp files"
        echo "cleaning ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "Error: delete tmp files" >&2
        echo "cleaning failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log and cleanup
trap 'end_log; rm_tmp;' EXIT

# make tmp directory
TMPDIR="$(mktemp -d)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "Error: you are not the '$TARGET_USER' user, exit" >&2; exit 1; }

# main variables
readonly ONLY_ARCHIVE="$1"

# check arguments
if [[ "$ONLY_ARCHIVE" != "manual" && "$ONLY_ARCHIVE" != "auto" || $# -ne 1 ]]; then
    echo "Use for backup xray"
    echo "run: $0 auto|manual"
    echo "auto - for auto backup with message"
    echo "manual - for only archive to Telegram, no message"
    exit 0
fi

# source Telegram func library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "xray_backup"

# lock check
run_lock_wait "xray" "600"
run_lock_wait "uri_db" "600"
run_lock_wait "tr_db" "600"

# read permission check
read_check "$XRAY_CONFIG"
read_check "$URI_DB"
read_check "$TR_DB_M"
read_check "$TR_DB_Y"

# function section
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
for file in "${FILES_TO_BACKUP[@]}"; do
    run_and_check "copy $file to tmp directory" cp --parents -f "$file" "$TMPDIR/"
done

# packed
run_and_check "packed backup archive" tar -C "$TMPDIR" -czf "$BACKUP_FILE_PATH" .

# send message and file or just file
if [[ "$ONLY_ARCHIVE" == "manual" ]]; then
    if telegram_file; then
        echo "✅ Success: backup was sent to the notification channel"
    else
        echo "❌ Error: failed to send backup to the notification channel" >&2
        exit $RC_F
    fi
else
    # start collecting message
    MESSAGE="📢<b> Scheduled backup</b> 

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
💾 <b>Backup log:</b> journalctl -t xray_backup"

    # logging message
    echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "$MESSAGE"

    # send message
    telegram_message "$MESSAGE"
    
    # send file
    telegram_file "$BACKUP_FILE_PATH" "$BACKUP_FILE_NAME"
fi

# if backup successuful send, delete all old backups
if [[ $RC_F == 0 ]]; then
    run_and_check "delete all old '.bak' files" rm -f -- /usr/local/etc/xray/*.bak.*
fi

# exit with file delivery status
exit $RC_F
