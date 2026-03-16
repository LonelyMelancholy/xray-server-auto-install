#!/bin/bash
# script for block/unblock manually xray user

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
readonly ACTION="$2"

# argument check
if [[ ! "$#" -eq 2 || "$USERNAME" == "--help" ]]; then
    echo "Used to block user in xray config"
    echo "run: $0 username block|unblock"
    exit 1
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    echo "❌ Error: only letters, numbers and '-' or '_' in username, length 1-64 characters, exit"
    exit 1
fi

if [[ "$USERNAME" =~ ^[-_]|[-_]$ ]]; then
    echo "❌ Error: username must not start or end with '-' or '_', exit"
    exit 1
fi

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp() {
    if rm -f "$TMP_XRAY_CONFIG" 2> /dev/null; then
        echo "✅ Success: delete tmp files"
    else
        echo "❌ Error: delete tmp files"
    fi
}

# set trap for tmp removing and exit message
trap 'rm_tmp' EXIT

# make tmp file
TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || { echo "❌ Error: create temp file failed, exit"; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check "xray" "console"

# read and write conf check
read_and_write_check "$XRAY_CONFIG" "console"

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

# for block: find client emails in inbound Vless, match USERNAME|*
get_client_emails() {
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
        .inbounds[]? | select(.tag == $tag)
        | .settings.clients[]?
        | select(((.email // "") | split("|")[0]) == $name)
        | .email // empty
    ' "$XRAY_CONFIG"
}

# for unblock: find all client only from OUR tagged managed rule, match USERNAME|*
get_blocked_emails_from_rule() {
    jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" --arg bot "$BLOCK_OUTBOUND_TAG" --arg brt "$MANUAL_BLOCK_TAG" '
        def is_managed_rule:
            (.type == "field")
            and (.outboundTag == $bot)
            and ((.inboundTag // []) | index($tag))
            and ((.ruleTag // "") == $brt)
            and has("user")
            and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

            (.routing.rules[]? | select(is_managed_rule) | .user[]?)
            | select((split("|")[0]) == $name) | select(length>0)
    ' "$XRAY_CONFIG"
}

# function for add|del user
# shellcheck disable=SC2329
jq_apply_users() {
  local op="$1" # add | del

  jq --arg tag "$INBOUND_TAG" \
     --arg bot "$BLOCK_OUTBOUND_TAG" \
     --arg rt "$MANUAL_BLOCK_TAG" \
     --arg op "$op" \
     --argjson emails "$EMAILS_JSON" \
     "$jq_manage_users" "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
}

# function for install config with save permission
# shellcheck disable=SC2329
install_new_conf() { cat "$TMP_XRAY_CONFIG" > "$XRAY_CONFIG" || return 1; }

# variable for ensure:
# outbounds contains {"tag":"blocked","protocol":"blackhole"}
# routing.rules exists
# our managed rule exists at top {"type":"field","ruleTag":"manual-block-users","inboundTag":["Vless"],"outboundTag":"blocked","user":[]}
# if not exist create new rule
# shellcheck disable=SC2016
jq_common_preamble='
  .outbounds = (.outbounds // []) |
  if any(.outbounds[]?; .tag == $bot) then .
  else .outbounds += [{"tag": $bot, "protocol": "blackhole"}]
  end |
  .routing = (.routing // {}) |
  .routing.rules = (.routing.rules // []) |

  def is_managed_rule:
    (.type == "field")
    and (.outboundTag == $bot)
    and ((.inboundTag // []) | index($tag))
    and ((.ruleTag // "") == $rt)
    and has("user")
    and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

  if any(.routing.rules[]?; is_managed_rule) then .
  else .routing.rules |= ([{"type":"field","ruleTag":$rt,"inboundTag":[$tag],"outboundTag":$bot,"user":[]} ] + .)
  end
'

# variable for del|add user in jq
# shellcheck disable=SC2016
jq_manage_users='
  '"$jq_common_preamble"' |

  def apply_user_delta($emails; $op):
    .routing.rules |= map(
      if is_managed_rule then
        .user = (
          if $op == "add" then
            (((.user // []) + $emails) | unique)
          elif $op == "del" then
            ((.user // []) - $emails)
          else
            (.user // [])
          end
        )
      else .
      end
    )
    | if $op == "del" then
        del(.routing.rules[] | select(is_managed_rule and ((.user // []) | length == 0)))
      else .
      end;

  apply_user_delta($emails; $op)
'

# start block/unblock
case "$ACTION" in
    block)
        # check client only in our tagged rule
        mapfile -t EMAILS < <(get_blocked_emails_from_rule)
        if [[ ${#EMAILS[@]} -gt 0 ]]; then
            echo "❌ Error: client for block name '$USERNAME' already blocked in ruleTag '$MANUAL_BLOCK_TAG'"
            exit 1
        fi

        # check client exist or not
        mapfile -t EMAILS < <(get_client_emails)
        if [[ ${#EMAILS[@]} -gt 1 ]]; then
            echo "❌ Error: '$USERNAME' too many matches in clients inbound '$INBOUND_TAG', edit config manually, exit"
            exit 1
        elif [[ ${#EMAILS[@]} -eq 1 ]]; then
            echo "✅ Success: found client with name '$USERNAME' in inbound tag '$INBOUND_TAG'"
        else
            echo "❌ Error: not found client with name '$USERNAME' in inbound tag '$INBOUND_TAG', exit"
            exit 1
        fi

        # convert email to json
        EMAILS_JSON="$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)"

        # run func for add user in block rule
        run_and_check "block user '$USERNAME', ruleTag '$MANUAL_BLOCK_TAG'" jq_apply_users add
    ;;

    unblock)
        # check client exist or not
        mapfile -t EMAILS < <(get_client_emails)
        if [[ ${#EMAILS[@]} -gt 1 ]]; then
            echo "❌ Error: '$USERNAME' too many matches in clients inbound '$INBOUND_TAG', edit config manually, exit"
            exit 1
        elif [[ ${#EMAILS[@]} -eq 1 ]]; then
            echo "✅ Success: found client with name '$USERNAME' in inbound tag '$INBOUND_TAG'"
        else
            echo "❌ Error: not found client with name '$USERNAME' in inbound tag '$INBOUND_TAG', exit"
            exit 1
        fi

        # check client only in our tagged rule
        mapfile -t EMAILS < <(get_blocked_emails_from_rule)
        if [[ ${#EMAILS[@]} -gt 1 ]]; then
            echo "❌ Error: '$USERNAME' too many matches in ruleTag '$MANUAL_BLOCK_TAG', edit config manually, exit"
            exit 1
        elif [[ ${#EMAILS[@]} -eq 1 ]]; then
            echo "✅ Success: found client for unblock name '$USERNAME' in ruleTag '$MANUAL_BLOCK_TAG'"
        else
            echo "❌ Error: not found client for unblock name '$USERNAME' in ruleTag '$MANUAL_BLOCK_TAG', exit"
            exit 1
        fi

        # convert email to json
        EMAILS_JSON="$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)"
        
        # run func for del user from block rule
        run_and_check "unblock user '$USERNAME', ruleTag '$MANUAL_BLOCK_TAG'" jq_apply_users del
    ;;

    *)
        echo "❌ Error: wrong argument, read help again, exit"
        exit 1
    ;;
esac

# checking new config
run_and_check "checking new tmp xray config" xray run -test -config "$TMP_XRAY_CONFIG"

# backup
run_and_check "backup old xray config to '$XRAY_CONFIG_BACKUP'" cp -a "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"

# install new file with save permission
run_and_check "install new xray config" install_new_conf

# restart xray
run_and_check "restart xray service" systemctl restart xray.service

echo "✅ Success: xray config updated for '$USERNAME'"

exit 0
