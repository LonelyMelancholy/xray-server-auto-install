#!/bin/bash
# script for del user in xray config

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# restart script for target user if have sudo without password
if [ "$(id -un)" != "$TARGET_USER" ]; then
    if ! exec sudo -n -u "$TARGET_USER" -- "$SCRIPT_FULL_PATH" "$@"; then
        echo "❌ Error: failed to restart the script as user '$TARGET_USER'"
        exit 1
    fi
fi

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "❌ Error: you are not the '$TARGET_USER' user, exit"; exit 1; }

# main variables
readonly USERNAME="$1"

# argument check
if [[ "$#" -ne 1 || "$USERNAME" == "--help" ]]; then
    echo "Used to delete user from xray config"
    echo "run: $0 username"
    exit 0
fi

if ! [[ "$USERNAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,62}[A-Za-z0-9]$ ]]; then
    echo "❌ Error: username must be 3..64 characters long and contain only letters, numbers and '-' or '_', begin and end with a letter or number, exit"
    exit 1
fi

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    if rm -f "$TMP_XRAY_CONFIG" "$TMP_URI_DB" 2> /dev/null; then
        echo "✅ Success: delete tmp files"
    else
        echo "❌ Error: delete tmp files"
    fi
}

# set trap for tmp removing and exit message
trap 'rm_tmp' EXIT

# make tmp file for uri and config
TMP_URI_DB="$(mktemp)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "uri_db" "console"

# read and write conf check
read_and_write_check "$XRAY_CONFIG" "console"
read_and_write_check "$URI_DB" "console"

# xray running check
xray_status_check "console"

# function section
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

# function for make new conf and delete user from inbound and blocked rules
# shellcheck disable=SC2329
make_new_conf() {
    # delete user and add to tmp conf (also clear from block rules)
    jq --arg t "$USERNAME" --arg tag "$INBOUND_TAG" '
        def base: split("|")[0];

        # remove from inbound clients (by email base part before "|")
        .inbounds |= map(
            if (.tag == $tag) and (.settings? and .settings.clients?) then
            .settings.clients |= map(select((.email | base) != $t))
            else
            .
            end
        )
        |

        # remove from routing block rules + drop rule if user[] becomes empty
        (if (.routing? and .routing.rules?) then
            .routing.rules |= (
            map(
                if ((.ruleTag? == "autoblock-expired-users") or (.ruleTag? == "manual-block-users") or (.ruleTag? == "autoblock-traffic-users"))
                    and (.user? and (.user|type)=="array") then
                .user |= map(select((. | base) != $t))
                else
                .
                end
            )

            # drop empty block rules
            | map(select(
                if ((.ruleTag? == "autoblock-expired-users") or (.ruleTag? == "manual-block-users") or (.ruleTag? == "autoblock-traffic-users"))
                    and (.user? and (.user|type)=="array") then
                    (.user | length) > 0
                else
                    true
                end
                ))
            )
        else
            .
        end)
        ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"

    # count numbers match users after
    AFTER="$(jq -r --arg t "$USERNAME" --arg tag "$INBOUND_TAG" "$COUNT_FILTER" "$TMP_XRAY_CONFIG")"

    # count blocked records after
    BLOCK_AFTER="$(jq -r --arg t "$USERNAME" "$BLOCK_COUNT_FILTER" "$TMP_XRAY_CONFIG")"

    # count how many users were deleted
    REMOVED=$((BEFORE - AFTER))

    # count how many block entries were deleted
    BLOCK_REMOVED=$((BLOCK_BEFORE - BLOCK_AFTER))
}

# function for delete username from uri_db
# shellcheck disable=SC2329
make_new_uri() {
    # paste in tmp file string without name: username,
    # and skip empty string after name block
    awk -v u="$USERNAME" '
        $0 ~ ("^name:[[:space:]]*" u "([^[:alnum:]-]|$)") { skip_blank=1; next }
        skip_blank && $0 ~ /^[[:space:]]*$/ { skip_blank=0; next }
        { skip_blank=0; print }
    ' "$URI_DB" > "$TMP_URI_DB" || return 1
}

# function for install new conf with save file permission 
# shellcheck disable=SC2329
install_new_conf() { cat "$1" > "$2"; }

# main logic start here
# count clients var for jd
# shellcheck disable=SC2016
readonly COUNT_FILTER='[
  .inbounds[]
  | select(.tag == $tag)
  | .settings.clients[]?
  | select((.email | split("|")[0]) == $t)
] | length'

# count blocked records in routing rules (only these 3 ruleTag)
# shellcheck disable=SC2016
readonly BLOCK_COUNT_FILTER='[
  .routing.rules[]?
  | select(.ruleTag == "autoblock-expired-users" or .ruleTag == "autoblock-traffic-users" or .ruleTag == "manual-block-users")
  | .user[]?
  | select((split("|")[0]) == $t)
] | length'

# count numbers match users before delete in block rules
BLOCK_BEFORE="$(jq -r --arg t "$USERNAME" "$BLOCK_COUNT_FILTER" "$XRAY_CONFIG")"

# count numbers match users before delete in inbound
BEFORE="$(jq -r --arg t "$USERNAME" --arg tag "$INBOUND_TAG" "$COUNT_FILTER" "$XRAY_CONFIG")"

if [[ "$BEFORE" -eq 0 && $BLOCK_BEFORE -eq 0 ]]; then
    echo "❌ Error: no matches found for: '$USERNAME'. Nothing to delete, exit"
    exit 1
fi

# del user, check config, install if config valid and delete tmp files, restart xray
run_and_check "delete xray user and make new xray config" make_new_conf

# config checking
run_and_check "checking new xray config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup old conf
run_and_check "backup old xray config '$XRAY_CONFIG_BACKUP'" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install new config
run_and_check "install new xray config" install_new_conf "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"

# restart xray
run_and_check "restart xray service" systemctl restart xray.service

# echo result
echo "✅ Success: removed '$REMOVED' client(s) for '$USERNAME' from inbound tag '$INBOUND_TAG'"

if [[ "$BLOCK_REMOVED" -gt 0 ]]; then
    echo "✅ Success: removed '$BLOCK_REMOVED' block record(s) for '$USERNAME' from routing rules (autoblock-expired-users/manual-block-users/autoblock-traffic-users)"
else
    echo "✅ Success: block record for '$USERNAME' from routing rules (autoblock-expired-users/manual-block-users/autoblock-traffic-users) not found"
fi

# if user removed need to remove user from uri file
if [[ "$REMOVED" -gt 0 && -f "$URI_DB" ]]; then
    # backup old conf
    run_and_check "backup old URI_DB '$URI_DB_BACKUP'" cp -a "$URI_DB" "$URI_DB_BACKUP"

    # clear username from uri_db
    run_and_check "delete xray user and make new URI_DB" make_new_uri

    # write from tmp to uri
    run_and_check "install new URI_DB" install_new_conf "$TMP_URI_DB" "$URI_DB"

    # echo result
    echo "✅ Success: removed '$REMOVED' client(s) for '$USERNAME' from URI database"
fi

exit 0
