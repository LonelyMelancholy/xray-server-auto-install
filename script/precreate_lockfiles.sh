#!/bin/bash
# for pred install all lock file, before other script start
# run from systemd

# main variables
LOCK_FILE="/run/lock/precreate_lockfiles.lock"
RC=1

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t precreate_lockfiles -p info) 2> >(systemd-cat -t precreate_lockfiles -p err) 5> >(systemd-cat -t precreate_lockfiles -p notice)

# start logging message
echo "precreate_lockfiles started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "precreate lockfiles ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "precreate lockfiles failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# root checking
[[ $EUID -ne 0 ]] && { echo "Error: you are not the root user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# lock file list
LOCK_FILES=(
    "/run/lock/boot_notify.lock"
    "/run/lock/cpu_alert.lock"
    "/run/lock/journald_alert.lock"
    "/run/lock/telegram_gateway.lock"
    "/run/lock/time_block.lock"
    "/run/lock/traffic_block.lock"
    "/run/lock/unattended_upgrade.lock"
    "/run/lock/xray_backup.lock"
    "/run/lock/xray_statistics.lock"
    "/run/lock/xray_update.lock"
    "/run/lock/xray.lock"
    "/run/lock/uri_db.lock"
    "/run/lock/tr_db.lock"
)

# permission only for read
LOCK_MODE=0644
LOCK_OWNER=root
LOCK_GROUP=root

for lock in "${LOCK_FILES[@]}"; do
    # if exist, delete and install new, else just install
    if [[ -e "$lock" ]]; then
        rm -rf "$lock" || { echo "Error: cannot be deleted '$lock', exit" >&2; exit 1; }
        install -m "$LOCK_MODE" -o "$LOCK_OWNER" -g "$LOCK_GROUP" "/dev/null" "$lock" || \
        { echo "Error: cannot be installed '$lock', exit" >&2; exit 1; }
    else
        install -m "$LOCK_MODE" -o "$LOCK_OWNER" -g "$LOCK_GROUP" "/dev/null" "$lock" || \
        { echo "Error: cannot be installed '$lock', exit" >&2; exit 1; }
    fi
done

RC=0

exit $RC
