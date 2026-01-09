#!/bin/bash
# script for xray backup via cron 23:00 night time last day month
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 0 23 28-31 * * root [ "$(date -v+1d +\%d)" = "01" ] && "/usr/local/bin/service/xray_backup.sh" &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
umask 077

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }


ONLY_ARCHIVE="${1:-0}"
if [[ "$ONLY_ARCHIVE" != 1 || "$ONLY_ARCHIVE" != 0]]; then
    echo "❌ Error: only 0 or 1 for argument"
    exit 1
fi

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly BACKUP_LOG="${LOG_DIR}/backup.${DATE_LOG}.log"
exec &>> "$BACKUP_LOG" || { echo "❌ Error: cannot write to log '$BACKUP_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## backup started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## backup ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## backup failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT
readonly WAIT_SEC="$(shuf -i "10-60" -n 1)"

# check another instanсe of the script is not running
readonly LOCK_FILE_5="/run/lock/backup.lock"
exec 99> "$LOCK_FILE_5" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_5', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance working on backup, exit"; exit 1; }

# check another instanсe of the script is not running (with retries)
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
readonly MAX_ATTEMPTS="3"
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 8; then
    break
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "❌ Error: Lock busy ($LOCK_FILE). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# check another instanсe of the script is not running (with retries)
readonly LOCK_FILE_2="/run/lock/uri_db.lock"
exec 9> "$LOCK_FILE_2" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_2', exit"; exit 1; }
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 9; then
    break
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "❌ Error: Lock busy ($LOCK_FILE_2). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE_2) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# check another instanсe of the script is not running (with retries)
readonly LOCK_FILE_3="/run/lock/tr_db.lock"
exec 10> "$LOCK_FILE_3" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_3', exit"; exit 1; }
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 10; then
    break
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "❌ Error: Lock busy ($LOCK_FILE_3). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE_3) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -c '%U:%a' "$ENV_FILE" 2>/dev/null)" != "telegram-gateway:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

FILES=(
  "/var/log/xray/TR_DB_M"
  "/var/log/xray/TR_DB_Y"
  "/usr/local/etc/xray/URI_DB"
  "/usr/local/etc/xray/config.json"
)

TS="$(date +'%Y-%m-%d_%H-%M-%S')"
HOST="$(hostname)"
ARCHIVE_NAME="xray_backup_${HOST}_${TS}.tar.gz"
ARCHIVE_PATH="/tmp/${ARCHIVE_NAME}"

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap 'on_exit; cleanup;' EXIT

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

# pure Telegram file sent function with checking the sending status
_tg_doc() {
    local response
    response="$(curl -fsS -m 30 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
            -F "chat_id=${CHAT_ID}" \
            -F "document=@${ARCHIVE_PATH};filename=${ARCHIVE_NAME}")" || return 1
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
                exit 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to Telegram after $attempt attempt"
            break
        fi
    done
    return 0
}

# Telegram message with logging and retry
telegram_file() {
    local attempt="1"
    while true; do
        if ! _tg_doc; then
            if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
                echo "❌ Error: failed to send Telegram file after $attempt attempt, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: file was sent to Telegram after $attempt attempt"
            RC=0
            break
        fi
    done
    return 0
}

# Собираем файлы в temp с сохранением путей
added_any=0
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    # --parents сохраняет структуру каталогов
    cp --parents -f "$f" "$TMPDIR/"
    added_any=1
  else
    msg="❌ Error: file not found: $f, exit"
    echo "$msg"
    exit 1
  fi
done

if [[ "$added_any" != "1" ]]; then
  echo "❌ Error: no files to backup (all missing?), exit"
  exit 1
fi

# Пакуем
tar -C "$TMPDIR" -czf "$ARCHIVE_PATH" .

# send message and file
if [[ "$ONLY_ARCHIVE" == 1 ]]; then
    telegram_file
else
    # start collecting message
    readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

    MESSAGE="📢<b> Scheduled backup</b> 

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
💾 <b>Backup log:</b> $BACKUP_LOG"

    # logging message
    echo "########## collected message - $DATE_MESSAGE ##########"
    echo "$MESSAGE"

    telegram_file
    telegram_message
fi

exit $RC