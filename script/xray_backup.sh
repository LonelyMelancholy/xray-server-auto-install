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
if [[ "$ONLY_ARCHIVE" != 1 && "$ONLY_ARCHIVE" != 0 ]]; then
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
RC_F="1"
on_exit() {
    if [[ "$RC_F" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## backup ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## backup failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanсe of the script is not running
readonly LOCK_FILE_5="/run/lock/backup.lock"
exec 99> "$LOCK_FILE_5" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_5', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance working on backup, exit"; exit 1; }

source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
xray_lock_retry
tr_db_lock_retry
uri_db_lock_retry

source "/usr/local/lib/service/telegram.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit"; exit 1; }

FILES=(
  "/var/log/xray/TR_DB_M"
  "/var/log/xray/TR_DB_Y"
  "/usr/local/etc/xray/URI_DB"
  "/usr/local/etc/xray/config.json"
)

TS="$(date +'%Y-%m-%d_%H-%M-%S')"
HOST="$(hostname)"
FILE_NAME="xray_backup_${HOST}_${TS}.tar.gz"
FILE_PATH="/tmp/${FILE_NAME}"

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap 'on_exit; cleanup;' EXIT

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
tar -C "$TMPDIR" -czf "$FILE_PATH" .

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

exit $RC_F