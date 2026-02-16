#!/bin/bash
# script for time block xray expired user via cron every day 0:01 night time
# all errors are logged in journald, see journalctl -t time_block
# 1 0 * * * telegram_gateway /usr/local/bin/service/time_block.sh
# exit codes work to tell Cron about success

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# main variables
readonly BLOCK_RULE_TAG="autoblock-expired-users"
readonly TODAY=$(date '+%F')
readonly TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
RC="1"
LOCK_FILE="/run/lock/time_block.lock"

# enable logging
exec > >(systemd-cat -t time_block -p info) 2> >(systemd-cat -t time_block -p err) 5> >(systemd-cat -t time_block -p notice)

# start logging message
echo "time block started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "time block ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "time block failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp_config() {
    echo "cleaning start - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -f "$TMP_XRAY_CONFIG" > /dev/null; then
        echo "Success: delete tmp config file"
        echo "cleaning ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "Error: delete tmp config file" >&2
        echo "cleaning failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# set trap for tmp removing and exit message
trap 'end_log; rm_tmp_config;' EXIT

# helper func
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

# function for parse old conf for exp email
# shellcheck disable=SC2329
parse_old_conf() {
    # get full email from inbound with tag == $INBOUND_TAG
    mapfile -t USERS_EMAILS_FULL < <(
        jq -r --arg tag "$INBOUND_TAG" '
            .inbounds[]? | select(.tag == $tag) |
            .settings.clients[]? | .email // empty
        ' "$XRAY_CONFIG"
    )

    # array for expired emails
    EXPIRED_EMAILS_FULL=()

    # cycle for get expired emails
    for email in "${USERS_EMAILS_FULL[@]}"; do
        # get exp date
        exp="$(sed -n 's/.*|exp=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' <<<"$email")"
        [[ -z "$exp" ]] && continue

        # get exp sec
        exp_ts="$(date -d "$exp" +%s 2>/dev/null)"
        [[ -z "$exp_ts" ]] && continue

        # block if exp < today (block users on next day if date matches)
        if [[ $exp_ts -lt $(date -d "today 00:00" '+%s') ]]; then
            EXPIRED_EMAILS_FULL+=("$email")
        fi
    done

    # make users json array if have expireed email
    if [[ ${#EXPIRED_EMAILS_FULL[@]} == 0 ]]; then
        EXPIRED_USERS_JSON='[]'
    else
        EXPIRED_USERS_JSON="$(printf '%s\n' "${EXPIRED_EMAILS_FULL[@]}" \
            | jq -R . \
            | jq -s .)"
    fi
}

# function for make new tmp config
# shellcheck disable=SC2329
make_new_tmp_config() {
    jq \
    --arg inbound "$INBOUND_TAG" \
    --arg out "blocked" \
    --arg ruleTag "$BLOCK_RULE_TAG" \
    --argjson users "$EXPIRED_USERS_JSON" '
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

# check another instanсe of the script is not running
exec 99> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n 99 || { echo "Error: another instance is running, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
run_lock_retry_check "xray"

# read and write conf check
read_and_write_check "$XRAY_CONFIG"

# main logic start here
# parse old conf for exp email
run_and_check "parse old xray config for expired email" parse_old_conf

# make new tmp config
run_and_check "make new xray tmp config" make_new_tmp_config

# if conf not change, exit
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    echo "Success: expired email not found, exit (today=$TODAY, expired=${#EXPIRED_EMAILS_FULL[@]})"
    RC=0
    exit 0
fi

# check new conf
run_and_check "checking new xray tmp config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup and install new config
run_and_check "backup old xray config $XRAY_CONFIG_BACKUP" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install new config (original permission saved)
run_and_check "install new xray config" install_new_conf

# if not found exp email but we have blocked email, config changed make_new_tmp_config func, blocked email deleted
# if email empty, rule $BLOCK_RULE_TAG deleted
if (( ${#EXPIRED_EMAILS_FULL[@]} == 0 )); then
    echo "Success: expired users not found, cleanup old ruleTag '$BLOCK_RULE_TAG' today=$TODAY, expired=${#EXPIRED_EMAILS_FULL[@]}"
else
    echo "Success: expired users found and blocked, ruleTag '$BLOCK_RULE_TAG', today=$TODAY, expired=${#EXPIRED_EMAILS_FULL[@]}"
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
    TITLE="⚠️<b> Scheduled time block</b>"
else
    TITLE="❌<b> Scheduled time block</b>"
fi

# make upper message body
MESSAGE="$TITLE

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
$XRAY_STATUS"

# make exp email section
if (( ${#EXPIRED_EMAILS_FULL[@]} == 0 )); then
    MESSAGE+=$'\n'"⚠️ <b>Expired users:</b> not found"
    MESSAGE+=$'\n'"⚠️ <b>Action:</b> cleanup old time block rule"
else
    MESSAGE+=$'\n'"❌ <b>Expired users blocked:</b>"
    while IFS= read -r EMAIL; do
        [[ -z "$EMAIL" ]] && continue
        NAME="${EMAIL%%|*}"
        MESSAGE+=$'\n'"❌ $NAME"
    done < <(printf '%s\n' "${EXPIRED_EMAILS_FULL[@]}")
fi

# add log section
MESSAGE+=$'\n'"💾 <b>Time block log:</b> journalctl -t time_block"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message

exit $RC