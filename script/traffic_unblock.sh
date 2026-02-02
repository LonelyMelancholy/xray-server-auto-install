#!/usr/bin/env bash
set -euo pipefail

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
AUTO_BLOCK_TAG="${AUTO_BLOCK_TAG:-autoblock-traffic-users}"
TR_DB_M="${TR_DB_M:-/var/log/xray/TR_DB_M}"

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
xray_lock
tr_db_lock

# check xray conf
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

# check TR_DB
if [[ ! -r "$TR_DB_M" ]]; then
    echo "❌ Error: check $TR_DB_M it's missing or you do not have read permissions, exit"
    exit 1
fi


if [[ $# -lt 1 ]]; then
  echo "Error: name for unblock"
  exit 1
fi

USERNAME="$1"  # на случай если передали full строку с метаданными
if [[ -z "${USERNAME}" ]]; then
  echo "ERROR: empty username."
  exit 1
fi

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
  fi
}

safe_write_json() {
  # safe_write_json <srcfile> <jq_filter> <jq_args...>
  local src="$1"; shift
  local filter="$1"; shift

  local dir tmp
  dir="$(dirname "$src")"
  tmp="$(mktemp "${dir}/.$(basename "$src").tmp.XXXXXX")"

  jq --indent 2 "$@" "$filter" "$src" > "$tmp"

  cat "$tmp" > "$src"
}

echo "Target user base: '${USERNAME}'"

# --- 1) Правим XRAY_CONFIG ---
if [[ -f "$XRAY_CONFIG" ]]; then
  conf_matches="$(jq -r --arg tag "$AUTO_BLOCK_TAG" --arg uname "$USERNAME" '
    [
      .routing.rules[]? 
      | select(.ruleTag? == $tag)
      | (.user[]? | select((split("|")[0]) == $uname))
    ] | length
  ' "$XRAY_CONFIG" 2>/dev/null || echo "PARSE_ERROR")"

  if [[ "$conf_matches" == "PARSE_ERROR" ]]; then
    echo "XRAY_CONFIG: ERROR: cannot parse JSON: $XRAY_CONFIG"
  else
    backup_file "$XRAY_CONFIG"

    safe_write_json "$XRAY_CONFIG" '
      if (.routing? and .routing.rules? and (.routing.rules | type == "array")) then
        .routing.rules |= (
          map(
            if (.ruleTag? == $tag) and (.user? | type == "array") then
              .user |= map(select((split("|")[0]) != $uname))
              | if ((.user | length) == 0) then empty else . end
            else
              .
            end
          )
        )
      else
        .
      end
    ' --arg tag "$AUTO_BLOCK_TAG" --arg uname "$USERNAME"

    # проверим, осталось ли правило autoblock
    remaining_rules="$(jq -r --arg tag "$AUTO_BLOCK_TAG" '
      [.routing.rules[]? | select(.ruleTag? == $tag)] | length
    ' "$XRAY_CONFIG" 2>/dev/null || echo "UNKNOWN")"

    echo "XRAY_CONFIG: removed ${conf_matches} user entry(ies) from tag '${AUTO_BLOCK_TAG}'. Remaining autoblock rules: ${remaining_rules}"
  fi
else
  echo "XRAY_CONFIG: skipped (file not found): $XRAY_CONFIG"
fi

# --- 2) Правим TR_DB_M ---
if [[ -f "$TR_DB_M" ]]; then
  tr_matches="$(jq -r --arg uname "$USERNAME" '
    [
      .stat[]?
      | select(.name? and (.name | type == "string"))
      | select(.name | startswith("user>>>"))
      | (.name | split(">>>")) as $p
      | select(($p | length) > 1)
      | select(($p[1] | split("|")[0]) == $uname)
      | select(has("value"))
    ] | length
  ' "$TR_DB_M" 2>/dev/null || echo "PARSE_ERROR")"

  if [[ "$tr_matches" == "PARSE_ERROR" ]]; then
    echo "TR_DB_M: ERROR: cannot parse JSON: $TR_DB_M"
  else
    backup_file "$TR_DB_M"

    safe_write_json "$TR_DB_M" '
      if (.stat? and (.stat | type == "array")) then
        .stat |= map(
          if (.name? and (.name | type == "string") and (.name | startswith("user>>>"))) then
            (.name | split(">>>")) as $p
            | if (($p | length) > 1 and ($p[1] | split("|")[0]) == $uname) then
                del(.value)
              else
                .
              end
          else
            .
          end
        )
      else
        .
      end
    ' --arg uname "$USERNAME"

    echo "TR_DB_M: cleared 'value' in ${tr_matches} stat record(s) for user base '${USERNAME}'."
  fi
else
  echo "TR_DB_M: skipped (file not found): $TR_DB_M"
fi

echo "Done ✅ (Backups created as *.bak.YYYYmmdd-HHMMSS)"
