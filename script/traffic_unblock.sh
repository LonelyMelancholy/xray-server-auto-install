#!/usr/bin/env bash

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

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "❌ Error: you are not the '$TARGET_USER' user, exit"; exit 1; }

# main variable
readonly USERNAME="$1"

# argument check
if [[ "$#" -ne 1 || "$USERNAME" == "--help" ]]; then
    echo "Used to reset traffic for user and unblock"
    echo "run: $0 username"
    exit 0
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    echo "❌ Error: only letters, numbers and '-' or '_' in username, length 1-64 characters, exit"
    exit 1
fi

if [[ "$USERNAME" =~ ^[-_]|[-_]$ ]]; then
    echo "❌ Error: username must not start or end with '-' or '_', exit"
    exit 1
fi

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    if rm -f "$TMP_XRAY_CONFIG" 2> /dev/null && rm -f "$TMP_TR_DB_M" 2> /dev/null; then
        echo "✅ Success: delete tmp files"
    else
        echo "❌ Error: delete tmp files"
    fi
}

# set trap for tmp removing and exit message
trap 'rm_tmp' EXIT

# make tmp config and tr_db
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }
TMP_TR_DB_M="$(mktemp)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "tr_db" "console"

# read and write conf check
read_and_write_check "$XRAY_CONFIG" "console"
read_and_write_check "$TR_DB_M" "console"

# xray running check
xray_status_check "console"

# function section
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

# for unblock: find client emails in inbound Vless, match USERNAME|*
get_client_emails() {
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
        .inbounds[]? | select(.tag == $tag)
        | .settings.clients[]?
        | select(((.email // "") | split("|")[0]) == $name)
        | .email // empty
    ' "$XRAY_CONFIG"
}

# for unblock: find all client only from OUR tagged managed rule, match USERNAME|*
get_blocked_emails_from_rule() {
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" --arg bot "$BLOCK_OUTBOUND_TAG" --arg brt "$TRAFFIC_BLOCK_TAG" '
        def is_managed_rule:
            (.type == "field")
            and (.outboundTag == $bot)
            and ((.inboundTag // []) | index($tag))
            and ((.ruleTag // "") == $brt)
            and has("user")
            and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

            (.routing.rules[]? | select(is_managed_rule) | .user[]?)
            | select((split("|")[0]) == $name) | select(length>0)
    ' "$XRAY_CONFIG"
}

# function for unblock email
# shellcheck disable=SC2329
make_new_conf() {
    jq --arg tag "$INBOUND_TAG" \
        --arg bot "$BLOCK_OUTBOUND_TAG" \
        --arg rt "$TRAFFIC_BLOCK_TAG" \
        --argjson emails "$EMAILS_JSON" '
    .outbounds = (.outbounds // []) |
    if any(.outbounds[]?; .tag == $bot) then .
    else .outbounds += [{"tag": $bot, "protocol": "blackhole"}]
    end |

    .routing = (.routing // {}) |
    .routing.rules = (.routing.rules // []) |

    def is_managed_rule:
        (.type == "field")
        and (.outboundTag == $bot)
        and ((.inboundTag // []) | index($tag))
        and ((.ruleTag // "") == $rt)
        and has("user")
        and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

    if any(.routing.rules[]?; is_managed_rule) then .
    else .routing.rules |= ([{"type":"field","ruleTag":$rt,"inboundTag":[$tag],"outboundTag":$bot,"user":[]} ] + .)
    end
    | .routing.rules |= map(
         if is_managed_rule then .user = ((.user // []) - $emails) else . end
        )
    | del(.routing.rules[] | select(is_managed_rule and ((.user // []) | length == 0)))
' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}

# function for install config with save permission
# shellcheck disable=SC2329
install_new_conf() { cat "$1" > "$2" || return 1; }

# function for reset traffic value to 0 in tr_db
# shellcheck disable=SC2329
reset_user_traffic() {
  local user="$1"

  jq --arg u "$user" '
    (.stat[]
      | select(.name? | startswith("user>>>" + $u + "|"))
      | select(has("value"))
      | .value
    ) = 0
  ' "$TR_DB_M" > "$TMP_TR_DB_M"
}

# main logic start here
# check client exist or not
mapfile -t EMAILS < <(get_client_emails)
if [[ ${#EMAILS[@]} -gt 1 ]]; then
    echo "❌ Error: '$USERNAME' too many matches in clients inbound '$INBOUND_TAG', edit config manually, exit"
    exit 1
elif [[ ${#EMAILS[@]} -eq 1 ]]; then
    echo "✅ Success: found client with name '$USERNAME' in inbound tag '$INBOUND_TAG'"
else
    echo "❌ Error: not found client with name '$USERNAME' in inbound tag '$INBOUND_TAG', exit"
    exit 1
fi

# check client only in our tagged rule
mapfile -t EMAILS < <(get_blocked_emails_from_rule)
if [[ ${#EMAILS[@]} -gt 1 ]]; then
    echo "❌ Error: '$USERNAME' too many matches in ruleTag '$TRAFFIC_BLOCK_TAG', edit config manually, exit"
    exit 1
elif [[ ${#EMAILS[@]} -eq 1 ]]; then
    echo "✅ Success: found client for unblock name '$USERNAME' in ruleTag '$TRAFFIC_BLOCK_TAG'"
    # convert email to json
    EMAILS_JSON="$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)"

    # run func for remove user in block rule
    run_and_check "unblock user '$USERNAME', ruleTag '$TRAFFIC_BLOCK_TAG'" make_new_conf

    # checking new config
    run_and_check "checking new tmp xray config" xray run -test -config "$TMP_XRAY_CONFIG"

    # backup
    run_and_check "backup old xray config to '$XRAY_CONFIG_BACKUP'" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

    # install new file with save permission
    run_and_check "install new xray config" install_new_conf "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"

    # restart xray
    run_and_check "restart xray service" systemctl restart xray.service

    echo "✅ Success: xray config updated for '$USERNAME'"
else
    echo "✅ Success: blocked rule not found"
    echo "✅ Success: xray config not changed"
fi


# reset user traffic to 0 in tmp file
run_and_check "reset user traffic in new tmp TR_DB_M for name '$USERNAME'" reset_user_traffic "$USERNAME"

if ! jq empty "$TMP_TR_DB_M" &> /dev/null; then
    cp -f "$TMP_TR_DB_M" "${TR_DB_M}.bad_new_${TS}.json" 
    echo "❌ Error: cannot parse xray new tmp TR_DB_M; saved raw to ${TR_DB_M}.bad_new_${TS}.json, exit"
    exit 1
fi

# backup
run_and_check "backup old TR_DB_M to '$TR_DB_M_BACKUP'" cp -a "$TR_DB_M" "$TR_DB_M_BACKUP"

# install new
run_and_check "install new TR_DB_M" install_new_conf "$TMP_TR_DB_M" "$TR_DB_M"

echo "✅ Success: TR_DB_M updated for '${USERNAME}'"

exit 0
