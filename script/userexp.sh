#!/bin/bash
# script for add time user in xray config

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# main variables
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly URI_FILE="/usr/local/etc/xray/URI_DB"
readonly XRAY_BACKUP_PATH="${XRAY_CONFIG}.$(date +%Y%m%d_%H%M%S).bak"
readonly URI_BACKUP_PATH="${URI_FILE}.$(date +%Y%m%d_%H%M%S).bak"
readonly INBOUND_TAG="Vless"
readonly BLOCK_RULE_TAG="autoblock-expired-users"
readonly USERNAME="$1"
DAYS="$2"
umask 022

# argument check
if [[ "$#" -ne 2 ]]; then
    echo "Use for add time for user in xray config, run: $0 <username> <days>"
    echo "days 0 - infinity days"
    exit 1
fi

if [[ ! $USERNAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: only letters, numbers and - in name, exit"
    exit 1
fi

if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: days must be non negative number, exit"
    exit 1
fi

# config check
if [[ ! -r "$XRAY_CONFIG" || ! -w "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have permissions, exit"
    exit 1
fi

if [[ ! -r "$URI_FILE" || ! -w "$URI_FILE" ]]; then
    echo "❌ Error: check $URI_FILE it's missing or you do not have permissions, exit"
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

# calculate new today and exp day
readonly TODAY="$(date +%F)"

# write variable
if [[ "$DAYS" == "0" ]]; then
    NEW_EMAIL="${USERNAME}|created=${TODAY}|days=infinity|exp=never"
    DAYS="infinity"
    EXP="never"
else
    EXP="$(date -d "$TODAY +$DAYS days" +%F)"
    NEW_EMAIL="${USERNAME}|created=${TODAY}|days=${DAYS}|exp=${EXP}"
fi

# counts client in config
client_count="$(
  jq -r --arg tag "$INBOUND_TAG" --arg name "$USERNAME" '
    [
      .inbounds[]? | select(.tag == $tag) |
      .settings.clients[]? |
      select(((.email // "") | split("|")[0]) == $name)
    ] | length
  ' "$XRAY_CONFIG"
)"

# we have rule with ruleTag?
rule_exists="$(
  jq -r --arg ruleTag "$BLOCK_RULE_TAG" '
    any(.routing.rules[]?; (.ruleTag? // "") == $ruleTag)
  ' "$XRAY_CONFIG" 2>/dev/null || echo "false"
)"

# count how many time name blocked
blocked_count=0
if [[ "$rule_exists" == "true" ]]; then
  blocked_count="$(
    jq -r --arg ruleTag "$BLOCK_RULE_TAG" --arg name "$USERNAME" '
      [
        .routing.rules[]? | select(.ruleTag == $ruleTag) |
        ((.user // [])[]) |
        select((split("|")[0]) == $name)
      ] | length
    ' "$XRAY_CONFIG"
  )"
fi

# if client not found, exit
if [[ $client_count -eq 0 ]]; then
  echo "❌ Error: '$USERNAME' not found in clients inbound '$INBOUND_TAG', exit"
  exit 1
fi

# to many client found, exit
if [[ $client_count -gt 1 ]]; then
  echo "❌ Error: '$USERNAME' to many match in clients inbound '$INBOUND_TAG', exit"
  exit 1
fi

# main func for renew email and deleting from ban rule
unban_and_add_time() {
    set -e

    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    chmod 644 "$TMP_XRAY_CONFIG"
    
    # set trap for deleting tmp files
    trap 'rm -f "$TMP_XRAY_CONFIG"' EXIT

jq \
  --arg inboundTag "$INBOUND_TAG" \
  --arg ruleTag "$BLOCK_RULE_TAG" \
  --arg name "$USERNAME" \
  --arg newEmail "$NEW_EMAIL" \
  --argjson ruleExists "$( [[ "$rule_exists" == "true" ]] && echo true || echo false )" '
  # renew email if exist
  (.inbounds[]? | select(.tag == $inboundTag) | .settings.clients) |=
    ( . // [] | map(
        if (((.email // "") | split("|")[0]) == $name)
        then .email = $newEmail
        else .
        end
      )
    ) |

  # if ban rule exist delete user from them
  (if $ruleExists then
      .routing = (.routing // {}) |
      .routing.rules = (.routing.rules // []) |
      .routing.rules |= map(
        if (.ruleTag? == $ruleTag) then
          .user = ((.user // []) | map(select((split("|")[0]) != $name)))
        else .
        end
      ) |
      # if rule empty after user deleting, delete rule
      .routing.rules |= map(
        select( (.ruleTag? != $ruleTag) or (((.user // []) | length) > 0) )
      )
   else
      .
   end)
' "$XRAY_CONFIG" > "$TMP_XRAY_CONFIG"

    # backup
    cp -a "$XRAY_CONFIG" "$XRAY_BACKUP_PATH"

}

# add time user, check config, install if config valid and delete tmp files
run_and_check "add time xray user" unban_and_add_time
run_and_check "check new xray config" sudo -u xray xray run -test -config "$TMP_XRAY_CONFIG"

# Если нет изменений — выходим
if cmp -s "$XRAY_CONFIG" "$TMP_XRAY_CONFIG"; then
    rm -f "$TMP_XRAY_CONFIG"
    echo "❌ Error: no changes, NEW_EMAIL='$NEW_EMAIL', exit"
    exit 1
fi

run_and_check "install new xray config" install -m 600 -o xray -g xray "$TMP_XRAY_CONFIG" "$XRAY_CONFIG"
run_and_check "delete temporary xray files " rm -f "$TMP_XRAY_CONFIG"

# unset trap, tmp already deleted
trap - EXIT

# restart
run_and_check "restart xray"  systemctl restart xray.service

# echo result
echo "✅ Success: apply for '$USERNAME' from inbound tag '$INBOUND_TAG'"
echo "✅ Success: new time, created: $TODAY, days: $DAYS, expiration: $EXP"
if [[ "$rule_exists" == "true" ]]; then
    echo "✅ Success: blocked rule found: yes (removed $blocked_count matches)"
else
    echo "✅ Success: blocked rule found: no"
fi
echo "✅ Success: Backup saved $XRAY_BACKUP_PATH"

update_uri_db() {
    set -e

    # make tmp file
    TMP_URI_FILE="$(mktemp --suffix=.json)"

    # set trap for deleting tmp files
    trap 'rm -f "$TMP_URI_FILE"' EXIT

    # search username record in URI
    if ! grep -qE "^name: ${USERNAME}, created: " "$URI_FILE"; then
        echo "❌ Error: no record for in URI for ${USERNAME}"
        return 1
    fi

  # renew only one sring created/days/expiration, not change other
    awk -v n="$USERNAME" -v today="$TODAY" -v days="$DAYS" -v exp="$EXP" '
        $0 ~ ("^name: " n ", created: ") {
        print "name: " n ", created: " today ", days: " days ", expiration: " exp
        next
        }
        {print}
    ' "$URI_FILE" > "$TMP_URI_FILE"

    # backup
    cp -a "$URI_FILE" "$URI_BACKUP_PATH"

    # write from tmp to uri
    install -m 600 -o root -g root "$TMP_URI_FILE" "$URI_FILE"

}

run_and_check "update URI database" update_uri_db
run_and_check "delete temporary uri files " rm -f "$TMP_URI_FILE"

# unset trap
trap - EXIT

# echo result
echo "✅ Success: URI database updated for '${USERNAME}'"
echo "✅ Success: Backup saved '$URI_BACKUP_PATH'"