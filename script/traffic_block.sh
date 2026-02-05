#!/usr/bin/env bash
# script for autoblock user who download traffic limit via cron every hour
# all errors are logged in journald, see journalctl -t traffic_block
# 10 * * * * telegram-gateway /usr/local/bin/service/traffic_block.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t traffic_block -p info) 2> >(systemd-cat -t traffic_block -p error)

# start logging message
echo "traffic block started - $(date '+%Y-%m-%d %H:%M:%S')"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        echo "traffic block ended - $(date '+%Y-%m-%d %H:%M:%S')"
    else
        echo "traffic block failed - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "Error: you are not the telegram-gateway user, exit" >&2; exit 1; }

# main variable
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.$(date '+%Y%m%d_%H%M%S')"
readonly INBOUND_TAG="Vless"
readonly TR_DB_M="/var/log/xray/TR_DB_M"
readonly AUTO_BLOCK_TAG="autoblock-traffic-users"
readonly MAX_TR=$((3000 * 1024 * 1024 * 1024)) # 3TB limits

# source runlock function library
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
xray_lock_retry
tr_db_lock_retry

# read and write conf check
read_and_write_check "$XRAY_CONFIG"
read_check "$TR_DB_M"

# source Telegram function library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# help function
run_and_check() {
    action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

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
  restart_xray
else
  echo "OK: превышений не найдено, конфиг не менялся."
fi

RC=0
