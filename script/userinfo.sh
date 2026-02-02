#!/bin/bash
# script for show user info from xray config and URI_DB

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

USERNAME="$1"

if ! [[ $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# check another instanсe of the script is not running
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
xray_lock
tr_db_lock
uri_db_lock

readonly URI_PATH="/usr/local/etc/xray/URI_DB"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly INBOUND_TAG="Vless"
readonly TR_DB_M="/var/log/xray/TR_DB_M"
readonly TR_DB_Y="/var/log/xray/TR_DB_Y"

# tags used for status detection
readonly MANUAL_BLOCK_TAG="manual-block-users"
readonly AUTO_BLOCK_EXPIRED_TAG="autoblock-expired-users"
readonly AUTO_BLOCK_TRAFFIC_TAG="autoblock-traffic-users"

# check xray conf
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# check URI
if [[ ! -r "$URI_PATH" ]]; then
    echo "❌ Error: check $URI_PATH it's missing or you do not have read permissions, exit"
    exit 1
fi

# check TR_DB
if [[ ! -r "$TR_DB_M" ]]; then
    echo "❌ Error: check $TR_DB_M it's missing or you do not have read permissions, exit"
    exit 1
fi

# check TR_DB
if [[ ! -r "$TR_DB_Y" ]]; then
    echo "❌ Error: check $TR_DB_Y it's missing or you do not have read permissions, exit"
    exit 1
fi

# Find full email string for the user in the specified inbound tag
FULL_EMAIL="$(
  jq -r --arg itag "$INBOUND_TAG" --arg u "$USERNAME" '
    (.inbounds // [])
    | map(select(.tag == $itag))
    | .[0].settings.clients // []
    | map(select((.email // "" | split("|")[0]) == $u))
    | .[0].email // ""
  ' "$XRAY_CONFIG"
)"

# If user not found in inbound -> exit
if [[ -z "$FULL_EMAIL" ]]; then
    echo "❌ Error: username not found, exit"
    exit 1
fi

# Helper: extract field value from FULL_EMAIL like "...|created=2026-01-15|days=10|exp=2026-01-25"
_extract_field() {
  local key="$1" s="$2"
  # Prints value or empty
  sed -n "s/.*|${key}=\\([^|]*\\).*/\\1/p" <<<"$s" | head -n1
}

CREATED="$(_extract_field "created" "$FULL_EMAIL" || true)"
DAYS_BOUGHT="$(_extract_field "days" "$FULL_EMAIL" || true)"
EXP="$(_extract_field "exp" "$FULL_EMAIL" || true)"

# Normalize missing/non-usable values -> 0
# created/exp: must look like YYYY-MM-DD, otherwise 0
if [[ ! "$CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  CREATED="unknown"
fi

if ! [[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$EXP" == "never" ]]; then
  EXP="unknown"
fi

# days: must be integer
if ! [[ "$DAYS_BOUGHT" =~ ^-?[0-9]+$  || "$DAYS_BOUGHT" == "infinity" ]]; then
  DAYS_BOUGHT="unknown"
fi

# Compute DAYS_LEFT (can be negative). If EXP=0 -> 0
DAYS_LEFT="0"
if [[ "$EXP" == "never" ]]; then
    DAYS_LEFT="infinity"
elif [[ $EXP =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    exp_epoch="$(date -d "$EXP" +%s 2>/dev/null)"
    today="$(date +%F)"
    today_epoch="$(date -d "$today" +%s 2>/dev/null || echo 0)"
    DAYS_LEFT="$(( (exp_epoch - today_epoch) / 86400 ))"
else
    DAYS_LEFT="unknown"
fi

STATUS="$(
  jq -r \
    --arg u "$FULL_EMAIL" \
    --arg mb "$MANUAL_BLOCK_TAG" \
    --arg ae "$AUTO_BLOCK_EXPIRED_TAG" \
    --arg at "$AUTO_BLOCK_TRAFFIC_TAG" '
      def has($tag):
        any(.routing.rules[]?;
          (.ruleTag? == $tag) and any(.user[]?; . == $u)
        );

      if has($mb) then "blocked"
      elif has($at) then "traffic ban"
      elif has($ae) then "expired ban"
      else "enable"
      end
    ' "$XRAY_CONFIG"
)"

json="$(xray api statsonline --email "$FULL_EMAIL" 2>/dev/null)"
DEVICE_NUMBER="$(jq -r '.stat.value // 0' <<<"$json")"
[[ ! $DEVICE_NUMBER =~ ^-?[0-9]+$ ]] && DEVICE_NUMBER=0

if (( DEVICE_NUMBER >= 1 )); then
  ONLINE="online"
else
  ONLINE="offline"
fi

IP_USER=""
if [[ $ONLINE == "online" ]]; then
    json="$(xray api statsonlineiplist --email "$FULL_EMAIL" 2>/dev/null)"
    if [[ -n "$json" ]]; then
        IP_USER="$(jq -r '(.ips // {}) | keys | join(" ")' <<<"$json")"
    fi
fi

total_bytes_m="$(
  jq -r --arg u "$USERNAME" '
    [ .stat[]?
      | select(.name? and (.name | startswith("user>>>")))
      | select((.name | split(">>>")[1] | split("|")[0]) == $u)
      | (.value // 0)
    ]
    | (add // 0)
    | . * 2
  ' "$TR_DB_M" 2>/dev/null
)"

# если файла/JSON нет или значений нет
[[ -z "$total_bytes_m" || "$total_bytes_m" == "null" ]] && total_bytes_m=0

if [[ "$total_bytes_m" -eq 0 ]] 2>/dev/null; then
  TOTAL_M=0
else
  TOTAL_M="$(numfmt --to=iec --suffix=B "$total_bytes_m")"
fi

total_bytes_y="$(
  jq -r --arg u "$USERNAME" '
    [ .stat[]?
      | select(.name? and (.name | startswith("user>>>")))
      | select((.name | split(">>>")[1] | split("|")[0]) == $u)
      | (.value // 0)
    ]
    | (add // 0)
    | . * 2
  ' "$TR_DB_Y" 2>/dev/null
)"

# если файла/JSON нет или значений нет
[[ -z "$total_bytes_y" || "$total_bytes_y" == "null" ]] && total_bytes_y=0

if [[ "$total_bytes_y" -eq 0 ]] 2>/dev/null; then
  TOTAL_Y=0
else
  TOTAL_Y="$(numfmt --to=iec --suffix=B "$total_bytes_y")"
fi

# Ищем строки вида:
# name: <username>, vless link: <link>
# Выводим только "<link>" (целиком), для всех совпадений по name.
matches="$(
  awk -v user="$USERNAME" '
    BEGIN { found=0 }
    {
      if (match($0, /^name:[[:space:]]*([^,]+),[[:space:]]*vless link:[[:space:]]*(.+)$/, m)) {
        name = m[1]
        link = m[2]
        # Точное совпадение имени, без частичных матчей
        if (name == user) {
          print link
          found=1
        }
      }
    }
    END { if (!found) exit 3 }
  ' "$URI_PATH"
)" || {
  rc=$?
  if [[ $rc -eq 3 ]]; then
    echo "User '$USERNAME' in URI_DB not found"
    exit 1
  fi
  echo "Error: failed to parse '$URI_PATH'"
  exit 2
}

echo "🧑🏿‍💻 Name: $USERNAME"
echo "📅 Created: $CREATED"
echo "🗓 Bought days: $DAYS_BOUGHT"
echo "🗓 Days left: $DAYS_LEFT"
echo "📅 Expiration: $EXP"
echo "🌐 Status: $ONLINE"
echo "🔏 Active: $STATUS"
echo "📱 Device: $DEVICE_NUMBER"
echo "📊 Traffic monthly: $TOTAL_M"
echo "📊 Traffic annual: $TOTAL_Y"
echo "📝 IP: $IP_USER"
echo "🛠 Vless link: $matches"