#!/bin/bash
# script for show users from xray config and URI_DB

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# main variables
readonly OPTION="$1"
readonly MANUAL_BLOCK_TAG="manual-block-users"
readonly EXPIRED_BLOCK_TAG="autoblock-expired-users"
readonly TRAFFIC_BLOCK_TAG="autoblock-traffic-users"
declare -A FULL_USERNAMES=()
declare -A DAYS_LEFT_BY_USER=()
declare -A STATUS_BY_USER=()
declare -A ONLINE_BY_USER=()
declare -A DEVICES_BY_USER=()
declare -A TRAFFIC_BY_USER=()

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "❌ Error: you are not the telegram_gateway user, exit"; exit 1; }

# function for print help
helper_f() {
    echo "Use for show user from xray config and URI_DB, run: $0 <option>"
    echo "links - all user link and expiration info"
    echo "all - table: username (online/offline), devices, (blocked/expired/enable), traffic, days left"
    exit 0
}

# argument check
if [[ "$#" -ne 1 || "$OPTION" == "--help" ]]; then
    helper_f
fi

# check another instanсe of the script is not running
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "tr_db" "console"
run_lock_check "uri_db" "console"

# read permission check
read_check "$XRAY_CONFIG" "console"
read_check "$URI_DB" "console"
read_check "$TR_DB_M" "console"

# run helping function for logging
run_and_check() {
    local action="$1"
    shift 1
    if ! "$@" > /dev/null; then
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# function for extract YYYY-MM-DD from strings like: "...|exp=2026-04-16". Prints nothing if not found
# shellcheck disable=SC2329
parse_exp_date() { sed -nE 's/.*\|exp=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' <<<"$1"; }

# function for calculate days left from YYYY-MM-DD
# shellcheck disable=SC2329
calc_days_left() {
    local exp_date="$1"
    local exp_epoch
    # if error just exit with no error, empty value is being processed in main function 
    exp_epoch="$(date -d "$exp_date" +%s 2>/dev/null)" || return 0
    echo "$(( (exp_epoch - $(date -d "today 00:00" '+%s') ) / 86400 ))"
}

# function for bytes to human read
# shellcheck disable=SC2329
fmt_bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null; }

# parse config for full usernames, get duplicates too, and set mark with number
# shellcheck disable=SC2329
collect_inbound_users_array() {
    local username full_username full_username_list duplicate_number=0

    full_username_list="$(jq -r --arg tag "$INBOUND_TAG" '.inbounds[]? | select(.tag? == $tag) | .settings? | .clients?[]? | .email? // empty' "$XRAY_CONFIG" 2>/dev/null)"

    while IFS= read -r full_username; do
        # cut username| and check if empty, continue to next user
        username="${full_username%%|*}"
        [[ -z "$username" ]] && continue

        # if we have duplicate, mark him
        if [[ -n ${FULL_USERNAMES["$username"]} ]]; then
            ((duplicate_number++))
            # set array with full usernames
            FULL_USERNAMES["${username}[duplicate${duplicate_number}]"]="$full_username"
        else
            # set array with full usernames
            FULL_USERNAMES["$username"]="$full_username"
        fi
    done <<<"$full_username_list"
}

# collect array with exp dates from full_username
# shellcheck disable=SC2329
collect_days_left_from_record_array() {
    local username_w_d
    local days_left
    local exp_date
    for username_w_d in "${!FULL_USERNAMES[@]}"; do
        # for every username print full username and parse date expiration,
        # if empty set to infinity days left in array and start to new user
        exp_date="$(parse_exp_date "${FULL_USERNAMES["$username_w_d"]}")"
        if [[ -z "$exp_date" ]]; then
            DAYS_LEFT_BY_USER["$username_w_d"]="infinity"
            continue
        fi
        # if empty set to unknown, if not empty - set actual days
        days_left="$(calc_days_left "$exp_date")"
        if [[ -z "$days_left" ]]; then
            DAYS_LEFT_BY_USER["$username_w_d"]="unknown"
        else
            DAYS_LEFT_BY_USER["$username_w_d"]="$days_left"
        fi
    done
}

# collect array with status full_username - [enable-blocked-traffic_ban-expired_ban]
# only one status can set, every iteration rewrite old value if we have new value
# shellcheck disable=SC2329
collect_blocked_users_array() {
    local tag="$1"     # MANUAL_BLOCK_TAG or AUTO_BLOCK_TAG
    local status="$2"  # blocked / expired
    local full_username_list_blocked
    local full_username
    # get list blocked full username
    full_username_list_blocked="$(jq -r --arg tag "$tag" '.routing.rules[]? | select(.ruleTag == $tag) | (.user // [])[]? // empty' "$XRAY_CONFIG" 2>/dev/null)"

    # set array full username - blocked status
    while IFS= read -r full_username; do
        [[ -z "$full_username" ]] && continue
        STATUS_BY_USER["$full_username"]="$status"
    done <<<"$full_username_list_blocked"
}

# collect array with online status full_username [online-offline]
# shellcheck disable=SC2329
collect_online_users_array() {
    local full_username_list_online
    local full_username
    local xray_api_json

    # get online list in json from api
    xray_api_json="$(xray api statsgetallonlineusers)"

    # convert json to list in variable
    full_username_list_online=$(
        jq -r '.users // []
            | .[]
            | sub("^user>>>";"")
            | sub(">>>online$";"")
            ' <<<"$xray_api_json" 2>/dev/null | awk 'NF'
        )

    # read variable and set array full username - online status
    while IFS= read -r full_username; do
        [[ -z "$full_username" ]] && continue
        ONLINE_BY_USER["$full_username"]="🟢 online"
    done <<<"$full_username_list_online"
}

# collect array with number of device full_username - [device]
# shellcheck disable=SC2329
collect_online_devices_array() {
    local online_json online_val username full_username
    
    # for every username get online stat for full username - number devices
    for username in "${!FULL_USERNAMES[@]}"; do
        # for every username print full username and get stat
        full_username="${FULL_USERNAMES["$username"]}"
        online_json="$(xray api statsonline --email "$full_username" 2>/dev/null)"
        online_val="$(jq -r '.stat.value // 0' <<<"$online_json" 2>/dev/null)"
        [[ "$online_val" =~ ^[0-9]+$ ]] || online_val=0
        DEVICES_BY_USER["$full_username"]="$online_val"
    done
}

# function for collect array with user traffic (only monthly) all username duplicate summary in one username
# shellcheck disable=SC2329
collect_users_traffic_array() {
    local raw lines full_username bytes username

    # get raw json from TR_DB if empty, exit
    raw="$(cat "$TR_DB_M" 2>/dev/null)"
    [[ -z "$raw" ]] && return 0

    # parse json to [full_username   traffic]
    lines="$(jq -r '
        (.stat // [])[]?
        | select(.name? and (.name | startswith("user>>>")))
        | (.name | split("user>>>")[1] | split(">>>traffic>>>")[0]) as $full_username
        | "\($full_username)\t\(.value // 0)"
    ' <<<"$raw" 2>/dev/null)"

    # read in cycle 
    while IFS=$'\t' read -r full_username bytes; do

        # cut username| and check if empty, continue to next user
        username="${full_username%%|*}"
        [[ -z "$username" ]] && continue

        # if bytes not valid or empty set 0
        [[ "$bytes" =~ ^-?[0-9]+$ ]] || bytes=0

        # set array [username]=traffic, start from 0, add traffic in each iteration
        TRAFFIC_BY_USER["$username"]=$(( ${TRAFFIC_BY_USER["$username"]:-0} + bytes ))
    done <<<"$lines"
}

# function for collect and print all info table
# shellcheck disable=SC2329
print_all_table() {
    local out username username_w_d full_username online devices status bytes traffic days

    # run all array collect function with log helper, if success - no out text, if error - print error and exit
    run_and_check "collect users inbound array" collect_inbound_users_array
    run_and_check "collect users days left arrray" collect_days_left_from_record_array
    run_and_check "collect blocked users array from manual block" collect_blocked_users_array "$MANUAL_BLOCK_TAG" "blocked"
    run_and_check "collect blocked users array from traffic block" collect_blocked_users_array "$TRAFFIC_BLOCK_TAG" "traffic ban"
    run_and_check "collect blocked users array from time block" collect_blocked_users_array "$EXPIRED_BLOCK_TAG" "expired ban"
    run_and_check "collect online users array" collect_online_users_array
    run_and_check "collect oline devices array" collect_online_devices_array
    run_and_check "collect users traffic array" collect_users_traffic_array

    # formatting first string in table
    out+=$'[user]-[online/offline]-[devices]-[status]-[traffic]-[days_left]\n'

    # for every username add string in variables
    for username_w_d in "${!FULL_USERNAMES[@]}"; do
        
        # get full username from array
        full_username="${FULL_USERNAMES["$username_w_d"]}"

        # may be empty, if empty print offline
        online="${ONLINE_BY_USER["$full_username"]:-⚫ offline}"

        # devices always exist in array
        devices="${DEVICES_BY_USER["$full_username"]}"

        # may be empty, if empty print enabled
        status="${STATUS_BY_USER["$full_username"]:-enabled}"

        # cut username| and get traffic for username
        username="${full_username%%|*}"
        # may be empty, if empty print 0
        bytes="${TRAFFIC_BY_USER["$username"]:-0}"
        # double value
        bytes=$(( bytes * 2 ))
        # make human read
        traffic="$(fmt_bytes "$bytes")"

        # days olways exist in array
        days="${DAYS_LEFT_BY_USER["$username_w_d"]}"

        # set user string
        out+="[🧑🏿‍💻${username_w_d}]-[${online}]-[📱${devices}]-[🔏${status}]-[📊${traffic}]-[🗓${days}]"$'\n'
    done

    # print output
    printf '%s' "$out"
}

# main logic start here
case "$OPTION" in
    links)
        # just print database (without last empty string)
        sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$URI_DB"
        exit 0
    ;;

    all)
        run_and_check "print final table" print_all_table
        exit 0
    ;;

    *)
        helper_f
    ;;
esac