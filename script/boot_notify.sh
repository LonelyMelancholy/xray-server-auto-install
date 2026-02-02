#!/bin/bash
# script for notify after server up, via systemctl timer
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# exit codes work to tell systemd about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# wait for all service started
sleep 200

# enable logging
NOTIFY_LOG="/var/log/telegram/boot.$(date '+%Y-%m-%d').log"
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
echo "########## boot notify started - $(date '+%Y-%m-%d %H:%M:%S') ##########"

# exit logging message function
RC_M="1"
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "########## boot notify ended - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    else
        echo "########## boot notify failed - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/boot_notify.lock"
exec 99> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance is running, exit"; exit 1; }

source "/usr/local/lib/service/telegram.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit"; exit 1; }

# wait for internet access
wait_internet() {
    local timeout=60
    local i
    for ((i=0; i<timeout; i++)); do
        ip route | grep 'default ' &> /dev/null || { sleep 2; continue; }
        getent ahosts api.telegram.org &> /dev/null || { sleep 2; continue; }
        curl -fsS -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' && return 0
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
systemctl is-active --quiet nginx.service && NGINX_STATUS="running" || NGINX_STATUS="fail"
systemctl is-active --quiet xray.service && XRAY_STATUS="running" || XRAY_STATUS="fail"

# start collecting message
# collecting title
if [[  "$SSH_STATUS" ==  "running" && "$CRON_STATUS" == "running" && "$FAIL2BAN_STATUS" == "running" && "$NGINX_STATUS" == "running" && "$XRAY_STATUS" == "running" && "$SYSTEM_STATUS" == "running" ]]; then
TITLE="✅ <b>Server up, all services are running</b>"
SYSTEM_STATUS="☑️ <b>Init system:</b> $SYSTEM_STATUS"
elif [[ "$SSH_STATUS" ==  "running" && "$CRON_STATUS" == "running" && "$FAIL2BAN_STATUS" == "running" && "$NGINX_STATUS" == "running" && "$XRAY_STATUS" == "running" ]]; then
TITLE="⚠️ <b>Server up, non-critical service down</b>"
SYSTEM_STATUS="⚠️ <b>Init system:</b> $SYSTEM_STATUS"
else 
TITLE="❌ <b>Server up, critical service down</b>"
SYSTEM_STATUS="❌ <b>Init system:</b> $SYSTEM_STATUS"
fi

# helper func for make status
make_status() {
    if [[  "$1" ==  "running" ]]; then
        echo "☑️ <b>${2}:</b> $1"
    else
        echo "❌ <b>${2}:</b> $1"
    fi
}
SSH_STATUS="$(make_status "$SSH_STATUS" "Status ssh")"
CRON_STATUS="$(make_status "$CRON_STATUS" "Status cron")"
FAIL2BAN_STATUS="$(make_status "$FAIL2BAN_STATUS" "Status fail2ban")"
NGINX_STATUS="$(make_status "$NGINX_STATUS" "Status nginx")"
XRAY_STATUS="$(make_status "$XRAY_STATUS" "Status xray")"

# collecting message body
MESSAGE="$TITLE

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
$SYSTEM_STATUS
$SSH_STATUS
$CRON_STATUS
$FAIL2BAN_STATUS
$NGINX_STATUS
$XRAY_STATUS
💾 <b>Notify log:</b> $NOTIFY_LOG"

# logging message
echo "########## collected message - $(date '+%Y-%m-%d %H:%M:%S') ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC_M