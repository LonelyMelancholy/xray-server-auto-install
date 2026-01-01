#!/bin/bash
# script for block/unblock manualy xray user

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/userblock.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly BACKUP_PATH="${XRAY_CONFIG}.$(date +%Y%m%d_%H%M%S).bak"
readonly INBOUND_TAG="Vless"
readonly USERNAME="$1"
readonly BLOCK_OUTBOUND_TAG="blocked"
readonly RULE_TAG="manual-block-users"
readonly ACTION="$2"

# argument check
if ! [[ "$#" -eq 2 ]]; then
    echo "Use for block user in xray config, run: $0 <username> <block|unblock>"
    exit 1
fi

if ! [[ $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

# config check
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# helper func
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

# for block: find client emails in inbound Vless that match USERNAME or USERNAME|
get_client_emails() {
  jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
    .inbounds[]?
    | select(.tag == $tag)
    | .settings.clients[]?
    | .email
    | select(. == $name or startswith($name + "|"))
  ' "$XRAY_CONFIG" | awk 'NF' | sort -u
}

# for unblock: only from OUR tagged managed rule
get_blocked_emails_from_rule() {
  jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" '
    def is_managed_rule:
      (.type == "field")
      and (.outboundTag == $bot)
      and ((.inboundTag // []) | index($tag))
      and ((.ruleTag // "") == $rt)
      and has("user")
      and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

    (.routing.rules[]? | select(is_managed_rule) | .user[]?)
    | select(. == $name or startswith($name + "|"))
  ' "$XRAY_CONFIG" | awk 'NF' | sort -u
}

# variable for ensure:
# - outbounds contains {"tag":"blocked","protocol":"blackhole"}
# - routing.rules exists
# - our managed rule exists at top {"type":"field","ruleTag":"manual-block-users","inboundTag":["Vless"],"outboundTag":"blocked","user":[]}
# if not exist create new rule
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

# start block/unblock
case "$ACTION" in
    block)
        # check client exist or not
        mapfile -t EMAILS < <(get_client_emails)
        if [[ ${#EMAILS[@]} -gt 0 ]]; then
            echo "✅ Success: found client with name '$USERNAME' in inbound tag '$INBOUND_TAG'"
        else
            echo "❌ Error: not found client with name '$USERNAME' in inbound tag '$INBOUND_TAG', exit"
            exit 1
        fi

        # make tmp file
        TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
        chmod 644 "$TMP_XRAY_CONFIG"

        # set trap for tmp removing
        trap 'rm -f "$TMP_XRAY_CONFIG"' EXIT
        
        block_user() {
            jq --arg tag "$INBOUND_TAG" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" \
            --argjson emails "$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)" '
            '"$jq_common_preamble"' |

            def is_managed_rule:
                (.type == "field")
                and (.outboundTag == $bot)
                and ((.inboundTag // []) | index($tag))
                and ((.ruleTag // "") == $rt)
                and has("user")
                and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

            .routing.rules |= (
                map(
                if is_managed_rule then
                    .user = (((.user // []) + $emails) | unique)
                else .
                end
                )
            )
            ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
        }
        run_and_check "block user ${EMAILS[*]}, ruleTag '$RULE_TAG'" block_user
    ;;

    unblock)
        # check client only in our tagged rule
        mapfile -t EMAILS < <(get_blocked_emails_from_rule)
        if [[ ${#EMAILS[@]} -gt 0 ]]; then
            echo "✅ Success: found client for unblock name '$USERNAME' in ruleTag '$RULE_TAG'"
        else
            echo "❌ Error: not found client for unblock name '$USERNAME' in ruleTag '$RULE_TAG', exit"
            exit 1
        fi

        # make tmp file
        TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
        chmod 644 "$TMP_XRAY_CONFIG"

        # set trap for tmp removing
        trap 'rm -f "$TMP_XRAY_CONFIG"' EXIT

        unblock_user() {
            jq --arg tag "$INBOUND_TAG" --arg bot "$BLOCK_OUTBOUND_TAG" --arg rt "$RULE_TAG" \
            --argjson emails "$(printf '%s\n' "${EMAILS[@]}" | jq -R . | jq -s .)" '
            '"$jq_common_preamble"' |

            def is_managed_rule:
                (.type == "field")
                and (.outboundTag == $bot)
                and ((.inboundTag // []) | index($tag))
                and ((.ruleTag // "") == $rt)
                and has("user")
                and ((keys - ["type","inboundTag","outboundTag","user","ruleTag"]) | length == 0);

            .routing.rules |= (
                map(
                if is_managed_rule then
                    .user = ((.user // []) - $emails)
                else .
                end
                )
                | map(
                    if is_managed_rule and ((.user // []) | length == 0) then empty else .
                    end
                )
            )
            ' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"
        }
        run_and_check "unblock user ${EMAILS[*]}, ruleTag '$RULE_TAG'" unblock_user
    ;;

  *)
    echo "❌ Error: wrong argument, read help again, exit"
    exit 1
    ;;
esac

run_and_check "backup xray config" cp -a "$XRAY_CONFIG" "$BACKUP_PATH"
run_and_check "new xray config checking" sudo -u xray xray run -test -config "$TMP_XRAY_CONFIG"
run_and_check "install new xray config" install -m 600 -o xray -g xray "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"
run_and_check "restart xray service" systemctl restart xray.service