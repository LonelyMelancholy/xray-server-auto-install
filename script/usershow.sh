#!/bin/bash
# script for show users from xray config and URI_DB
#
# Options:
#   links - print URI_DB (unchanged)
#   all   - print table:
#           username (online/offline), number of device, (blocked/expired/enable), traffic, number days left

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instance of the script is not running
readonly LOCK_FILE="/var/run/user.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on xray configuration or URI DB, exit"; exit 1; }

# argument check
if ! [[ "$#" -eq 1 ]]; then
  echo "Use for show user from xray config and URI_DB, run: $0 <option>"
  echo "links - all user link and expiration info"
  echo "all   - table: username (online/offline), devices, (blocked/expired/enable), traffic, days left"
  exit 1
fi

# main variables
readonly OPTION="$1"
readonly URI_PATH="/usr/local/etc/xray/URI_DB"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly INBOUND_TAG="Vless"
readonly TR_DB_M="/var/log/xray/TR_DB_M"

# tags used for status detection
readonly MANUAL_BLOCK_TAG="manual-block-users"
readonly AUTO_BLOCK_TAG="autoblock-expired-users"

# global (script-wide) storage for the "all" option
declare -A USER_SET=()
declare -A DAYS_LEFT_BY_USER=()
declare -A STATUS_BY_USER=()
declare -A DEVICES_BY_USER=()
declare -A TRAFFIC_BY_USER=()

# NOTE: file checks are done per option (links/all)

have_cmd() { command -v "$1" >/dev/null 2>&1; }

parse_exp_date() {
  # Extract YYYY-MM-DD from strings like: "...|exp=2026-04-16".
  # Prints nothing if not found.
  sed -nE 's/.*\|exp=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' <<<"$1"
}

calc_days_left() {
  # Usage: calc_days_left "YYYY-MM-DD"
  # Prints integer days (can be negative), or empty on parse error.
  local exp_date="$1"
  local exp_epoch
  exp_epoch="$(date -d "$exp_date" +%s 2>/dev/null)" || return 0
  echo $(( (exp_epoch - TODAY_EPOCH) / 86400 ))
}

fmt_bytes() {
  local b="$1"
  if have_cmd numfmt; then
    numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "$b"
  else
    echo "$b"
  fi
}

add_user() {
  local username="$1"
  [[ -z "$username" ]] && return 0
  USER_SET["$username"]=1
}

set_days_left_from_record() {
  # record may be "email" from config or "user" string from routing rules
  local record="$1"
  local username="${record%%|*}"
  [[ -z "$username" ]] && return 0

  # do not override if we already have value
  [[ -n "${DAYS_LEFT_BY_USER[$username]:-}" ]] && return 0

  local exp_date days_left
  exp_date="$(parse_exp_date "$record")"
  if [[ -z "$exp_date" ]]; then
    DAYS_LEFT_BY_USER["$username"]="infinity"
    return 0
  fi

  days_left="$(calc_days_left "$exp_date")"
  [[ -n "$days_left" ]] && DAYS_LEFT_BY_USER["$username"]="$days_left"
}

collect_inbound_users() {
  local emails
  emails="$(jq -r --arg tag "$INBOUND_TAG" '.inbounds[]? | select(.tag? == $tag) | .settings? | .clients?[]? | .email? // empty' "$XRAY_CONFIG" 2>/dev/null)" || true

  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    local username="${email%%|*}"
    add_user "$username"
    set_days_left_from_record "$email"
  done <<<"$emails"
}

collect_blocked_users() {
  local tag="$1"     # MANUAL_BLOCK_TAG or AUTO_BLOCK_TAG
  local status="$2"  # blocked / expired
  local users

  users="$(jq -r --arg tag "$tag" '.routing.rules[]? | select(.ruleTag == $tag) | (.user // [])[]? // empty' "$XRAY_CONFIG" 2>/dev/null)" || true

  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    local username="${rec%%|*}"
    add_user "$username"
    STATUS_BY_USER["$username"]="$status"
    set_days_left_from_record "$rec"
  done <<<"$users"
}

collect_online_devices() {
  # Fill DEVICES_BY_USER based on xray api outputs.
  have_cmd xray || return 0
  have_cmd jq || return 0

  local stats_json
  stats_json="$(xray api statsquery 2>/dev/null || true)"
  [[ -z "$stats_json" ]] && return 0

  mapfile -t USER_IDS < <(
    jq -r '
      (.stat // [])[]
      | .name
      | select(type=="string")
      | select(startswith("user>>>"))
      | (split("user>>>")[1] | split(">>>traffic>>>")[0])
    ' <<<"$stats_json" 2>/dev/null | awk 'NF' | sort -u
  )

  local uid username online_json online_val
  for uid in "${USER_IDS[@]}"; do
    username="${uid%%|*}"
    [[ -z "$username" ]] && continue
    add_user "$username"
    set_days_left_from_record "$uid"

    online_json="$(xray api statsonline --email "$uid" 2>/dev/null || true)"
    online_val="$(jq -r '.stat.value // 0' <<<"$online_json" 2>/dev/null)"
    [[ "$online_val" =~ ^[0-9]+$ ]] || online_val=0

    if (( online_val > 0 )); then
      DEVICES_BY_USER["$username"]=$(( ${DEVICES_BY_USER["$username"]:-0} + online_val ))
    fi
  done
}

collect_traffic() {
  have_cmd jq || return 0
  [[ -r "$TR_DB_M" ]] || return 0

  local raw
  raw="$(cat "$TR_DB_M" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 0

  local lines
  lines="$(jq -r '
    (.stat // [])[]?
    | select(.name? and (.name | startswith("user>>>")))
    | (.name | split("user>>>")[1] | split(">>>traffic>>>")[0]) as $uid
    | "\($uid)\t\(.value // 0)"
  ' <<<"$raw" 2>/dev/null)" || true

  local uid bytes username
  while IFS=$'\t' read -r uid bytes; do
    [[ -z "$uid" ]] && continue
    username="${uid%%|*}"
    [[ -z "$username" ]] && continue
    add_user "$username"
    set_days_left_from_record "$uid"

    [[ "$bytes" =~ ^-?[0-9]+$ ]] || bytes=0
    TRAFFIC_BY_USER["$username"]=$(( ${TRAFFIC_BY_USER["$username"]:-0} + bytes ))
  done <<<"$lines"
}

print_all_table() {
  # today 00:00 epoch for days_left calculations
  readonly TODAY_EPOCH="$(date -d "today 00:00" +%s)"

  USER_SET=()
  DAYS_LEFT_BY_USER=()
  STATUS_BY_USER=()
  DEVICES_BY_USER=()
  TRAFFIC_BY_USER=()

  collect_inbound_users
  collect_blocked_users "$MANUAL_BLOCK_TAG" "blocked"
  collect_blocked_users "$AUTO_BLOCK_TAG" "expired"
  collect_online_devices
  collect_traffic

  # default status for remaining users
  local u
  for u in "${!USER_SET[@]}"; do
    [[ -n "${STATUS_BY_USER[$u]:-}" ]] || STATUS_BY_USER["$u"]="enable"
  done

  # build output as TSV (then pretty-print with column if available)
  local out
  out+=$'user (online/offline)\tdevices\tstatus\ttraffic\tdays_left\n'

  while IFS= read -r u; do
    [[ -z "$u" ]] && continue

    local devices online status bytes traffic days
    devices="${DEVICES_BY_USER[$u]:-0}"
    [[ "$devices" =~ ^[0-9]+$ ]] || devices=0

    online="offline"
    (( devices > 0 )) && online="online"

    status="${STATUS_BY_USER[$u]:-enable}"
    bytes="${TRAFFIC_BY_USER[$u]:-0}"
    [[ "$bytes" =~ ^-?[0-9]+$ ]] || bytes=0

    # keep behaviour compatible with old "statistic" option (it doubled per-user traffic)
    bytes=$(( bytes * 2 ))
    traffic="$(fmt_bytes "$bytes")"

    days="${DAYS_LEFT_BY_USER[$u]:--}"

    out+="${u} (${online})\t${devices}\t${status}\t${traffic}\t${days}"$'\n'
  done < <(printf '%s\n' "${!USER_SET[@]}" | LC_ALL=C sort)

  if have_cmd column; then
    printf '%s' "$out" | column -t -s $'\t'
  else
    printf '%s' "$out"
  fi
}

case "$OPTION" in
  links)
    if [[ ! -r "$URI_PATH" ]]; then
      echo "❌ Error: check $URI_PATH it's missing or you do not have read permissions, exit"
      exit 1
    fi
    # just print database (without last empty string)
    sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$URI_PATH"
    exit 0
  ;;

  all)
    if [[ ! -r "$XRAY_CONFIG" ]]; then
      echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
      exit 1
    fi
    print_all_table
    exit 0
  ;;

  *)
    echo "❌ Error: wrong option, use: $0 links|all"
    exit 1
  ;;
esac
