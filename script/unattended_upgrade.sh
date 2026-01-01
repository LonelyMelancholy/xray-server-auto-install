#!/bin/bash
# auto install upgrade (unattended-upgrade) and send notify via cron every first day month, 3:01 night time
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 1 3 1 * * root /usr/local/bin/service/unattended_upgrade.sh &> /dev/null
# exit codes work to tell Cron about success

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly UPGRADE_LOG="${LOG_DIR}/unattended-upgrade.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$UPGRADE_LOG" || { echo "❌ Error: cannot write to log '$UPGRADE_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## unattended upgrade started - $DATE_START ##########"

# exit logging message function
RC="1"
REBOOT="0"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## unattended upgrade ended - $date_end ##########"
        [[ "$REBOOT" -eq "1" ]] && reboot
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## unattended upgrade failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instance of the script is not running
readonly LOCK_FILE="/var/run/unattended_upgrade.lock"
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
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
                echo "❌ Error: failed to send Telegram message after $attempt attempts, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to Telegram after $attempt attempt"
            return 0
        fi
    done
}

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%a' "$ENV_FILE")" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

# main variables
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS="3"
readonly TODAY="$(date +%Y-%m-%d)"

# main logic start here
DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"
MESSAGE="⚠️ <b>Scheduled security upgrade</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
⚫️ <b>Action:</b> upgrade started"

echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"
telegram_message

update_and_upgrade() {
    local action="$1"
    shift 1
    local attempt=1

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first one)
        if "$@"; then
            echo "✅ Success: $action completed"
            RC="0"
            return 0
            
        fi
        if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
            sleep 60
            echo "⚠️  Non-critical error: $action failed, trying again"
            ((attempt++))
            continue
        else
            echo "❌ Error: $action failed, attempts ended, check '$UPGRADE_LOG', exit"
            RC="1"
            return 1
        fi
    done
}

#checking fail in update/upgrade step
check_fail() {
    if [[ -n "${FAIL_STEP:-}" ]]; then
        DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"
        MESSAGE="❌ <b>Scheduled security updates</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
❌ <b>Action:</b> updgrade failed
❌ <b>Step:</b> ${FAIL_STEP}
💾 <b>UN-UP log:</b> /var/log/unattended-upgrades/unattended-upgrades.log
💾 <b>Upgrade log:</b> ${UPGRADE_LOG}
💾 <b>Dpkg log:</b> /var/log/dpkg.log"
        echo "########## collected message - $DATE_MESSAGE ##########"
        echo "$MESSAGE"
        telegram_message
        exit $RC
    fi
}

# call update and fail check
update_and_upgrade "update packages list" apt-get update || { FAIL_STEP="apt-get update"; check_fail; }
update_and_upgrade "upgrade" unattended-upgrade || { FAIL_STEP="unattended-upgrade"; check_fail; }

# parse package changes from dpkg.log for name+version, not use unattended log because he dont have version
CHANGES="$(awk -v d="$TODAY" '
  function numver(v,    m) {
    sub(/^[0-9]+:/, "", v)
    if (match(v, /^[0-9]+(\.[0-9]+)*/))
      return substr(v, RSTART, RLENGTH)
    return v
  }

  $1==d && ($3=="upgrade" || $3=="install" || $3=="remove") {
    pkg=$4; sub(/:.*/,"",pkg);

    if ($3=="upgrade")
      printf "[↻] upgrade %s %s -> %s\n", pkg, numver($5), numver($6);
    else if ($3=="install")
      printf "[↑] install %s %s\n", pkg, numver($6);
    else if ($3=="remove")
      printf "[↓] %s %s %s\n", $3, pkg, numver($5);
  }' /var/log/dpkg.log || true)"

if [[ -z "$CHANGES" ]]; then
  CHANGE_SUMMARY="➖ No package changes"
else
  COUNT="$(printf "%s\n" "$CHANGES" | wc -l)"
  CHANGE_SUMMARY="➕ $COUNT package changed:
$CHANGES"
fi

# start collecting final message
DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"
MESSAGE="<b>✅ Scheduled security updates</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
⚫️ <b>Action:</b> upgrade success
$CHANGE_SUMMARY
💾 <b>UN-UP log:</b> /var/log/unattended-upgrades/unattended-upgrades.log
💾 <b>Upgrade log:</b> ${UPGRADE_LOG}
💾 <b>Dpkg log:</b> /var/log/dpkg.log"

echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"
telegram_message

# check reboot requiers
if [[ -f /var/run/reboot-required ]]; then
    PKGS_REBOOT="$(cat /var/run/reboot-required.pkgs)"
    PKGS_REBOOT="$(printf '%s\n' "$PKGS_REBOOT" | sed 's/^/[→] /')"
    DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"
    MESSAGE="⚠️ <b>Scheduled security upgrade</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
⚫️ <b>Action:</b> reboot after 1 min
🔎 <b>Reboot request from packages:</b>
${PKGS_REBOOT}"

echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"
telegram_message

sleep 60
REBOOT="1"
fi

exit $RC