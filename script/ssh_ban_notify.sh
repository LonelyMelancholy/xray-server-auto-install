#!/bin/bash
# done
# fail2ban Telegram ssh notify
# arguments: <action> <ip> <bantime_sec>
# exit 0 to avoid bothering fail2ban with an incorrect error code, all errors are still logged exept 3 first

# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 0; }

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/f2b.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 0; }
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 0; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "   ########## fail2ban notify started - $DATE_START ##########   "

# exit log message function
RC=1
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "   ########## fail2ban notify ended - $DATE_END ##########   "
    else
        DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "   ########## fail2ban notify failed - $DATE_FAIL ##########   "
    fi
}

# error exit log message for end log
trap 'on_exit' EXIT

# main variable
readonly ACTION="${1:-unknown}"
readonly IP="${2:-unknown}"
readonly BANTIME_SEC="${3:-0}"
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS=3

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

# pure telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MESSAGE}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# telegram message with logging and retry
telegram_message() {
    local attempt=1
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
                echo "❌ Error: failed to send telegram message after $attempt attempts, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to telegram after $attempt attempts"
            RC=0
            break
        fi
    done
}

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -c '%U:%a' "$ENV_FILE" 2>/dev/null)" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 0
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 0; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 0; }

# start collecting message
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

case "$ACTION" in
    ban)
MESSAGE="⚠️  SSH jail notify (ban)

🖥️  Host: $HOSTNAME
⌚ Time: $DATE_MESSAGE
💀 Banned for: $BAN_TIME in jail
🏴‍☠️ From: $IP
💾 Fail2ban log: '/var/log/fail2ban.log'
💾 Notify log: '$NOTIFY_LOG'"
    ;;
    unban)
MESSAGE="⚠️  SSH jail notify (unban)

🖥️  Host: $HOSTNAME
⌚ Time: $DATE_MESSAGE
💀 Unbanned after: $BAN_TIME in jail
🏴‍☠️ From: $IP
💾 Fail2ban log: '/var/log/fail2ban.log'
💾 Notify log: '$NOTIFY_LOG'"
    ;;
    *)
MESSAGE="⚠️  SSH jail notify (unknown)

🖥️  Host: $HOSTNAME
⌚ Time: $DATE_MESSAGE
❌ Error: unknown fail2ban action, check settings
💾 Fail2ban log: '/var/log/fail2ban.log'
💾 Notify log: '$NOTIFY_LOG'"
    ;;
esac

# logging message
echo "   ########## collected message - $DATE_MESSAGE ##########   "
echo "$MESSAGE"

# send message
telegram_message

exit 0