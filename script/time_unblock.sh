#!/bin/bash
# script for manyally add user time in xray config

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# restart script for target user if have sudo without password
if [ "$(id -un)" != "$TARGET_USER" ]; then
    if ! exec sudo -n -u "$TARGET_USER" -- "$0" "$@"; then
        echo "❌ Error: failed to restart the script as user '$TARGET_USER'"
        exit 1
    fi
fi

# main variables
readonly USERNAME="$1"
# make tmp config
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }
DAYS="$2"

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    if rm -f "$TMP_XRAY_CONFIG" 2> /dev/null; then
        echo "✅ Success: delete tmp files"
    else
        echo "❌ Error: delete tmp files"
    fi
}

# set trap for tmp removing and exit message
trap 'rm_tmp' EXIT

# user check
[[ "$(whoami)" != "$TARGET_USER" ]] && { echo "❌ Error: you are not the '$TARGET_USER' user, exit"; exit 1; }

# argument check
if [[ "$#" -ne 2 || "$USERNAME" == "--help" ]]; then
    echo "Use for add time for user in xray config, run: $0 <username> <days>"
    echo "days 0 - infinity days"
    exit 0
fi

if [[ ! $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: days must be non negative number, exit"
    exit 1
fi

# helper function
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

# function for serch we have rule with ruleTag in config? true or false
search_rule() {
    local block_tag="$1"
    jq -r --arg ruleTag "$block_tag" '
        any(.routing.rules[]?; (.ruleTag? // "") == $ruleTag)
    ' "$XRAY_CONFIG" 2>/dev/null || echo "false"
}

# function for count how many times username blocked in rule
count_user_in_rule() {
    local block_tag="$1"
    jq -r --arg ruleTag "$block_tag" --arg name "$USERNAME" '
        [
            .routing.rules[]? | select(.ruleTag == $ruleTag) |
            ((.user // [])[]) |
            select((split("|")[0]) == $name)
        ] | length
    ' "$XRAY_CONFIG"
}

# main func for renew email and deleting from block rule
# shellcheck disable=SC2329
make_new_tmp_config() {
    jq \
        --arg inboundTag "$INBOUND_TAG" \
        --arg ruleTag "$EXPIRED_BLOCK_TAG" \
        --arg name "$USERNAME" \
        --arg newEmail "$NEW_FULL_EMAIL" \
        --argjson ruleExists "$( [[ "$EXPIRED_RULE_EXIST" == "true" ]] && echo true || echo false )" '
        
        # renew email if exist
        (.inbounds[]? | select(.tag == $inboundTag) | .settings.clients) |=
            ( . // [] | map(
                if (((.email // "") | split("|")[0]) == $name)
                then .email = $newEmail
                else .
                end
            )
        ) |

        # if block rule exist delete user from them
        (if $ruleExists then
            .routing = (.routing // {}) |
            .routing.rules = (.routing.rules // []) |
            .routing.rules |= map(
                if (.ruleTag? == $ruleTag) then
                    .user = ((.user // []) | map(select((split("|")[0]) != $name)))
                else .
                end
            ) |
            
            # if rule empty after user deleting, delete rule
            .routing.rules |= map(
                select( (.ruleTag? != $ruleTag) or (((.user // []) | length) > 0) )
            )
        else
            .
        end)
    ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG" || return 1
}

# function for install new config (original permission saved)
# shellcheck disable=SC2329
install_new_conf() { cat "$1" > "$2" || return 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"

# read and write conf check
read_and_write_check "$XRAY_CONFIG" "console"

# xray running check
xray_status_check "console"

# main logic start here
# write new username
if [[ "$DAYS" == "0" ]]; then
    NEW_FULL_EMAIL="${USERNAME}|created=${TODAY}|days=infinity|exp=never"
    DAYS="infinity"
    EXP="never"
else
    EXP="$(date -d "$TODAY +$DAYS days" +%F)"
    NEW_FULL_EMAIL="${USERNAME}|created=${TODAY}|days=${DAYS}|exp=${EXP}"
fi

# counts username in config (if have dublicat)
USERNAME_COUNT="$(
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
        [
            .inbounds[]? | select(.tag == $tag) |
            .settings.clients[]? |
            select(((.email // "") | split("|")[0]) == $name)
        ] | length
    ' "$XRAY_CONFIG"
)"

# to many client found, exit
# if client not found, exit
if [[ $USERNAME_COUNT -gt 1 ]]; then
    echo "❌ Error: '$USERNAME' to many match in clients inbound '$INBOUND_TAG', edit config manually, exit"
    exit 1
elif [[ $USERNAME_COUNT -eq 1 ]]; then
    echo "✅ Success: found client with name '$USERNAME' in inbound tag '$INBOUND_TAG'"
else
    echo "❌ Error: not found client with name '$USERNAME' in inbound tag '$INBOUND_TAG', exit"
    exit 1
fi

# we have rule with expired auto block? true or false
EXPIRED_RULE_EXIST="$(search_rule "$EXPIRED_BLOCK_TAG")"

# count how many time username blocked
EXPIRED_BLOCKED_COUNT=0
if [[ "$EXPIRED_RULE_EXIST" == "true" ]]; then
    EXPIRED_BLOCKED_COUNT="$(count_user_in_rule "$EXPIRED_BLOCK_TAG")"
fi

# exit if have expired block count > 1 user, its mean we have dublicat in rule
if [[ $EXPIRED_BLOCKED_COUNT -gt 1 ]]; then
    echo "❌ Error: '$USERNAME' to many match in ruleTag '$EXPIRED_BLOCK_TAG', edit config manually, exit"
    exit 1
fi

# we have rule with traffic auto block? true or false
TRAFFIC_BLOCK_EXIST="$(search_rule "$TRAFFIC_BLOCK_TAG")"

# count how many time name blocked
TRAFFIC_BLOCKED_COUNT=0
if [[ "$TRAFFIC_BLOCK_EXIST" == "true" ]]; then
    TRAFFIC_BLOCKED_COUNT="$(count_user_in_rule "$TRAFFIC_BLOCK_TAG")"
fi

# exit if have manual block for not changing unic name
if [[ $TRAFFIC_BLOCKED_COUNT -gt 0 ]]; then
    echo "❌ Error: '$USERNAME' blocked in '$TRAFFIC_BLOCK_TAG', reset user traffic first, exit"
    exit 1
fi

# we have rule with manual block? true or false
MANUAL_BLOCK_EXIST="$(search_rule "$MANUAL_BLOCK_TAG")"

# count how many time name blocked
MANUALLY_BLOCKED_COUNT=0
if [[ "$MANUAL_BLOCK_EXIST" == "true" ]]; then
    MANUALLY_BLOCKED_COUNT="$(count_user_in_rule "$MANUAL_BLOCK_TAG")"
fi

# exit if have manual block for not changing unic name
if [[ $MANUALLY_BLOCKED_COUNT -gt 0 ]]; then
    echo "❌ Error: '$USERNAME' blocked manualy in '$MANUAL_BLOCK_TAG', unblock user first, exit"
    exit 1
fi

if [[ "$EXPIRED_RULE_EXIST" == "true" ]]; then
    echo "✅ Success: found client for unblock name '$USERNAME' in ruleTag '$EXPIRED_BLOCK_TAG'"
else
    echo "✅ Success: blocked rule not found"
fi

# main logic start here
# make new config, add time and delete blocked user
run_and_check "change time for user '$USERNAME'" make_new_tmp_config

# if not changed, exit
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    echo "❌ Error: '$USERNAME' created and expiration date is the same, xray config not changed, exit"
    exit 1
fi

# check new conf
run_and_check "checking new tmp xray config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup old xray config
run_and_check "backup old xray config to '$XRAY_CONFIG_BACKUP'" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install new config (original permission saved)
run_and_check "install new xray config" install_new_conf "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"

# restart
run_and_check "restart xray service" systemctl restart xray.service

# echo result
echo "✅ Success: xray config updated for '$USERNAME'"
echo "✅ Success: new time, created: $TODAY, days: $DAYS, expiration: $EXP"

exit 0
