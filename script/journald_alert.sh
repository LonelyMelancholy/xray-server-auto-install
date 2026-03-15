#!/bin/bash
# script for send alert errors in journald (level err-crit-alert-emerg) via Telegram
# all errors are logged in journald, see journalctl -t journald_alert

# enable logging
exec > >(systemd-cat -t journald_alert -p info) 2> >(systemd-cat -t journald_alert -p err) 5> >(systemd-cat -t journald_alert -p notice)

# start logging message
echo "journald alert started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    echo "journald alert stopped - $(date '+%Y-%m-%d %H:%M:%S')" >&5
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "Error: you are not the '$TARGET_USER' user, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "journald_alert"

# main logic start here
# if have cursor file, load for start point
CURSOR_ARGS=()
if [[ -f "$STATE_FILE" ]]; then
    CURSOR_ARGS=(--after-cursor "$(cat "$STATE_FILE")")
fi

# run eternal cycle and and catch messages
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
    MESSAGE="🚨 <b>Journald error alert</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
🚨 <b>Error level:</b> ${ERROR_LEVEL[$prio]}
⚙️ <b>Unit:</b> ${unit}
📑 <b>Message:</b> ${msg}
💾 <b>Alert log:</b> journalctl -t journald_alert"

    # logging message
    echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "$MESSAGE"
    
    # send message
    telegram_message "$MESSAGE"

    # sleep for message frequency reduction
    sleep 1
done
