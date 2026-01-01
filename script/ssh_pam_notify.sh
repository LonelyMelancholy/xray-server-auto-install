#!/bin/bash
# script for notify ssh login/unlogin via PAM
# exit 0 to avoid bothering PAM with an incorrect error code
# all errors are still logged, except the first three for debugging, add a redirect to the debug log

# sends the script to the background without delaying pam and send exit 0 to pam
if [[ -z "${TG_BG:-}" ]]; then
    export TG_BG=1
    "$0" "$@" &> /dev/null &
    exit 0
fi

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/ssh_pam.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## ssh pam notify started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## ssh pam notify ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## ssh pam notify failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# main variables
readonly HOSTNAME="$(hostname)"
readonly IP="$PAM_RHOST"
readonly USER="$PAM_USER"
readonly SESSION="$PAM_TYPE"
readonly MAX_ATTEMPTS="3"

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
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
                echo "❌ Error: failed to send Telegram message after $attempt attempt, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to Telegram after $attempt attempt"
            RC="0"
            break
        fi
    done
    return 0
}

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -c '%U:%a' "$ENV_FILE" 2>/dev/null)" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

# start collecting message
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

case "$SESSION" in
    open_session)
    MESSAGE="📢 <b>SSH PAM notify (login)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
🧑🏿‍💻 <b>User:</b> $USER
🏴 <b>From:</b> $IP
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    close_session)
    MESSAGE="📢 <b>SSH PAM notify (logout)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
🧑🏿‍💻 <b>User:</b> $USER
🏴 <b>From:</b> $IP
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    *)
    MESSAGE="⚠️ <b>SSH PAM notify (unknown)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
❌ Error: unknown PAM session type, check settings
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
esac

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC