#!/bin/bash
# script for notify errors in journalctl level err-crit-alert-emerg via Telegram
# all errors are logged in journald, see journalctl -t journalctl_notify

# main variables
readonly LOCK_FILE="/run/lock/journalctl_notify.lock"
readonly STATE_FILE="/var/tmp/journalctl_notify.last_cursor"

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# array for error level in message
declare -A ERROR_LEVEL
ERROR_LEVEL=(
    [0]="emergency"
    [1]="alert"
    [2]="critical"
    [3]="error"
)

# if have cursor file, load for start point
CURSOR_ARGS=()
if [[ -f "$STATE_FILE" ]]; then
    CURSOR_ARGS=(--after-cursor "$(cat "$STATE_FILE")")
fi

# enable logging
exec > >(systemd-cat -t journalctl_notify -p info) 2> >(systemd-cat -t journalctl_notify -p err) 5> >(systemd-cat -t journalctl_notify -p notice)

# start logging message
echo "journalctl notify started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# exit logging message function
# shellcheck disable=SC2329
on_exit() {
    echo "journalctl notify ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
}

# trap for the end log message for the end log
trap on_exit EXIT

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# main logic start here
journalctl -b -f -p err..emerg -o json --no-pager "${CURSOR_ARGS[@]}" |
while IFS= read -r json; do
    # save cursor for restart
    cursor=$(jq -r '.__CURSOR // empty' <<<"$json")
    [[ -n "$cursor" ]] && printf '%s' "$cursor" >"$STATE_FILE"

    # set variables
    unit=$(jq -r '.SYSLOG_IDENTIFIER // empty' <<<"$json")
    msg=$(jq -r '.MESSAGE // empty' <<<"$json")
    prio=$(jq -r '.PRIORITY // empty' <<<"$json")

    # collect message
    MESSAGE="❌<b> Journalctl error report</b> 

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
🚨 <b>Error level:</b> ${ERROR_LEVEL[$prio]}
⚙️ <b>Unit:</b> ${unit}
📑 <b>Messsage:</b> ${msg}
💾 <b>Notify log:</b> journalctl -t journalctl_notify"
    
    # send message
    telegram_message
done