#!/bin/bash
# script for add user in xray config

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# main variables
readonly DEFAULT_FLOW="xtls-rprx-vision"
readonly USERNAME="$1"
DAYS="$2"

# argument check
if [[ "$#" -ne 2 || "$USERNAME" == "--help" ]]; then
    echo "Use for add user in xray config, run: $0 <username> <days>"
    echo "days 0 - infinity days"
    exit 0
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: days must be non negative number, exit"
    exit 1
fi

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "❌ Error: you are not the telegram_gateway user, exit"; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "uri_db" "console"

# read and write conf check
read_and_write_check "$XRAY_CONFIG" "console"
read_and_write_check "$URI_DB" "console"

# make tmp file
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp_config() {
    if rm -f "$TMP_XRAY_CONFIG" 2> /dev/null; then
        echo "✅ Success: delete tmp config file"
    else
        echo "❌ Error: delete tmp config file"
    fi
}

# set trap for tmp removing and exit message
trap 'rm_tmp_config' EXIT

# helper func
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

make_new_config() {
    # add user
    jq --arg tag "$INBOUND_TAG" \
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

install_new_conf() { cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG"; }

# function for checking variables in json config
check_var() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]; then
        echo "❌ Error: $name not found in realitySettings inbound, exit"
        exit 1
    fi
}

# make uri link function
uri_encode() { printf '%s' "$1" | jq -sRr @uri; }

# function for update URI_DB
install_new_uri_db() {
    tee -a "$URI_DB" >/dev/null <<EOF
name: $USERNAME, vless link: $VLESS_URI

EOF
}

# main logic start here
# counts client in config
USERNAME_COUNT="$(
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
        [
            .inbounds[]? | select(.tag == $tag) |
            .settings.clients[]? |
            select(((.email // "") | split("|")[0]) == $name)
        ] | length
    ' "$XRAY_CONFIG"
)"

# if client exist, exit
if [[ $USERNAME_COUNT -ge 1 ]]; then
    echo "❌ Error: name already exist in xray config, exit"
    exit 1
fi

# calculate exp and created date
# write variable
if [[ "$DAYS" == "0" ]]; then
    XRAY_EMAIL="${USERNAME}|created=${TODAY}|days=infinity|exp=never"
    DAYS="infinity"
    EXP="never"
else
    EXP="$(date -d "$TODAY + $DAYS days" +%F)"
    XRAY_EMAIL="${USERNAME}|created=${TODAY}|days=${DAYS}|exp=${EXP}"
fi

# check inbound
readonly HAS_INBOUND="$(jq --arg tag "$INBOUND_TAG" '
    any(.inbounds[]?; .tag == $tag and .protocol == "vless")
' "$XRAY_CONFIG")"

# if not have inbound, exit
if [[ "$HAS_INBOUND" != "true" ]]; then
    echo "❌ Error: config not have vless-inbound, tag='$INBOUND_TAG', exit"
    exit 1
fi

# uuid generation
readonly UUID="$(xray uuid)"

# add user
run_and_check "add xray user and make new config" make_new_config

# check config
run_and_check "checking new xray config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup config
run_and_check "backup old xray config '$XRAY_CONFIG_BACKUP'" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install if config valid
run_and_check "install new xray config" install_new_conf

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

# checking empty variable or not
check_var "PORT" "$PORT"
check_var "REALITY_SNI" "$REALITY_SNI"
check_var "PRIVATE_KEY" "$PRIVATE_KEY"
check_var "SHORT_ID" "$SHORT_ID"
check_var "FLOW" "$FLOW"

# generate public key from privat key
readonly XRAY_X25519_OUT="$(xray x25519 -i "$PRIVATE_KEY")"
readonly PUBLIC_KEY="$(printf '%s\n' "$XRAY_X25519_OUT" | awk -F': ' '/Password:/ {print $2}')"

# checking pubkey not empty
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "❌ Error: empty publicKey/password, exit"
  exit 1
fi

# get server ip
SERVER_HOST="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

# if not get ip set host as hostname
if [ -z "$SERVER_HOST" ]; then
    SERVER_HOST="$(hostname)"
fi

# get link
readonly VLESS_URI="vless://${UUID}@${SERVER_HOST}:${PORT}/?encryption=none&flow=$(uri_encode "$FLOW")&\
security=reality&type=tcp&sni=$(uri_encode "$REALITY_SNI")&fp=$(uri_encode "chrome")&pbk=\
$(uri_encode "$PUBLIC_KEY")&sid=$(uri_encode "$SHORT_ID")#$(uri_encode "$USERNAME")"

# backup old uri_db
run_and_check "backup old URI_DB '$URI_DB_BACKUP'" cp -a "$URI_DB" "$URI_DB_BACKUP"
echo "✅ Success: Backup saved $URI_DB_BACKUP"

# update URI_DB
run_and_check "add user in URI_DB" install_new_uri_db

# print result
echo "✅ Success: name $USERNAME, added"
echo "✅ Success: created: $TODAY, days: $DAYS, expiration: $EXP"
echo "name: $USERNAME, vless link: $VLESS_URI"