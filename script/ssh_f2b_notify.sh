#!/bin/bash
# script for notify ban/unban via ssh fail2ban action
# arguments: <action> <ip> <bantime_sec>
# exit 0 to avoid bothering fail2ban with an incorrect error code
# all errors are logged in journald, see journalctl -t ssh_f2b_notify

# main variables
RC_M=1
readonly ACTION="${1:-unknown}"
readonly IP="${2:-unknown}"
readonly BANTIME_SEC="${3:-0}"
readonly TARGET_USER="telegram_gateway"

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# sends the script to the background from telegram_gateway, without delaying pam and send exit 0 to pam
if [[ -z "${TG_BG:-}" ]]; then
    export TG_BG=1
    if [[ "$(whoami)" != "$TARGET_USER" ]]; then
        /usr/bin/setpriv \
        --reuid="$TARGET_USER" \
        --regid="$TARGET_USER" \
        --init-groups \
        --inh-caps=-all \
        -- "$0" "$@" &> /dev/null &
    else
        "$0" "$@" &> /dev/null &
    fi
    exit 0
fi

# enable logging
exec > >(systemd-cat -t ssh_f2b_notify -p info) 2> >(systemd-cat -t ssh_f2b_notify -p err) 5> >(systemd-cat -t ssh_f2b_notify -p notice)

# start logging message
echo "ssh fail2ban notify started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# user check
[[ "$(whoami)" != "$TARGET_USER" ]] && { echo "Error: you are not the $TARGET_USER user, exit" >&2; exit 1; }

# exit logging message function
# shellcheck disable=SC2329
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "ssh fail2ban notify ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "ssh fail2ban notify failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# function to calculate human readable values ban time
duration_human() {
    local -i total="$1"
    local -i d h m s
    d="$(( total / 86400 ))"
    h="$(( (total % 86400) / 3600 ))"
    m="$(( (total % 3600) / 60 ))"
    s="$(( total % 60 ))"

    # show bigger units only if non-zero
    if [[ "$d" -gt "0" ]]; then
        echo "$d days, $h hours, $m min, $s sec"
    elif [[ "$h" -gt "0" ]]; then
        echo "$h hours, $m min, $s sec"
    elif [[ "$m" -gt "0" ]]; then
        echo "$m min, $s sec"
    elif [[ "$s" -gt "0" ]]; then
        echo "$s sec"
    else
        echo "unknown time"
    fi
}

# source Telegram func library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# main logic start here
# converting seconds to human readable values
readonly BAN_TIME="$(duration_human "$BANTIME_SEC")"

# start collecting message parts
case "$ACTION" in
    ban)
        MESSAGE_TITLE="📢 <b>SSH fail2ban notify (ban)</b>"
        MESSAGE_ACTION="💀 <b>Banned for:</b> $BAN_TIME in jail"$'\n'"🏴‍☠️ <b>From:</b> $IP"
    ;;
    unban)
        MESSAGE_TITLE="📢 <b>SSH fail2ban notify (unban)</b>"
        MESSAGE_ACTION="💀 <b>Unbanned after:</b> $BAN_TIME in jail"$'\n'"🏴‍☠️ <b>From:</b> $IP"
    ;;
    *)
        MESSAGE_TITLE="⚠️ <b>SSH fail2ban notify (unknown)</b>"
        MESSAGE_ACTION="❌ <b>Error:</b> unknown fail2ban action, check settings"
    ;;
esac

# collecting full message
MESSAGE="${MESSAGE_TITLE}

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
${MESSAGE_ACTION}
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> journalctl -t ssh_f2b_notify"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message

exit $RC_M