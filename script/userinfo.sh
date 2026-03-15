#!/bin/bash
# script for show user info from xray config and URI_DB

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

# main variables
readonly USERNAME="$1"

# argument check
if [[ $# -ne 1 || $USERNAME == "--help" ]]; then
    echo "Use for show individual user info"
    echo "run: $0 username"
    exit 0
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"
run_lock_check "uri_db" "console"
run_lock_check "tr_db" "console"

# permission check
read_check "$URI_DB" "console"
read_check "$XRAY_CONFIG" "console"
read_check "$TR_DB_M" "console"
read_check "$TR_DB_Y" "console"

# xray running check
xray_status_check "console"

# function section
# function for extract field value from FULL_EMAIL like "...|created=2026-01-15|days=10|exp=2026-01-25"
extract_field() {
    local key="$1" s="$2"
    # Prints value or empty
    sed -n "s/.*|${key}=\\([^|]*\\).*/\\1/p" <<<"$s" | head -n1
}

# function for extract link from URI_DB
get_links() {
    local username="$1"
    local field_name="$2"

    awk -v user="$username" -v field="$field_name" '
        {
            pattern = "^name:[[:space:]]*([^,]+),[[:space:]]*" field ":[[:space:]]*(.+)$"
            if (match($0, pattern, m) && m[1] == user) {
                print m[2]
                exit
            }
        }
    ' "$URI_DB"
}

# main logic start here
# Find full email string for the user in the specified inbound tag
# print 1 match and exit
FULL_EMAIL="$(
    jq -r --arg itag "$INBOUND_TAG" --arg u "$USERNAME" '
        (.inbounds // [])
        | map(select(.tag == $itag))
        | .[0].settings.clients // []
        | map(select((.email // "" | split("|")[0]) == $u))
        | .[0].email // ""
    ' "$XRAY_CONFIG"
)"

# If user not found in inbound -> exit
if [[ -z "$FULL_EMAIL" ]]; then
    echo "❌ Error: username not found, exit"
    exit 1
fi

# extract field from $FULL_EMAIL
CREATED="$(extract_field "created" "$FULL_EMAIL")"
DAYS_BOUGHT="$(extract_field "days" "$FULL_EMAIL")"
EXP="$(extract_field "exp" "$FULL_EMAIL")"

# Normalize missing/non-usable values -> unknown
# created/exp: must look like YYYY-MM-DD, exp/days - never/infinity
if [[ ! "$CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    CREATED="unknown"
fi

if ! [[ "$EXP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$EXP" == "never" ]]; then
    EXP="unknown"
fi

# days: must be integer
if ! [[ "$DAYS_BOUGHT" =~ ^-?[0-9]+$  || "$DAYS_BOUGHT" == "infinity" ]]; then
    DAYS_BOUGHT="unknown"
fi

# Compute DAYS_LEFT (can be negative). If EXP=0 -> 0
DAYS_LEFT="0"
if [[ "$EXP" == "never" ]]; then
    DAYS_LEFT="infinity"
elif [[ $EXP =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    exp_epoch="$(date -d "$EXP" +%s 2>/dev/null)"
    today_epoch="$(date -d "today 00:00" +%s 2>/dev/null)"
    DAYS_LEFT="$(( (exp_epoch - today_epoch) / 86400 ))"
else
    DAYS_LEFT="unknown"
fi

# get ban or enable status
STATUS="$(
    jq -r \
        --arg u "$FULL_EMAIL" \
        --arg mb "$MANUAL_BLOCK_TAG" \
        --arg ae "$EXPIRED_BLOCK_TAG" \
        --arg at "$TRAFFIC_BLOCK_TAG" '
            def has($tag):
                any(.routing.rules[]?;
                (.ruleTag? == $tag) and any(.user[]?; . == $u)
                );

            if has($mb) then "blocked manually"
            elif has($at) then "traffic ban"
            elif has($ae) then "expired ban"
            else "enable"
            end
    ' "$XRAY_CONFIG"
)"

# get all online user list in json
# call "xray api statsgetallonlineusers" make reset online device to offline if he real offline
XRAY_API_JSON="$(xray api statsgetallonlineusers)"

# if not empty, (xray offline), or if not {} (no online users) try get user status and device count
if ! [[ -z "$XRAY_API_JSON" || "$XRAY_API_JSON" == "{}" ]]; then
    # collect full username massive from json
    mapfile -t USERS_ONLINE_EMAIL_FULL < <(
        jq -r '.users // []
            | .[]
            | sub("^user>>>";"")
            | sub(">>>online$";"")
            ' <<<"$XRAY_API_JSON" 2>/dev/null | awk 'NF'
    )

    # search username in online list if and if have in list make status online
    for email in "${USERS_ONLINE_EMAIL_FULL[@]}"; do
        if [[ "$email" == "$FULL_EMAIL" ]]; then
            USER_ONLINE_STATUS="online"
            break
        fi
    done

    # get device number if error reset to 0
    json="$(xray api statsonline --email "$FULL_EMAIL" 2>/dev/null)"
    USER_DEVICE_COUNT="$(jq -r '.stat.value // 0' <<<"$json")"
fi

# in any case check device count end if not valid reset to 0
[[ ! $USER_DEVICE_COUNT =~ ^-?[0-9]+$ ]] && USER_DEVICE_COUNT=0

# check online status and if empty or not online set offline
[[ $USER_ONLINE_STATUS != "online" ]] && USER_ONLINE_STATUS="offline"

# get user ip if he online
if [[ $USER_ONLINE_STATUS == "online" ]]; then
    json="$(xray api statsonlineiplist --email "$FULL_EMAIL" 2>/dev/null)"
    if [[ -n "$json" ]]; then
        IP_USER="$(jq -r '(.ips // {}) | keys | join(" ")' <<<"$json")"
    fi
fi

# get userstat from TR_DB_M for all username|
TOTAL_M="$(
    jq -r --arg u "$USERNAME" '
        [ .stat[]?
            | select(.name? and (.name | startswith("user>>>")))
            | select((.name | split(">>>")[1] | split("|")[0]) == $u)
            | (.value // 0)
        ]
        | (add // 0)
        | . * 2
     ' "$TR_DB_M" 2>/dev/null
)"

# if JSON empty or null - reset, else - byte to human read
if [[ -z "$TOTAL_M" || "$TOTAL_M" == "null" ]]; then
    TOTAL_M=0
else
    TOTAL_M="$(numfmt --to=iec --suffix=B "$TOTAL_M")"
fi

# get userstat from TR_DB_Y for all username|
TOTAL_Y="$(
  jq -r --arg u "$USERNAME" '
    [ .stat[]?
      | select(.name? and (.name | startswith("user>>>")))
      | select((.name | split(">>>")[1] | split("|")[0]) == $u)
      | (.value // 0)
    ]
    | (add // 0)
    | . * 2
  ' "$TR_DB_Y" 2>/dev/null
)"

# if JSON empty or null - reset, else - byte to human read
if [[ -z "$TOTAL_Y" || "$TOTAL_Y" == "null" ]]; then
    TOTAL_Y=0
else
    TOTAL_Y="$(numfmt --to=iec --suffix=B "$TOTAL_Y")"
fi

# search for
# name: <username>, vless ip_* link: <link>
# print "<link>", all matches
USER_VLESS_LINK_4="$(get_links "$USERNAME" "vless ip_4 link")"
USER_VLESS_LINK_6="$(get_links "$USERNAME" "vless ip_6 link")"
USER_VLESS_LINK_DOMAIN="$(get_links "$USERNAME" "vless domain link")"

[[ -z $IP_USER ]] && IP_USER="[not available]"
[[ -z $USER_VLESS_LINK_4 ]] && USER_VLESS_LINK_4="[not available]"
[[ -z $USER_VLESS_LINK_6 ]] && USER_VLESS_LINK_6="[not available]"

# convert limit bytes to human read traffic limit
MAX_TR_H="$(numfmt --to=iec --suffix=B "$MAX_TR")"

echo "🧑🏿‍💻 Name: $USERNAME"
echo "📅 Created: $CREATED"
echo "🗓 Bought days: $DAYS_BOUGHT"
echo "🗓 Days left: $DAYS_LEFT"
echo "📅 Expiration: $EXP"
echo "🌐 Status: $USER_ONLINE_STATUS"
echo "🔏 Active: $STATUS"
echo "📱 Devices: $USER_DEVICE_COUNT"
echo "📊 Traffic monthly: $TOTAL_M/$MAX_TR_H"
echo "📊 Traffic annual: $TOTAL_Y"
echo "📝 IP: $IP_USER"
echo "🛠 Vless domain link: $USER_VLESS_LINK_DOMAIN"
echo "🛠 Vless ip_4 link: $USER_VLESS_LINK_4"
echo "🛠 Vless ip_6 link: $USER_VLESS_LINK_6"

exit 0
