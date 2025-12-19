#!/bin/bash
# auto install update (unattended-upgrade) and send notify via Telegram
# launch from crontab
# 0 2 * * * root "$TRAFFIC_NOTIFY_SCRIPT_DEST" &> /dev/null
# for debugging, add a redirect to the debug log
#
#

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly UPGRADE_LOG="${LOG_DIR}/unattended-upgrade.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$UPGRADE_LOG" || { echo "❌ Error: cannot write to log '$UPGRADE_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## unattended upgrade started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## unattended upgrade ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## unattended upgrade failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/unattended_upgrade.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# pure Telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${MESSAGE}" 2> /dev/null)" || return 1
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
            return 0
        fi
    done
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

# main variables
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS="3"
DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date +%Y-%m-%d)"
NO_REBOOT=0

# main logic start here
MESSAGE="⚠️ <b>Scheduled security updates</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
⚫️ Action: Update started"

echo "$MESSAGE"
telegram_message

update_and_upgrade() {
    local action="$1"
    shift 2
    local attempt=1
    local max_attempt=3

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first two)
        if "$@" &>> "/dev/null"; then
            echo "✅ Success: $action completed"
            RC="0"
            return 0
            
        fi
        if [[ "$attempt" -lt "$max_attempt" ]]; then
            sleep 60
            echo "⚠️  Non-critical error: $action failed, trying again"
            ((attempt++))
            continue
        else
            echo "❌ Error: $action failed, attempts ended, check '$UPGRADE_LOG', exit"
            return 1
            RC="1"
            exit $RC
        fi
    done
}

cmd_update=(apt-get update)
cmd_upgrade=(unattended-upgrade)
update_and_upgrade "update packages list" "$UPGRADE_LOG" "${cmd_update[@]}"
update_and_upgrade "upgrade" "$UPGRADE_LOG" "${cmd_upgrade[@]}"

CHANGES="$(awk -v d="$TODAY" '
  function numver(v,    m) {
    sub(/^[0-9]+:/, "", v)                  # убрать epoch вида 1:
    if (match(v, /^[0-9]+(\.[0-9]+)*/))     # взять только N(.N)*
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
  }' /var/log/dpkg.log 2>/dev/null || true)"

if [ -z "$CHANGES" ]; then
  CHANGE_SUMMARY="➖ No package changes"
else
  COUNT="$(printf "%s\n" "$CHANGES" | wc -l)"
  CHANGE_SUMMARY="➕ $COUNT package changed:
$CHANGES"
fi

[[ "$RC" == "0" ]] && TITLE="✅ <b>Successful installation security updates</b>" || TITLE="❌ <b>Error installing security updates</b>"

MESSAGE="$TITLE

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
$CHANGE_SUMMARY
💾 <b>UN-UP log:</b> /var/log/unattended-upgrades/unattended-upgrades.log
💾 <b>Upgrade log:</b> ${UPGRADE_LOG}
💾 <b>Dpkg log:</b> /var/log/dpkg.log"

echo "$MESSAGE"

telegram_message

if [[ -f /var/run/reboot-required ]]; then
    PKGS_REBOOT="$(cat /var/run/reboot-required.pkgs 2> /dev/null)"
    MESSAGE="⚠️ <b>Scheduled security updates</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
⚫️ Action: Reboot after 1 min
🔎 Reboot request: ${PKGS_REBOOT}"

echo "$MESSAGE"
telegram_message

sleep 60
reboot
fi


exit $RC