#!/bin/bash
# script for notify ban/unban via ssh fail2ban action
# arguments: <action> <ip> <bantime_sec>
# exit 0 to avoid bothering fail2ban with an incorrect error code
# all errors are logged in journald, see journalctl -t ssh_f2b_notify

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t ssh_f2b_notify -p info) 2> >(systemd-cat -t ssh_f2b_notify -p error)

# sends the script to the background from telegram-gateway, without delaying pam and send exit 0 to pam
TARGET_USER="telegram-gateway"
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

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "Error: you are not the telegram-gateway user, exit" >&2; exit 1; }

# start logging message
echo "ssh fail2ban notify started - $(date '+%Y-%m-%d %H:%M:%S')"

# main variables
RC_M=1
readonly ACTION="${1:-unknown}"
readonly IP="${2:-unknown}"
readonly BANTIME_SEC="${3:-0}"

# exit logging message function
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "ssh fail2ban notify ended - $(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "ssh fail2ban notify failed - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# function to calculate the ban time
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
readonly BAN_TIME="$(duration_human "$BANTIME_SEC")"

# start collecting message
case "$ACTION" in
    ban)
MESSAGE="📢 <b>SSH fail2ban notify (ban)</b>

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
💀 <b>Banned for:</b> $BAN_TIME in jail
🏴‍☠️ <b>From:</b> $IP
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> journalctl -t ssh_f2b_notify"
    ;;
    unban)
MESSAGE="📢 <b>SSH fail2ban notify (unban)</b>

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
💀 <b>Unbanned after:</b> $BAN_TIME in jail
🏴‍☠️ <b>From:</b> $IP
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> journalctl -t ssh_f2b_notify"
    ;;
    *)
MESSAGE="⚠️ <b>SSH fail2ban notify (unknown)</b>

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
❌ <b>Error:</b> unknown fail2ban action, check settings
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> journalctl -t ssh_f2b_notify"
    ;;
esac

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# send message
telegram_message

exit $RC_M