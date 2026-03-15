#!/bin/bash
# script for notify xray traffic and user exp date via systemd timer every day 0:02 night time
# all errors are logged in journald, see journalctl -t user_notify
# exit codes work to tell systemd about success sending message

# enable logging
exec > >(systemd-cat -t user_notify -p info) 2> >(systemd-cat -t user_notify -p err) 5> >(systemd-cat -t user_notify -p notice)

# start logging message
echo "user notify started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "user notify ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "user notify failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "Error: you are not the '$TARGET_USER' user, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "user_notify"

# lock check
run_lock_wait "xray" "600"
run_lock_wait "tr_db" "600"

# permission check
read_check "$XRAY_CONFIG"
read_and_write_check "$TR_DB_M"
read_and_write_check "$TR_DB_Y"

# xray running check
xray_status_check

# function section
# function for parse json to name:name:number
stat_lines() {
    local json="$1"
    jq -r '
        .stat[]
        | (.name | split(">>>")) as $p
        | "\($p[0]):\($p[1]):\(.value // 0)"
    ' <<<"$json"
}

# function for calculate total server traffic (inbound+outbound)
sum_server() {
    local lines="$1"
    awk -F: '
        $1=="inbound" || $1=="outbound" { s += ($3+0) }
        END { print s+0 }
    ' <<<"$lines"
}

# function for calculate total traffic each user and cut | info
sum_users() {
    local lines="$1"
    awk -F: '
        $1=="user" {
            split($2, a, "|")
            u[a[1]] += ($3+0)
        }
        END { for (k in u) printf "%s %d\n", k, u[k] }
     ' <<<"$lines" | LC_ALL=C sort
}

# function for statistic reset in json file
# shellcheck disable=SC2329
reset_stat_file() { printf '{"stat":[]}\n' > "$1"; }

# formatting bytes function
byte_to_human(){ numfmt --to=iec --suffix=B "$1"; }

# main logic start here
# get traffic data from json and parse
DATA="$(stat_lines "$(cat "$TR_DB_M")")"

# get server traffic
SERVER_TOTAL="$(sum_server "$DATA")"

# get user traffic with format - user date
USERS_TOTAL="$(sum_users "$DATA")"

# set reset flag traffic if 1 day of month
RESET_ARG_M="0"
[[ "$(date +%d)" = "01" ]] && RESET_ARG_M="1"

# set reset flag traffic if 1 day of year
RESET_ARG_Y="0"
[[ "$(date +%j)" = "001" ]] && RESET_ARG_Y="1"

# reset traffic 1 day of month
[[ $RESET_ARG_M == "1" ]] && reset_stat_file "$TR_DB_M"

# reset traffic 1 day of year
[[ $RESET_ARG_Y == "1" ]] && reset_stat_file "$TR_DB_Y"

# parse config for full users email
USERS_EMAILS_FULL="$(jq -r --arg tag "$INBOUND_TAG" '.inbounds[]? | select(.tag? == $tag) | .settings? | .clients[]? | .email? // empty' "$XRAY_CONFIG")"

# parse and print email - exp days
USERS_WITH_DAYS=""
while IFS= read -r email; do
    [[ -z "$email" ]] && continue

    username="${email%%|*}"

    exp_date="$(printf '%s' "$email" | sed -nE 's/.*\|exp=([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
    [[ -z "$exp_date" ]] && continue

    exp_epoch="$(date -d "$exp_date" +%s)"
    days_left=$(( (exp_epoch - TODAY_EPOCH) / 86400 ))

    USERS_WITH_DAYS+="$(printf '%s %s' "$username" "$days_left")"$'\n'
done <<< "$USERS_EMAILS_FULL"

# start collecting message
MESSAGE="📢 <b>Daily user report</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
🔛 <b>Traffic:</b>
🔛 <b>Host traffic:</b> $(byte_to_human "$SERVER_TOTAL")"

# collecting traffic section
while IFS=$' ' read -r EMAIL TRAFF; do
    [[ -z "$EMAIL" ]] && continue
    TRAFFx2=$(( TRAFF * 2 ))
    MESSAGE+=$'\n'"🔛 <b>User traffic:</b> $EMAIL - $(byte_to_human "$TRAFFx2")"
done <<< "$USERS_TOTAL"

# collecting time section
MESSAGE+=$'\n'"🔚 <b>Time:</b>"
while IFS=$' ' read -r EMAIL DAYS; do
    [[ -z "$EMAIL" ]] && continue
    if [[ $DAYS -lt 0 ]]; then
        MESSAGE+=$'\n'"❌ <b>User time:</b> $EMAIL - $DAYS days left"
    elif [[ $DAYS -le 10 ]]; then
        MESSAGE+=$'\n'"⚠️ <b>User time:</b> $EMAIL - $DAYS days left"
    else
        MESSAGE+=$'\n'"🔚 <b>User time:</b> $EMAIL - $DAYS days left"
    fi
done <<< "$USERS_WITH_DAYS"

# collecting log section
MESSAGE+=$'\n'"💾 <b>Xray error log:</b> /var/log/xray/error.log
💾 <b>Xray access log:</b> /var/log/xray/access.log
💾 <b>Notify log:</b> journalctl -t user_notify"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# send message
telegram_message "$MESSAGE"

# exit with message delivery status
exit $RC_M
