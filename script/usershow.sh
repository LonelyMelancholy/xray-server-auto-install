#!/bin/bash
# script for show user from xray config and URI_DB

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/user.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on xray configuration or URI DB, exit"; exit 1; }

if [[ "$#" -eq 1 ]]; then
    echo "Use for show user from xray config and URI_DB, run: $0 <option>"
    echo "all - all user link and expiration info"
    echo "ban - blocked manualy user"
    echo "exp - expiered, auto blocked user"
    exit 1
fi

OPTION="$1"
URI_PATH="/usr/local/etc/xray/URI_DB"

case "$OPTION" in
    all)
        cat "$URI_PATH"
        exit 0
    ;;;
    ban)

    ;;;
    exp)

    ;;;
    *)
    echo "❌ Error: wrong option, read help again, exit"
    exit 1
    ;;
esac

