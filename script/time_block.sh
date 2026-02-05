#!/bin/bash
# script for time block xray expired user via cron every day 0:01 night time
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 1 0 * * * telegram-gateway /usr/local/bin/service/time_block.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly TIME_BLOCK_LOG="/var/log/service/time_block.$(date '+%Y-%m-%d').log"
exec &>> "$TIME_BLOCK_LOG" || { echo "❌ Error: cannot write to log '$TIME_BLOCK_LOG', exit"; exit 1; }

# start logging message
echo "########## time block started - $(date '+%Y-%m-%d %H:%M:%S') ##########"

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        echo "########## time block ended - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    else
        echo "########## time block failed - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly INBOUND_TAG="Vless"
readonly BLOCK_OUTBOUND_TAG="blocked"
readonly RULE_TAG="autoblock-expired-users"
readonly TODAY="$(date +%F)"
readonly TODAY_TS="$(date -d "$TODAY" +%s)"
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

# check another instanсe of the script is not running (with retries)
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
xray_lock_retry

# check xray conf
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

source "/usr/local/lib/service/telegram.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit"; exit 1; }

# helper func
run_and_check() {
    action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}


# parse old conf for exp email
parse_conf() {
    # get email from inbound with tag
    mapfile -t EMAILS < <(
        jq -r --arg tag "$INBOUND_TAG" '
            .inbounds[]? | select(.tag == $tag) |
            .settings.clients[]? | .email // empty
        ' "$XRAY_CONFIG"
    )

    expired_emails=()

    for email in "${EMAILS[@]}"; do
        # get exp date
        exp="$(sed -n 's/.*|exp=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' <<<"$email")"
        [[ -z "$exp" ]] && continue

        # get exp sec
        exp_ts="$(date -d "$exp" +%s 2>/dev/null || true)"
        [[ -z "$exp_ts" ]] && continue

        # block if exp < today
        if (( exp_ts < TODAY_TS )); then
            expired_emails+=("$email")
        fi
    done

    # users JSON array
    if (( ${#expired_emails[@]} == 0 )); then
        users_json='[]'
    else
        users_json="$(printf '%s\n' "${expired_emails[@]}" \
            | jq -R . \
            | jq -s 'unique')"
    fi
}
run_and_check "parse config for exp email" parse_conf

# make new config
new_conf() {
    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    chmod 600 "$TMP_XRAY_CONFIG" || return 1

    # set trap for tmp removing
    trap 'on_exit; rm -f "$TMP_XRAY_CONFIG";' EXIT

    jq \
        --arg inbound "$INBOUND_TAG" \
        --arg out "$BLOCK_OUTBOUND_TAG" \
        --arg ruleTag "$RULE_TAG" \
        --argjson users "$users_json" '
        .routing = (.routing // {}) |
        .routing.rules = (.routing.rules // []) |
        .routing.rules |= map(select(.ruleTag != $ruleTag)) |

        (if (.outbounds | type) != "array" then
            error("❌ Error: outbounds not found, cant add blackhole")
        else
            .
        end) |

    .outbounds |= (
        if any(.[]; .tag == $out) then .
        else . + [{"tag": $out, "protocol": "blackhole"}]
        end
    ) |

    (if ($users | length) > 0 then
        .routing.rules = ([{
        "type": "field",
        "ruleTag": $ruleTag,
        "inboundTag": [$inbound],
        "user": $users,
        "outboundTag": $out
        }] + .routing.rules)
    else
        .
    end)
' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}
run_and_check "make new config" new_conf

# if conf not change, exit
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    echo "✅ Success: expired email not found, exit (today=$TODAY, expired=${#expired_emails[@]})"
    RC=0
    exit 0
fi

# check new conf
run_and_check "xray new config checking" xray run -test -config "$TMP_XRAY_CONFIG"

# backup and install new config
run_and_check "backup old xray config" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

install_new_conf() {
    cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG"
}
run_and_check "install new xray config" install_new_conf

if (( ${#expired_emails[@]} == 0 )); then
    echo "✅ Success: expired users not found, cleanup old ruleTag '$RULE_TAG' (today=$TODAY)"
else
    echo "⚠️ Success: expired users found and blocked, today=$TODAY, expired=${#expired_emails[@]}"
fi
echo "✅ Success: Backup saved $XRAY_CONFIG_BACKUP"


# restart xray
if systemctl restart xray.service; then
    XRAY_STATUS="☑️ <b>Xray status:</b> running"
    XR_ST=0
    RC=0
    echo "✅ Success: restart xray"
else
    XRAY_STATUS="❌ <b>Xray status:</b> fail"
    XR_ST=1
    RC=1
    echo "❌ Error: restart xray"
fi

# start collecting message
if [[ $XR_ST == 0 ]]; then
    TITLE="⚠️<b> Scheduled time block</b>"
else
    TITLE="❌<b> Scheduled time block</b>"
fi

MESSAGE="$TITLE

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
$XRAY_STATUS"

if (( ${#expired_emails[@]} == 0 )); then
    MESSAGE+=$'\n'"⚠️ <b>Expired users:</b> not found"
    MESSAGE+=$'\n'"⚠️ <b>Action:</b> cleanup old time block rule"
else
    MESSAGE+=$'\n'"❌ <b>Expired users blocked:</b>"
    while IFS= read -r EMAIL; do
        [[ -z "$EMAIL" ]] && continue
        NAME="${EMAIL%%|*}"
        MESSAGE+=$'\n'"❌ $NAME"
    done < <(printf '%s\n' "${expired_emails[@]}")
fi

MESSAGE+=$'\n'"💾 <b>Time block log:</b> $TIME_BLOCK_LOG"

# logging message
echo "########## collected message - $(date '+%Y-%m-%d %H:%M:%S') ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC