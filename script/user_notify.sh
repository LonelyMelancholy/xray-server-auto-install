#!/bin/bash
# script for notify xray traffic and user exp date via cron every day 1:01 night time
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 1 1 * * * telegram-gateway /usr/local/bin/telegram/user_notify.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/telegram"
readonly NOTIFY_LOG="${LOG_DIR}/user.${DATE_LOG}.log"
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## user notify started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## user notify ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## user notify failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly TR_DB_M="/var/log/xray/TR_DB_M"
readonly TR_DB_Y="/var/log/xray/TR_DB_Y"
readonly INBOUND_TAG="Vless"
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS="3"
readonly WAIT_SEC="$(shuf -i "10-60" -n 1)"

# check xray conf
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# check secret file, if the file is ok, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -c '%U:%a' "$ENV_FILE" 2>/dev/null)" != "telegram-gateway:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check group id from secret file
[[ -z "$GROUP_ID" ]] && { echo "❌ Error: Telegram group ID is missing in '$ENV_FILE', exit"; exit 1; }

# check another instanсe of the script is not running (with retries)
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
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
readonly LOCK_FILE_3="/run/lock/tr_db.lock"
exec 10> "$LOCK_FILE_3" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_3', exit"; exit 1; }
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
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

# pure Telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${GROUP_ID}" \
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

# reset traffic 1 day of month and year
RESET_ARG_M="0"
[[ "$(date +%d)" = "01" ]] && RESET_ARG_M="1"

RESET_ARG_Y="0"
[[ "$(date +%j)" = "001" ]] && RESET_ARG_Y="1"

# get stat json
readonly RAW="$(cat "$TR_DB_M")"

# reset traffic 1 day of month
if [[ $RESET_ARG_M == "1" ]]; then
    rm -f "$TR_DB_M"
fi

# reset traffic 1 day of year
if [[ $RESET_ARG_Y == "1" ]]; then
    rm -f "$TR_DB_Y"
fi

# parse json to name:name:number
stat_lines() {
  local json="$1"
  jq -r '
    .stat[]
    | (.name | split(">>>")) as $p
    | "\($p[0]):\($p[1]):\(.value // 0)"
  ' <<<"$json"
}
DATA="$(stat_lines "$RAW")"

# calculate total server traffic
sum_server() {
  local lines="$1"
  awk -F: '
    $1=="inbound" || $1=="outbound" { s += ($3+0) }
    END { print s+0 }
  ' <<<"$lines"
}
SERVER_TOTAL="$(sum_server "$DATA")"

# calculate total traffic each user and cut | info
sum_users() {
  local lines="$1"
  awk -F: '
    $1=="user" {
      split($2, a, "|")
      u[a[1]] += ($3+0)
    }
    END { for (k in u) printf "%s %d\n", k, u[k] }
  ' <<<"$lines" | LC_ALL=C sort
}
USERS_TOTAL="$(sum_users "$DATA")"

# formatting bytes
fmt(){ numfmt --to=iec --suffix=B "$1"; }

# calculate sec since 1970 and parse email
readonly TODAY_EPOCH="$(date -d "today 00:00" +%s)"
readonly EMAILS="$(jq -r --arg tag "$INBOUND_TAG" '.inbounds[]? | select(.tag? == $tag) | .settings? | .clients?[]? | .email? // empty' "$XRAY_CONFIG")"

# parse and print email - exp days
USERS_LEFT=""
while IFS= read -r email; do
    [[ -z "$email" ]] && continue

    username="${email%%|*}"

    exp_date="$(printf '%s' "$email" | sed -nE 's/.*\|exp=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
    [[ -z "$exp_date" ]] && continue

    exp_epoch="$(date -d "$exp_date" +%s)"
    days_left=$(( (exp_epoch - TODAY_EPOCH) / 86400 ))


    USERS_LEFT+="$(printf '%s %s' "$username" "$days_left")"$'\n'
done <<< "$EMAILS"

# start collecting message
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

MESSAGE="📢<b> Daily user report</b> 

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
🔛 <b>Traffic:</b>
🔛 <b>Host traffic:</b> $(fmt "$SERVER_TOTAL")"

while IFS=$' ' read -r EMAIL TRAFF; do
    [[ -z "$EMAIL" ]] && continue
    TRAFFx2=$(( TRAFF * 2 ))
    MESSAGE+=$'\n'"🔛 <b>User traffic:</b> $EMAIL - $(fmt "$TRAFFx2")"
done <<< "$USERS_TOTAL"

MESSAGE+=$'\n'"🔚 <b>Time:</b>"

while IFS=$' ' read -r EMAIL DAYS; do
    [[ -z "$EMAIL" ]] && continue
    if [[ $DAYS -le 0 ]]; then
        MESSAGE+=$'\n'"❌ <b>User time:</b> $EMAIL - $DAYS days left"
    elif [[ $DAYS -le 10 ]]; then
        MESSAGE+=$'\n'"⚠️ <b>User time:</b> $EMAIL - $DAYS days left"
    else
        MESSAGE+=$'\n'"🔚 <b>User time:</b> $EMAIL - $DAYS days left"
    fi
done <<< "$USERS_LEFT"

MESSAGE+=$'\n'"💾 <b>Xray error log:</b> /var/log/xray/error.log
💾 <b>Xray access log:</b> /var/log/xray/access.log
💾 <b>Notify log:</b> $NOTIFY_LOG"

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC