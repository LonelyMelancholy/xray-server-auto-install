#!/bin/bash
# script for notify ban/unban via ssh fail2ban action
# arguments: <action> <ip> <bantime_sec>
# exit 0 to avoid bothering fail2ban with an incorrect error code
# all errors are still logged, except the first three for debugging, add a redirect to the debug log

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

TARGET_USER="telegram-gateway"

# sends the script to the background from telegram-gateway, without delaying pam and send exit 0 to pam
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
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/ssh_f2b.${DATE_LOG}.log"
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## ssh fail2ban notify started - $DATE_START ##########"

# exit logging message function
RC_M="1"
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## ssh fail2ban notify ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## ssh fail2ban notify failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

source "/usr/local/lib/service/telegram.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit"; exit 1; }

# main variables
readonly ACTION="${1:-unknown}"
readonly IP="${2:-unknown}"
readonly BANTIME_SEC="${3:-0}"
readonly HOSTNAME="$(hostname)"

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
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

case "$ACTION" in
    ban)
MESSAGE="📢 <b>SSH fail2ban notify (ban)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
💀 <b>Banned for:</b> $BAN_TIME in jail
🏴‍☠️ <b>From:</b> $IP
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    unban)
MESSAGE="📢 <b>SSH fail2ban notify (unban)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
💀 <b>Unbanned after:</b> $BAN_TIME in jail
🏴‍☠️ <b>From:</b> $IP
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    *)
MESSAGE="⚠️ <b>SSH fail2ban notify (unknown)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
❌ <b>Error:</b> unknown fail2ban action, check settings
💾 <b>Fail2ban log:</b> /var/log/fail2ban.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
esac

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC_M