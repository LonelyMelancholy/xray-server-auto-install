#!/usr/bin/env bash
# script for autoblock user who download traffic limit via cron every hour
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 10 * * * * telegram-gateway /usr/local/bin/service/traffic_block.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }
# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly TRAFFIC_BLOCK_LOG="${LOG_DIR}/traffic_block.${DATE_LOG}.log"
exec &>> "$TRAFFIC_BLOCK_LOG" || { echo "❌ Error: cannot write to log '$TRAFFIC_BLOCK_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "########## traffic block started - $DATE_START ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local date_end="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## traffic block ended - $date_end ##########"
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## traffic block failed - $date_fail ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

readonly MAX_ATTEMPTS="3"
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

run_and_check() {
    action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
}

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

readonly URI_PATH="/usr/local/etc/xray/URI_DB"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
readonly INBOUND_TAG="Vless"
readonly TR_DB_M="/var/log/xray/TR_DB_M"
readonly AUTO_BLOCK_TAG="autoblock-traffic-users"
# 3TB limit
readonly MAX_TR=$((3000 * 1024 * 1024 * 1024))

# check xray conf
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# check TR_DB
if [[ ! -r "$TR_DB_M" ]]; then
    echo "❌ Error: check $TR_DB_M it's missing or you do not have read permissions, exit"
    exit 1
fi

# ====== СБОР ТРАФИКА ПО ИМЕНИ ДО '|' ======
declare -A total_bytes_by_base

# Берем только user>>>...>>>traffic>>>up/downlink у которых есть value
# name пример: user>>>black|created=...>>>traffic>>>downlink
while IFS=$'\t' read -r name value; do
  # вытащить кусок между user>>> и >>>traffic
  user_full="${name#user>>>}"
  user_full="${user_full%%>>>traffic*}"

  # базовое имя до |
  base="${user_full%%|*}"

  # value может быть большим, используем bash integer
  total_bytes_by_base["$base"]=$(( ${total_bytes_by_base["$base"]:-0} + value ))
done < <(
  jq -r '
    .stat[]
    | select(.name? and (.name | startswith("user>>>")))
    | select(.value? != null)
    | select(.name | test(">>>traffic>>>(up|down)link$"))
    | [.name, (.value|tostring)]
    | @tsv
  ' "$TR_DB_M"
)

if (( ${#total_bytes_by_base[@]} == 0 )); then
  echo "OK: в $TR_DB_M не найдено user>>>...>>>traffic>>>uplink/downlink со значениями."
  exit 0
fi

# Найти актуальный полный email в inbound Vless по base (до |)
find_full_email_in_config() {
  local base="$1"
  # 1) сначала ищем email начинающийся с "base|"
  local found
  found="$(jq -r --arg inb "$INBOUND_TAG" --arg base "$base" '
    .inbounds[]?
    | select(.tag? == $inb)
    | .settings.clients[]?
    | select(.email? and (.email | startswith($base + "|")))
    | .email
  ' "$XRAY_CONFIG" | head -n1)"

  [[ -n "$found" ]] && printf '%s\n' "$found"
}

is_already_blocked() {
  local email="$1"
  jq -e --arg tag "$AUTO_BLOCK_TAG" --arg email "$email" '
    (.routing.rules // [])
    | any(.ruleTag? == $tag and ((.user // []) | index($email)))
  ' "$XRAY_CONFIG" >/dev/null 2>&1
}

add_block_rule_user() {
  local email="$1"

  # Пишем во временный файл и заменяем атомарно
  local tmp
  tmp="$(mktemp)"

  jq --arg tag "$AUTO_BLOCK_TAG" \
     --arg inb "$INBOUND_TAG" \
     --arg email "$email" '
    .routing = (.routing // {})
    | .routing.domainStrategy = (.routing.domainStrategy // "IPOnDemand")
    | .routing.rules = (.routing.rules // [])
    | ( .routing.rules | any(.ruleTag? == $tag) ) as $has
    | if $has then
        .routing.rules = (
          .routing.rules
          | map(
              if .ruleTag? == $tag then
                .type = "field"
                | .inboundTag = (.inboundTag // [$inb])
                | .outboundTag = "blocked"
                | .user = ((.user // []) + [$email] | unique)
              else .
              end
            )
        )
      else
        .routing.rules += [{
          "type": "field",
          "ruleTag": $tag,
          "inboundTag": [$inb],
          "outboundTag": "blocked",
          "user": [$email]
        }]
      end
  ' "$XRAY_CONFIG" > "$tmp"

  # минимальная валидация JSON
  jq -e . "$tmp" >/dev/null

  cat "$tmp" > "$XRAY_CONFIG"
}

restart_xray() {
    systemctl restart xray.service 2>/dev/null || return 1
}

# ====== ОСНОВНОЙ ЦИКЛ ======
changed=0
declare -a blocked_now=()

for base in "${!total_bytes_by_base[@]}"; do
  sum=$(( total_bytes_by_base["$base"] ))
  used=$(( sum * 2 ))

  if (( used > MAX_TR )); then
    full_email="$(find_full_email_in_config "$base" || true)"

    if [[ -z "${full_email:-}" ]]; then
      echo "WARN: base='$base' превысил лимит, но в конфиге не найден актуальный email клиента Vless."
      continue
    fi

    if is_already_blocked "$full_email"; then
      echo "OK: уже заблокирован: $full_email (base='$base')"
      continue
    fi

    if (( changed == 0 )); then
        # backup config
        run_and_check "backup old xray config" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"
    fi

    add_block_rule_user "$full_email"
    changed=1
    blocked_now+=("$full_email")
    echo "BLOCK: $full_email (base='$base'), used=$used bytes, MAX_TR=$MAX_TR"
  fi
done

if (( changed == 1 )); then
    # backup and install new config
    run_and_check "backup old xray config" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"
  
  echo "Готово: добавлено в блокировку (${#blocked_now[@]}):"
  printf ' - %s\n' "${blocked_now[@]}"
else
  echo "OK: превышений не найдено, конфиг не менялся."
fi
