#!/bin/bash
# script for notify after server up, via systemd timer
# all errors are logged in journald, see journalctl -t boot_notify
# exit codes work to tell systemd about success sending message

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
run_lock_check "boot_notify"

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

# main logic start here
# wait for all service started 1m
sleep 60

# internet check 2m, exit if offline
if wait_internet; then
    echo "Success: internet is available"
else
    echo "Error: no internet after 3 min from server boot, exit" >&2
    exit 1
fi

# init system status
SYSTEM_STATUS="$(systemctl is-system-running)"

# critical daemon status
SSH_STATUS="$(daemon_status ssh.socket ssh)" || COMMON_STATUS=1
FAIL2BAN_STATUS="$(daemon_status fail2ban.service fail2ban)" || COMMON_STATUS=1
NGINX_STATUS="$(daemon_status nginx.service nginx)" || COMMON_STATUS=1
XRAY_STATUS="$(daemon_status xray.service xray)" || COMMON_STATUS=1
NFTABLES_STATUS="$(daemon_status nftables.service nftables)" || COMMON_STATUS=1

# start collecting message parts
if [[ $COMMON_STATUS != 1 ]] && [[ "$SYSTEM_STATUS" == "running" || "$SYSTEM_STATUS" == "starting" ]]; then
    MESSAGE_TITLE="✅ <b>Server up, all services are running</b>"
    SYSTEM_STATUS="☑️ <b>Init system:</b> $SYSTEM_STATUS"
elif [[ $COMMON_STATUS != 1 ]]; then
    MESSAGE_TITLE="⚠️ <b>Server up, non-critical service down</b>"
    SYSTEM_STATUS="⚠️ <b>Init system:</b> $SYSTEM_STATUS"
else 
    MESSAGE_TITLE="❌ <b>Server up, critical service down</b>"
    SYSTEM_STATUS="❌ <b>Init system:</b> $SYSTEM_STATUS"
fi

# collecting full message
MESSAGE="$MESSAGE_TITLE

🖥️ <b>Host:</b> ${HOST_TAG}
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
telegram_message "$MESSAGE"

# exit with message delivery status
exit $RC_M
