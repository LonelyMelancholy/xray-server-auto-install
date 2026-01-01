#!/bin/bash
# script for notify after server up, via systemctl timer
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# exit codes work to tell systemd about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# wait for all service started
sleep 60

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/boot.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## boot notify started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## boot notify ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## boot notify failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/boot_notify.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# pure Telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${MESSAGE}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram message with logging and retry
telegram_message() {
    local attempt="1"
    local max_attempt="3"
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$max_attempt" ]]; then
                echo "❌ Error: failed to send Telegram message after $attempt attempts, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to Telegram after $attempt attempt"
            RC="0"
            return 0
        fi
    done
}

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%a' "$ENV_FILE" 2> /dev/null)" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

# wait for internet access
wait_internet() {
    local timeout=60
    local i
    for ((i=0; i<timeout; i++)); do
        ip route | grep 'default ' &> /dev/null || { sleep 2; continue; }
        getent ahosts api.telegram.org &> /dev/null || { sleep 2; continue; }
        curl -fsS -m 5 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' && return 0
        sleep 2
    done
    return 1
}

if wait_internet; then
    echo "✅ Success: internet is available"
else
    echo "❌ Error: no internet after 2 min, exit"
    exit 1
fi

# init system status
SYSTEM_STATUS="$(systemctl is-system-running)"

# critical daemon status
systemctl is-active --quiet ssh.socket && SSH_STATUS="running" || SSH_STATUS="fail"
systemctl is-active --quiet cron.service && CRON_STATUS="running" || CRON_STATUS="fail"
systemctl is-active --quiet fail2ban.service && FAIL2BAN_STATUS="running" || FAIL2BAN_STATUS="fail"
systemctl is-active --quiet xray.service && XRAY_STATUS="running" || XRAY_STATUS="fail"

# start collecting message
readonly HOSTNAME="$(hostname)"
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

# collecting title
if [[  "$SSH_STATUS" ==  "running" && "$CRON_STATUS" == "running" && "$FAIL2BAN_STATUS" == "running" && "$XRAY_STATUS" == "running" && "$SYSTEM_STATUS" == "running" ]]; then
TITLE="✅ <b>Server up, all services are running</b>"
SYSTEM_STATUS="⚫️ <b>Init system:</b> $SYSTEM_STATUS"
elif [[ "$SSH_STATUS" ==  "running" && "$CRON_STATUS" == "running" && "$FAIL2BAN_STATUS" == "running" && "$XRAY_STATUS" == "running" ]]; then
TITLE="⚠️ <b>Server up, non-critical service down</b>"
SYSTEM_STATUS="⚠️ <b>Init system:</b> $SYSTEM_STATUS"
else 
TITLE="❌ <b>Server up, critical service down</b>"
SYSTEM_STATUS="❌ <b>Init system:</b> $SYSTEM_STATUS"
fi

# helper func for make status
make_status() {
    if [[  "$1" ==  "running" ]]; then
        echo "⚫️ <b>${2}:</b> $1"
    else
        echo "❌ <b>${2}:</b> $1"
    fi
}
SSH_STATUS="$(make_status "$SSH_STATUS" "Status ssh")"
CRON_STATUS="$(make_status "$CRON_STATUS" "Status cron")"
FAIL2BAN_STATUS="$(make_status "$FAIL2BAN_STATUS" "Status fail2ban")"
XRAY_STATUS="$(make_status "$XRAY_STATUS" "Status xray")"

# collecting message body
MESSAGE="$TITLE

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
$SYSTEM_STATUS
$SSH_STATUS
$CRON_STATUS
$FAIL2BAN_STATUS
$XRAY_STATUS
💾 <b>Notify log:</b> $NOTIFY_LOG"

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC