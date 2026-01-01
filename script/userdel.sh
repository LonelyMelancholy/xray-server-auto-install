#!/bin/bash
# script for del user in xray config

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/user.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on xray configuration or URI DB, exit"; exit 1; }

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

# function error helper
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
        return 0
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# count clients var for jd
readonly COUNT_FILTER='[
  .inbounds[]
  | select(.tag == $tag)
  | .settings.clients[]?
  | select((.email | split("|")[0]) == $t)
] | length'

# count numbers match users before
readonly BEFORE="$(jq -r --arg t "$USERNAME" --arg tag "$INBOUND_TAG" "$COUNT_FILTER" "$XRAY_CONFIG")"

if [[ "$BEFORE" -eq 0 ]]; then
    echo "❌ Error: no matches found for: '$USERNAME' in inbound tag \"Vless\". Nothing to do."
    exit 1
fi

xray_userdel() {
    set -e
    # backup
    cp -a "$XRAY_CONFIG" "$BACKUP_PATH"
    
    # make tmp file
    readonly TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    chmod 644 "$TMP_XRAY_CONFIG"
    
    # set trap for tmp file
    trap 'rm -f "$TMP_XRAY_CONFIG" "$TMP_URI"' EXIT

    # delete user and add to tmp conf
    jq --arg t "$USERNAME" --arg tag "$INBOUND_TAG" '
        def base_email: split("|")[0];
        .inbounds |= map(
            if (.tag == $tag) and (.settings? and .settings.clients?) then
            .settings.clients |= map(select((.email | base_email) != $t))
            else
            .
            end
        )
    ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"

    # count numbers match users after
    AFTER="$(jq -r --arg t "$USERNAME" --arg tag "$INBOUND_TAG" "$COUNT_FILTER" "$TMP_XRAY_CONFIG")"

    # count how many users were deleted
    REMOVED=$((BEFORE - AFTER))
}

# del user, check config, install if config valid and delete tmp files, restart xray
run_and_check "delete xray user" xray_userdel
run_and_check "xray config checking" sudo -u xray xray run -test -config "$TMP_XRAY_CONFIG"
run_and_check "install new xray config" install -m 600 -o xray -g xray "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"
run_and_check "restart xray service" systemctl restart xray.service

# echo result
echo "✅ Success: removed $REMOVED client(s) for '$USERNAME' from inbound tag '$INBOUND_TAG'"
echo "✅ Success: Backup saved $BACKUP_PATH"

# if user removed need to remove user from uri file
if [[ "$REMOVED" -gt 0 && -f "$URI_PATH" ]]; then
    uri_userdel() {
        # backup
        cp -a "$URI_PATH" "$URI_BAK"

        # create tmp file
        readonly TMP_URI="$(mktemp)"

        # set trap for tmp file
        trap 'rm -f "$TMP_XRAY_CONFIG" "$TMP_URI"' EXIT

        # paste in tmp file without username
        awk -v t="$USERNAME" '
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
        install -m 600 -o root -g root "$TMP_URI" "$URI_PATH"
    }

    run_and_check "clear user from URI database" uri_userdel

    echo "✅ Success: removed $REMOVED client(s) for '$USERNAME' from URI database"
    echo "✅ Success: Backup saved $URI_BAK"
fi

exit 0