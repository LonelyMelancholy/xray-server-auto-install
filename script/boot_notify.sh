#!/bin/bash
# script for notify after server up, via systemctl timer
# all errors are logged in journald, see journalctl -t boot_notify
# exit codes work to tell systemd about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t boot_notify -p info) 2> >(systemd-cat -t boot_notify -p error)

# main variables
RC_M=1

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "Error: you are not the telegram-gateway user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/boot_notify.lock"
exec 99> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n 99 || { echo "Error: another instance is running, exit" >&2; exit 1; }

# start logging message
echo "boot notify started - $(date '+%Y-%m-%d %H:%M:%S')"

# function section
# exit logging message function
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "boot notify ended - $(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "boot notify failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# wait for internet access func
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

# critical daemon status func
daemon_status() {
    local service="$1"
    local name="$2"
    if systemctl is-active --quiet "$service"; then
        echo "☑️ <b>Status $name:</b> running"
    else
        echo "❌ <b>Status $name:</b> fail"
        COMMON_STATUS=1
    fi
}

# source Telegram func library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }


# main logic start here
# wait for all service started
sleep 180

# internet check, exit if offline
if wait_internet; then
    echo "Success: internet is available"
else
    echo "Error: no internet after 5 min, exit" >&2
    exit 1
fi

# init system status
SYSTEM_STATUS="$(systemctl is-system-running)"

# common status critical service
COMMON_STATUS=0

# critical daemon status
SSH_STATUS="$(daemon_status ssh.socket ssh)"
CRON_STATUS="$(daemon_status cron.service cron)"
FAIL2BAN_STATUS="$(daemon_status fail2ban.service fail2ban)"
NGINX_STATUS="$(daemon_status nginx.service nginx)"
XRAY_STATUS="$(daemon_status xray.service xray)"

# start collecting message
if [[  $COMMON_STATUS == 0 && "$SYSTEM_STATUS" == "running" ]]; then
    TITLE="✅ <b>Server up, all services are running</b>"
    SYSTEM_STATUS="☑️ <b>Init system:</b> $SYSTEM_STATUS"
elif [[ $COMMON_STATUS == 0 ]]; then
    TITLE="⚠️ <b>Server up, non-critical service down</b>"
    SYSTEM_STATUS="⚠️ <b>Init system:</b> $SYSTEM_STATUS"
else 
    TITLE="❌ <b>Server up, critical service down</b>"
    SYSTEM_STATUS="❌ <b>Init system:</b> $SYSTEM_STATUS"
fi

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
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"
# send message
telegram_message

exit $RC_M