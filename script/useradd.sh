#!/bin/bash
# script for add user in xray config

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 8 || { echo "❌ Error: another instance working on '$LOCK_FILE', exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE_2="/run/lock/uri_db.lock"
exec 9> "$LOCK_FILE_2" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_2', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on '$LOCK_FILE_2', exit"; exit 1; }

# prevents attempts to restart via this script while the update is in progress
readonly LOCK_FILE_4="/run/lock/xray_update.lock"
exec 99> "$LOCK_FILE_4" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_4', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# main variables
readonly URI_PATH="/usr/local/etc/xray/URI_DB"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly BACKUP_PATH="${XRAY_CONFIG}.$(date +%Y%m%d_%H%M%S).bak"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly INBOUND_TAG="Vless"
readonly DEFAULT_FLOW="xtls-rprx-vision"
readonly USERNAME="$1"
readonly URI_BAK="${URI_PATH}.$(date +%Y%m%d_%H%M%S).bak"
DAYS="$2"

# helper func
try() { "$@" || return 1; }

run_and_check() {
    action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
}

# argument check
if [[ "$#" -ne 2 ]]; then
    echo "Use for add user in xray config, run: $0 <username> <days>"
    echo "days 0 - infinity days"
    exit 1
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: days must be non negative number, exit"
    exit 1
fi

# counts client in config
client_count="$(
  jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
    [
      .inbounds[]? | select(.tag == $tag) |
      .settings.clients[]? |
      select(((.email // "") | split("|")[0]) == $name)
    ] | length
  ' "$XRAY_CONFIG"
)"

if [[ $client_count -ge 1 ]]; then
    echo "❌ Error: name already exist in xray config, exit"
    exit 1
fi

# config check
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# calculate exp and created date
readonly CREATED="$(date +%F)"

# write variable
if [[ "$DAYS" == "0" ]]; then
    XRAY_EMAIL="${USERNAME}|created=${CREATED}|days=infinity|exp=never"
    DAYS="infinity"
    EXP="never"
else
    EXP="$(date -d "$CREATED + $DAYS days" +%F)"
    XRAY_EMAIL="${USERNAME}|created=${CREATED}|days=${DAYS}|exp=${EXP}"
fi

# check inbound
readonly HAS_INBOUND="$(jq --arg tag "$INBOUND_TAG" '
  any(.inbounds[]?; .tag == $tag and .protocol == "vless")
' "$XRAY_CONFIG")"

if [[ "$HAS_INBOUND" != "true" ]]; then
  echo "❌ Error: config not have vless-inbound, tag=\"$INBOUND_TAG\", exit"
  exit 1
fi

# uuid generation
if [[ -x "$XRAY_BIN" ]]; then
    readonly UUID="$("$XRAY_BIN" uuid)"
else
    echo "❌ Error: not found $XRAY_BIN, for UUID generation, exit"
    exit 1
fi

xray_useradd() {
    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    try chmod 600 "$TMP_XRAY_CONFIG"

    # set trap for deleting tmp files
    trap 'rm -f "$TMP_XRAY_CONFIG"' EXIT
    
    # add user
    try jq --arg tag "$INBOUND_TAG" \
        --arg email "$XRAY_EMAIL" \
        --arg id "$UUID" \
        --arg dflow "$DEFAULT_FLOW" '
        (.inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // $dflow) as $flow
        | .inbounds = (.inbounds | map(
            if .tag == $tag and .protocol == "vless" then
            .settings.clients += [{
                "email": $email,
                "id": $id,
                "flow": $flow
                }]
            else .
            end
        ))
    ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}

# add user, check config, install if config valid and delete tmp files
run_and_check "add xray user in config" xray_useradd
run_and_check "new xray config checking" xray run -test -config "$TMP_XRAY_CONFIG"
run_and_check "backup xray config" cp -a "$XRAY_CONFIG" "$BACKUP_PATH"
run_and_check "install new xray config" cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG"
run_and_check "delete temporary xray files " rm -f "$TMP_XRAY_CONFIG"

# unset trap, tmp already deleted
trap - EXIT

# restart xray for enable user
run_and_check "restart xray service" systemctl restart xray.service

# start make link, get inbound paremetres
readonly PORT="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .port
' "$XRAY_CONFIG")"

readonly REALITY_SNI="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.serverNames[0] // ""
' "$XRAY_CONFIG")"

readonly PRIVATE_KEY="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.privateKey // ""
' "$XRAY_CONFIG")"

readonly SHORT_ID="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.shortIds[0] // ""
' "$XRAY_CONFIG")"

readonly FLOW="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // ""
' "$XRAY_CONFIG")"

check_var() {
    local name="$1"
    local value="${!name}"
    if [ -z "$value" ]; then
        echo "❌ Error: $name not found in realitySettings inbound"
        exit 1
    fi
}

check_var PORT
check_var REALITY_SNI
check_var PRIVATE_KEY
check_var SHORT_ID
check_var FLOW

# generate public key from privat key
readonly XRAY_X25519_OUT="$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY")"

readonly PUBLIC_KEY="$(printf '%s\n' "$XRAY_X25519_OUT" | awk -F': ' '/Password:/ {print $2}')"

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "❌ Error: empty publicKey/password, exit"
  exit 1
fi

# get server ip
SERVER_HOST="$(curl -4 -s https://ifconfig.io || curl -4 -s https://ipinfo.io/ip || echo "")"

if [ -z "$SERVER_HOST" ]; then
    SERVER_HOST="SERVER_IP"  # плейсхолдер, если не смогли определить
fi

# make uri link
uri_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

QUERY="encryption=none"
QUERY="${QUERY}&flow=$(uri_encode "$FLOW")"
QUERY="${QUERY}&security=reality"
QUERY="${QUERY}&type=tcp"
QUERY="${QUERY}&sni=$(uri_encode "$REALITY_SNI")"
QUERY="${QUERY}&fp=$(uri_encode "chrome")"
QUERY="${QUERY}&pbk=$(uri_encode "$PUBLIC_KEY")"
QUERY="${QUERY}&sid=$(uri_encode "$SHORT_ID")"
readonly NAME_ENC="$(uri_encode "$USERNAME")"
readonly VLESS_URI="vless://${UUID}@${SERVER_HOST}:${PORT}/?${QUERY}#${NAME_ENC}"

# print result
cp -a "$URI_PATH" "$URI_BAK"
echo "✅ Success: Backup saved $URI_BAK"
echo "✅ Success: name $USERNAME, added"
tee -a "$URI_PATH" <<EOF
name: $USERNAME, created: $CREATED, days: $DAYS, expiration: $EXP
name: $USERNAME, vless link: $VLESS_URI

EOF