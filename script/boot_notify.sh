#!/bin/bash
# script for notify after server up, via systemd timer
# all errors are logged in journald, see journalctl -t boot_notify
# exit codes work to tell systemd about success sending message

# main variables
RC_M=1
readonly LOCK_FILE="/run/lock/boot_notify.lock"

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t boot_notify -p info) 2> >(systemd-cat -t boot_notify -p err) 5> >(systemd-cat -t boot_notify -p notice)

# start logging message
echo "boot notify started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "boot notify ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "boot notify failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# function section
# wait for internet access function
wait_internet() {
    local timeout=60
    local i
    for ((i=0; i<timeout; i++)); do
        ip route  2> /dev/null | grep 'default ' &> /dev/null || { sleep 2; continue; }
        getent ahosts api.telegram.org &> /dev/null || { sleep 2; continue; }
        curl -fsS -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' && return 0
        sleep 2
    done
    return 1
}

# critical daemon status function
daemon_status() {
    local service="$1"
    local name="$2"
    if systemctl is-active --quiet "$service" &> /dev/null; then
        echo "☑️ <b>Status $name:</b> running"
    else
        echo "❌ <b>Status $name:</b> fail"
        return 1
    fi
}

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# main logic start here
# wait for all service started 5m
sleep 300

# internet check 2m, exit if offline
if wait_internet; then
    echo "Success: internet is available"
else
    echo "Error: no internet after 7 min, exit" >&2
    exit 1
fi

# init system status
SYSTEM_STATUS="$(systemctl is-system-running)"

# common status critical service
COMMON_STATUS=0

# critical daemon status
SSH_STATUS="$(daemon_status ssh.socket ssh)" || COMMON_STATUS=1
FAIL2BAN_STATUS="$(daemon_status fail2ban.service fail2ban)" || COMMON_STATUS=1
NGINX_STATUS="$(daemon_status nginx.service nginx)" || COMMON_STATUS=1
XRAY_STATUS="$(daemon_status xray.service xray)" || COMMON_STATUS=1
NFTABLES_STATUS="$(daemon_status nftables.service nftables)" || COMMON_STATUS=1

# start collecting message parts
if [[  $COMMON_STATUS == 0 && "$SYSTEM_STATUS" == "running" ]]; then
    MESSAGE_TITLE="✅ <b>Server up, all services are running</b>"
    SYSTEM_STATUS="☑️ <b>Init system:</b> $SYSTEM_STATUS"
elif [[ $COMMON_STATUS == 0 ]]; then
    MESSAGE_TITLE="⚠️ <b>Server up, non-critical service down</b>"
    SYSTEM_STATUS="⚠️ <b>Init system:</b> $SYSTEM_STATUS"
else 
    MESSAGE_TITLE="❌ <b>Server up, critical service down</b>"
    SYSTEM_STATUS="❌ <b>Init system:</b> $SYSTEM_STATUS"
fi

# collecting full message
MESSAGE="$MESSAGE_TITLE

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
$SYSTEM_STATUS
$SSH_STATUS
$FAIL2BAN_STATUS
$NFTABLES_STATUS
$NGINX_STATUS
$XRAY_STATUS
💾 <b>Notify log:</b> journalctl -t boot_notify"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message

exit $RC_M
