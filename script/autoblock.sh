#!/bin/bash
# script for autoblock xray expired user via cron every day 0:01 night time
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 1 0 * * * telegram-gateway /usr/local/bin/service/autoblock.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly AUTOBLOCK_LOG="${LOG_DIR}/autoblock.${DATE_LOG}.log"
exec &>> "$AUTOBLOCK_LOG" || { echo "❌ Error: cannot write to log '$AUTOBLOCK_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## autoblock started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## autoblock ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## autoblock failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly INBOUND_TAG="Vless"
readonly BLOCK_OUTBOUND_TAG="blocked"
readonly RULE_TAG="autoblock-expired-users"
readonly TODAY="$(date +%F)"
readonly TODAY_TS="$(date -d "$TODAY" +%s)"
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS="3"
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
readonly WAIT_SEC="$(shuf -i "10-60" -n 1)"

# check another instanсe of the script is not running (with retries)
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 8; then
    break
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "⚠️  Non-critical error: Lock busy ($LOCK_FILE). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# prevents attempts to restart via this script while the update is in progress (with retries)
readonly LOCK_FILE_4="/run/lock/xray_update.lock"
exec 99> "$LOCK_FILE_4" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_4', exit"; exit 1; }
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 99; then
    break
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "⚠️  Non-critical error: Lock busy ($LOCK_FILE_4). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE_4) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# check xray conf
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
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

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

# helper func
try() { "$@" || return 1; }

run_and_check() {
    action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
}

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

# parse old conf for exp email
parse_conf() {
    # get email from inbound with tag
    mapfile -t EMAILS < <(
        jq -r --arg tag "$INBOUND_TAG" '
            .inbounds[]? | select(.tag == $tag) |
            .settings.clients[]? | .email // empty
        ' "$XRAY_CONFIG"
    )

    expired_emails=()

    for email in "${EMAILS[@]}"; do
        # get exp date
        exp="$(sed -n 's/.*|exp=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' <<<"$email")"
        [[ -z "$exp" ]] && continue

        # get exp sec
        exp_ts="$(date -d "$exp" +%s 2>/dev/null || true)"
        [[ -z "$exp_ts" ]] && continue

        # block if exp < today
        if (( exp_ts < TODAY_TS )); then
            expired_emails+=("$email")
        fi
    done

    # users JSON array
    if (( ${#expired_emails[@]} == 0 )); then
        users_json='[]'
    else
        users_json="$(printf '%s\n' "${expired_emails[@]}" \
            | jq -R . \
            | jq -s 'unique')"
    fi
}
run_and_check "parse config for exp email" parse_conf

# make new config
new_conf() {
    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    try chmod 600 "$TMP_XRAY_CONFIG"

    # set trap for tmp removing
    trap 'on_exit; rm -f "$TMP_XRAY_CONFIG";' EXIT

    try jq \
        --arg inbound "$INBOUND_TAG" \
        --arg out "$BLOCK_OUTBOUND_TAG" \
        --arg ruleTag "$RULE_TAG" \
        --argjson users "$users_json" '
        .routing = (.routing // {}) |
        .routing.rules = (.routing.rules // []) |
        .routing.rules |= map(select(.ruleTag != $ruleTag)) |

        (if (.outbounds | type) != "array" then
            error("❌ Error: outbounds not found, cant add blackhole")
        else
            .
        end) |

    .outbounds |= (
        if any(.[]; .tag == $out) then .
        else . + [{"tag": $out, "protocol": "blackhole"}]
        end
    ) |

    (if ($users | length) > 0 then
        .routing.rules = ([{
        "type": "field",
        "ruleTag": $ruleTag,
        "inboundTag": [$inbound],
        "user": $users,
        "outboundTag": $out
        }] + .routing.rules)
    else
        .
    end)
' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}
run_and_check "make new config" new_conf

# if conf not change, exit
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    echo "✅ Success: expired email not found, exit (today=$TODAY, expired=${#expired_emails[@]})"
    RC=0
    exit 0
fi

# check new conf
run_and_check "xray new config checking" xray run -test -config "$TMP_XRAY_CONFIG"

# backup and install new config
run_and_check "backup old xray config" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

install_new_conf() {
    cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG"
}
run_and_check "install new xray config" install_new_conf

if (( ${#expired_emails[@]} == 0 )); then
    echo "✅ Success: expired users not found, cleanup old ruleTag '$RULE_TAG' (today=$TODAY)"
else
    echo "⚠️ Success: expired users found and blocked, today=$TODAY, expired=${#expired_emails[@]}"
fi
echo "✅ Success: Backup saved $XRAY_CONFIG_BACKUP"


# restart xray
if systemctl restart xray.service; then
    XRAY_STATUS="☑️ <b>Xray status:</b> running"
    XR_ST=0
    RC=0
    echo "✅ Success: restart xray"
else
    XRAY_STATUS="❌ <b>Xray status:</b> fail"
    XR_ST=1
    RC=1
    echo "❌ Error: restart xray"
fi

# start collecting message
readonly DATE_MESSAGE="$(date '+%Y-%m-%d %H:%M:%S')"

if [[ $XR_ST == 0 ]]; then
    TITLE="⚠️<b> Scheduled autoblock</b>"
else
    TITLE="❌<b> Scheduled autoblock</b>"
fi

MESSAGE="$TITLE

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $DATE_MESSAGE
$XRAY_STATUS"

if (( ${#expired_emails[@]} == 0 )); then
    MESSAGE+=$'\n'"⚠️ <b>Expired users:</b> not found"
    MESSAGE+=$'\n'"⚠️ <b>Action:</b> cleanup old autoblock rule"
else
    MESSAGE+=$'\n'"❌ <b>Expired users blocked:</b>"
    while IFS= read -r EMAIL; do
        [[ -z "$EMAIL" ]] && continue
        NAME="${EMAIL%%|*}"
        MESSAGE+=$'\n'"❌ $NAME"
    done < <(printf '%s\n' "${expired_emails[@]}")
fi

MESSAGE+=$'\n'"💾 <b>Autoblock log:</b> $AUTOBLOCK_LOG"

# logging message
echo "########## collected message - $DATE_MESSAGE ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC