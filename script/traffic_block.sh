#!/usr/bin/env bash
# script for autoblock user who download traffic limit via systemd timer every 10m
# all errors are logged in journald, see journalctl -t traffic_block
# exit codes work to tell systemd about success

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# main variables
readonly LOCK_FILE="/run/lock/traffic_block.lock"
# make tmp config
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
declare -A TOTAL_BYTES_BY_USERS
declare -a FULL_EMAILS=()
declare -a FULL_EMAILS_TO_BLOCK=()
declare -a USERNAME_TO_BLOCK=()
RC=1

# enable logging
exec > >(systemd-cat -t traffic_block -p info) 2> >(systemd-cat -t traffic_block -p err) 5> >(systemd-cat -t traffic_block -p notice)

# start logging message
echo "traffic block started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "traffic block ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "traffic block failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    echo "cleaning start - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -f "$TMP_XRAY_CONFIG" > /dev/null; then
        echo "Success: delete tmp files"
        echo "cleaning ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "Error: delete tmp files" >&2
        echo "cleaning failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# set trap for tmp removing and exit message
trap 'end_log; rm_tmp;' EXIT

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
exec {fd}< "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
run_lock_retry_check "xray"
run_lock_retry_check "tr_db"

# read and write conf check
read_and_write_check "$XRAY_CONFIG"
read_check "$TR_DB_M"

# xray running check
xray_status_check

# source Telegram function library
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# helper function
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "Success: $action"
    else
        echo "Error: $action, exit" >&2
        exit 1
    fi
}

# function for find email still in config or not and print all matches
find_full_email_in_config() {
    local username="$1"
    local found
    # find all match username|*
    found="$(jq -r --arg inb "$INBOUND_TAG" --arg username "$username" '
        .inbounds[]?
        | select(.tag? == $inb)
        | .settings.clients[]?
        | select(.email? and (.email | startswith($username + "|")))
        | .email
    ' "$XRAY_CONFIG")"

    # if we found clients, print
    [[ -n "$found" ]] && printf '%s\n' "$found"
}

# function for make new tmp config
# shellcheck disable=SC2329
make_new_tmp_config() {
    jq \
    --arg inbound "$INBOUND_TAG" \
    --arg out "blocked" \
    --arg ruleTag "$TRAFFIC_BLOCK_TAG" \
    --argjson users "$TRAFFIC_END_USERS_JSON" '
        .routing = (.routing // {})
        | .routing.domainStrategy = (.routing.domainStrategy // "IPOnDemand")
        | .routing.rules = (.routing.rules // [])

        # outbounds обязаны быть массивом
        | (if (.outbounds | type) != "array" then
                error("Error: outbounds not found, cant add blackhole")
            else
                .
            end)

        # гарантируем наличие blackhole-outbound с tag == $out
        | .outbounds |= (
            if any(.[]; .tag == $out) then .
            else . + [{"tag": $out, "protocol": "blackhole"}]
            end
            )

        # индекс первого правила с ruleTag (чтобы сохранить позицию "на месте")
        | (.routing.rules | map(.ruleTag? == $ruleTag) | index(true)) as $idx

        # удалить все правила с этим ruleTag (чтобы не было дублей)
        | .routing.rules |= map(select(.ruleTag? != $ruleTag))

        # если users пуст — правило не возвращаем (оно будет удалено)
            | if ($users | length) > 0 then
                .routing.rules |= (
                    if $idx == null then
                        # правила не было — добавляем в конец
                        . + [{
                            "type": "field",
                            "ruleTag": $ruleTag,
                            "inboundTag": [$inbound],
                            "user": $users,
                            "outboundTag": $out
                        }]
                    else
                        # правило было — вставляем на место первого найденного
                        .[0:$idx] + [{
                            "type": "field",
                            "ruleTag": $ruleTag,
                            "inboundTag": [$inbound],
                            "user": $users,
                            "outboundTag": $out
                        }] + .[$idx:]
                    end
                )
            else
                .
            end
    ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}

# function for install new conf with save original permission
# shellcheck disable=SC2329
install_new_conf() {
    cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG" || return 1
}

# main logic start here
# collect data from tr_db
# user>>>........>>>traffic>>>downlink	value
USERS_TRAFFIC_TOTAL=$(jq -r '
    .stat[]
    | select(.name? and (.name | startswith("user>>>")))
    | select(.value? != null)
    | select(.name | test(">>>traffic>>>(up|down)link$"))
    | [.name, (.value|tostring)]
    | @tsv
' "$TR_DB_M")

# get named array [username|] - [in+out traffic]
while IFS=$'\t' read -r name value; do
    # cut user>>>
    user_full="${name#user>>>}"
    # cut >>>traffic*
    user_full="${user_full%%>>>traffic*}"
    # get username|
    username="${user_full%%|*}"

    # skip empty strings
    [[ -z "$username" ]] && continue
    
    # add value to array, if array value empty set to 0 and add value
    TOTAL_BYTES_BY_USERS["$username"]=$(( ${TOTAL_BYTES_BY_USERS["$username"]:-0} + value ))
done <<< "$USERS_TRAFFIC_TOTAL"

# check traffic in array, if empty value - exit
if (( ${#TOTAL_BYTES_BY_USERS[@]} == 0 )); then
    echo "Success: in $TR_DB_M not found user>>>...>>>traffic>>>uplink/downlink with value, exit"
    RC=0
    exit $RC
fi

# per user, check traffic limit, ifexceeded add to array to block
for username in "${!TOTAL_BYTES_BY_USERS[@]}"; do
    # get traffic and * 2 for username|
    sum=$(( TOTAL_BYTES_BY_USERS["$username"] ))
    used=$(( sum * 2 ))

    # if used to much traffic then block part, if not - continue to next user
    if [[ $used -ge $MAX_TR ]]; then
        echo "Success: $username exceeded the limit, try to find full email"
        
        # get all email who match to username|
        mapfile -t FULL_EMAILS < <(find_full_email_in_config "$username")

        # if not found actual full email, user already deleted, countinue to next user
        if [[ ${#FULL_EMAILS[@]} -eq 0 ]]; then
            echo "Error: username '$username' exceeded the limit, but the current Vless client email was not found in the config, continue"
            continue
        fi

        # add all email from full emails array to array to block
        for full_email in "${FULL_EMAILS[@]}"; do
            FULL_EMAILS_TO_BLOCK+=("$full_email")
        done
        
        # add username to report array
        USERNAME_TO_BLOCK+=("$username")
        echo "Success: username '$username', found full email and prepared to block"
    fi
done

# make users json array full emails for block if have email in array
if [[ ${#FULL_EMAILS_TO_BLOCK[@]} == 0 ]]; then
    TRAFFIC_END_USERS_JSON='[]'
else
    TRAFFIC_END_USERS_JSON="$(printf '%s\n' "${FULL_EMAILS_TO_BLOCK[@]}" | jq -R . | jq -s .)"
fi

# make new tmp config
run_and_check "make new xray tmp config" make_new_tmp_config

# if conf not change, exit
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    echo "Success: users exceeded the limit not found, exit"
    RC=0
    exit $RC
fi

# check new conf
run_and_check "checking new xray tmp config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup config
run_and_check "backup old xray config $XRAY_CONFIG_BACKUP" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install new config (original permission saved)
run_and_check "install new xray config" install_new_conf

# if not found exceeded the limit email but we have blocked email, config changed make_new_tmp_config func, blocked email deleted
# if email empty, rule $TRAFFIC_BLOCK_TAG deleted
if (( ${#FULL_EMAILS_TO_BLOCK[@]} == 0 )); then
    echo "Success: exceeded the limit not found, cleanup old ruleTag '$TRAFFIC_BLOCK_TAG'"
else
    echo "Success: exceeded the limit found and blocked, ruleTag '$TRAFFIC_BLOCK_TAG', exceeded the limit=${#FULL_EMAILS_TO_BLOCK[@]}"
fi

# restart xray and make xray status message
if systemctl restart xray.service; then
    XRAY_STATUS="☑️ <b>Xray status:</b> running"
    XR_ST=0
    RC=0
    echo "Success: restart xray"
else
    XRAY_STATUS="❌ <b>Xray status:</b> fail"
    XR_ST=1
    RC=1
    echo "Error: restart xray" >&2
fi

# start collecting message
# make title
if [[ $XR_ST == 0 ]]; then
    TITLE="⚠️<b> Scheduled traffic block</b>"
else
    TITLE="❌<b> Scheduled traffic block</b>"
fi

# make upper message body
MESSAGE="$TITLE

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
$XRAY_STATUS"

# make exp email section
if (( ${#USERNAME_TO_BLOCK[@]} == 0 )); then
    MESSAGE+=$'\n'"⚠️ <b>Exceeded the limit users:</b> not found"
    MESSAGE+=$'\n'"⚠️ <b>Action:</b> cleanup old traffic block rule"
else
    MESSAGE+=$'\n'"❌ <b>Exceeded the limit users blocked:</b>"
    while IFS= read -r username; do
        [[ -z "$username" ]] && continue
        MESSAGE+=$'\n'"❌ $username"
    done < <(printf '%s\n' "${USERNAME_TO_BLOCK[@]}")
fi

# add log section
MESSAGE+=$'\n'"💾 <b>Time block log:</b> journalctl -t traffic_block"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message

exit $RC
