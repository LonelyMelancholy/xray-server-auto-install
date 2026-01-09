#!/bin/bash
# script for del user in xray config

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/run/lock/xray_config.lock"
exec 8> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 8 || { echo "❌ Error: another instance working on '$LOCK_FILE', exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE_2="/run/lock/uri_db.lock"
exec 9> "$LOCK_FILE_2" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on '$LOCK_FILE', exit"; exit 1; }

# prevents attempts to restart via this script while the update is in progress
readonly LOCK_FILE_4="/run/lock/xray_update.lock"
exec 99> "$LOCK_FILE_4" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_4', exit"; exit 1; }
flock -n 99 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# argument check
if [[ "$#" -ne 1 ]]; then
    echo "Use for del user in xray config, run: $0 <username>"
    exit 1
fi

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly INBOUND_TAG="Vless"
readonly ARG_RAW="$1"
readonly USERNAME="${ARG_RAW%%|*}"
readonly URI_PATH="/usr/local/etc/xray/URI_DB"
readonly BACKUP_PATH="${XRAY_CONFIG}.$(date +%Y%m%d_%H%M%S).bak"
readonly URI_BAK="${URI_PATH}.$(date +%Y%m%d_%H%M%S).bak"

# config check
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# username check after parsing
if [[ -z "$USERNAME" ]]; then
    echo "❌ Error: empty username after parsing input, exit"
    exit 1
fi

if [[ ! $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

# helper func
try() { "$@" || return 1; }

run_and_check() {
    action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
}

# count clients var for jd
readonly COUNT_FILTER='[
  .inbounds[]
  | select(.tag == $tag)
  | .settings.clients[]?
  | select((.email | split("|")[0]) == $t)
] | length'

# count blocked records in routing rules (only these 2 ruleTag)
readonly BLOCK_COUNT_FILTER='[
  .routing.rules[]?
  | select(.ruleTag == "autoblock-expired-users" or .ruleTag == "manual-block-users")
  | .user[]?
  | select((split("|")[0]) == $t)
] | length'
readonly BLOCK_BEFORE="$(jq -r --arg t "$USERNAME" "$BLOCK_COUNT_FILTER" "$XRAY_CONFIG")"

# count numbers match users before
readonly BEFORE="$(jq -r --arg t "$USERNAME" --arg tag "$INBOUND_TAG" "$COUNT_FILTER" "$XRAY_CONFIG")"

if [[ "$BEFORE" -eq 0 ]]; then
    echo "❌ Error: no matches found for: '$USERNAME' in inbound tag \"Vless\". Nothing to do."
    exit 1
fi

xray_userdel() {
    # backup
    try cp -a "$XRAY_CONFIG" "$BACKUP_PATH"
    
    # make tmp file
    readonly TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    try chmod 600 "$TMP_XRAY_CONFIG"
    
    # set trap for tmp file
    trap 'rm -f "$TMP_XRAY_CONFIG" "$TMP_URI"' EXIT

    # delete user and add to tmp conf (also clear from block rules)
    try jq --arg t "$USERNAME" --arg tag "$INBOUND_TAG" '
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
                if ((.ruleTag? == "autoblock-expired-users") or (.ruleTag? == "manual-block-users"))
                    and (.user? and (.user|type)=="array") then
                .user |= map(select((. | base) != $t))
                else
                .
                end
            )

            # drop empty block rules
            | map(select(
                if ((.ruleTag? == "autoblock-expired-users") or (.ruleTag? == "manual-block-users"))
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

# del user, check config, install if config valid and delete tmp files, restart xray
run_and_check "delete xray user" xray_userdel
run_and_check "xray config checking" xray run -test -config "$TMP_XRAY_CONFIG"
install_new_conf() {
    cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG"
}
run_and_check "install new xray config" install_new_conf
run_and_check "restart xray service" systemctl restart xray.service

# echo result
echo "✅ Success: removed $REMOVED client(s) for '$USERNAME' from inbound tag '$INBOUND_TAG'"
echo "✅ Success: Backup saved $BACKUP_PATH"
if [[ "$BLOCK_REMOVED" -gt 0 ]]; then
    echo "✅ Success: removed $BLOCK_REMOVED block record(s) for '$USERNAME' from routing rules (autoblock-expired-users/manual-block-users)"
else
    echo "✅ Success: block record for '$USERNAME' from routing rules (autoblock-expired-users/manual-block-users) not found"
fi

# if user removed need to remove user from uri file
if [[ "$REMOVED" -gt 0 && -f "$URI_PATH" ]]; then
    uri_userdel() {
        # backup
        try cp -a "$URI_PATH" "$URI_BAK"

        # create tmp file
        readonly TMP_URI="$(mktemp)"

        # set trap for tmp file
        trap 'rm -f "$TMP_XRAY_CONFIG" "$TMP_URI"' EXIT

        # paste in tmp file without username
        try awk -v t="$USERNAME" '
            BEGIN { skipping=0 }
            $0 ~ ("^name:[ \t]*" t "([ \t,].*|$)") {
                skipping=1
                next
            }
            skipping==1 {
                if ($0 ~ /^[ \t]*$/) { skipping=0; next }
                next
            }
            { print }
        ' "$URI_PATH" > "$TMP_URI"

        # write from tmp to uri
        try cat "$TMP_URI" > "$URI_PATH"
    }

    run_and_check "clear user from URI database" uri_userdel

    echo "✅ Success: removed $REMOVED client(s) for '$USERNAME' from URI database"
    echo "✅ Success: Backup saved $URI_BAK"
fi

exit 0