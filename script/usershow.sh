#!/bin/bash
# script for show user from xray config and URI_DB

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/user.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance working on xray configuration or URI DB, exit"; exit 1; }

# argument check
if ! [[ "$#" -eq 1 ]]; then
    echo "Use for show user from xray config and URI_DB, run: $0 <option>"
    echo "all - all user link and expiration info"
    echo "block - blocked manually user"
    echo "exp - expired, auto blocked user"
    echo "online - online user and ip"
    echo "statistic - user and server traffic statistic"
    exit 1
fi

# main variables
OPTION="$1"
URI_PATH="/usr/local/etc/xray/URI_DB"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# change rule and act depending of option
[[ "$OPTION" == "block" ]] && { BLOCK_RULE_TAG="manual-block-users"; ACT="blocked"; }
[[ "$OPTION" == "exp" ]] && { BLOCK_RULE_TAG="autoblock-expired-users"; ACT="expired"; }

# config and URI_DB check
if [[ ! -r "$XRAY_CONFIG" ]]; then
    echo "❌ Error: check $XRAY_CONFIG it's missing or you do not have read permissions, exit"
    exit 1
fi

if [[ ! -r "$URI_PATH" ]]; then
  echo "❌ Error: check $URI_PATH it's missing or you do not have read permissions, exit"
  exit 1
fi

# search blocked user and print
find_blocked_user() {
    jq -r --arg tag "$BLOCK_RULE_TAG" '
        def parse_user($s):
            ($s | tostring | split("|")) as $p
            | ($p[0] // "") as $name
            | (reduce ($p[1:][]?) as $kv ({}; 
                if ($kv | contains("=")) then
                ($kv | split("=")) as $a
                | . + { ($a[0]): ($a[1:] | join("=")) }
                else . end
            )) as $m
            | "name: \($name), created: \($m.created // ""), days: \($m.days // ""), expiration: \($m.exp // $m.expiration // "")"
        ;

        .routing.rules[]?
        | select(.ruleTag == $tag)
        | (.user // [])[]?
        | parse_user(.)
        ' "$XRAY_CONFIG"
}

# chose path execution
case "$OPTION" in
    all)
        # just print database
        cat "$URI_PATH"
        exit 0
    ;;

    block|exp)
        # count rule math, if not math, exit 
        rule_count="$(jq -r --arg tag "$BLOCK_RULE_TAG" '
        [ .routing.rules[]? | select(.ruleTag == $tag) ] | length
        ' "$XRAY_CONFIG")"

        if [[ "$rule_count" == "0" ]]; then
            echo "❌ Error: ruletag '$BLOCK_RULE_TAG' not found"
            exit 1
        fi

        # count user in ruletag if user not exist, exit
        users_len="$(jq -r --arg tag "$BLOCK_RULE_TAG" '
        [ .routing.rules[]? | select(.ruleTag == $tag) | (.user // [])[]? ] | length
        ' "$XRAY_CONFIG")"

        if [[ "$users_len" == "0" ]]; then
            echo "✅ Success: $ACT users not found"
            exit 0
        fi

        # find and print user in ruletag
        find_blocked_user || { echo "❌ Error: find $ACT user, exit"; exit 1; }
        exit 0
    ;;

    online)
        STATUS_LIST=""
        IP_LIST=""

        stats_json="$(xray api statsquery 2>/dev/null || true)"

        mapfile -t USER_IDS < <(
        jq -r '
            (.stat // [])[]
            | .name
            | select(type=="string")
            | select(startswith("user>>>"))
            | (split("user>>>")[1] | split(">>>traffic>>>")[0])
        ' <<<"$stats_json" | awk 'NF' | sort -u
        )

        declare -A IPS_BY_USER=()
        declare -A ONLINE_BY_USER=()

        for uid in "${USER_IDS[@]}"; do
        username="${uid%%|*}"
        [[ -z "$username" ]] && continue

        online_json="$(xray api statsonline --email "$uid" 2>/dev/null || true)"
        online_val="$(jq -r '.stat.value // 0' <<<"$online_json")"

        if [[ "$online_val" =~ ^[0-9]+$ ]] && (( online_val > 0 )); then
            ip_json="$(xray api statsonlineiplist --email "$uid" 2>/dev/null || true)"
            ips="$(jq -r '((.ips // {}) | keys | join(", "))' <<<"$ip_json")"

            ONLINE_BY_USER["$username"]="$online_val"
            IPS_BY_USER["$username"]="$ips"
        fi
        done

        while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        STATUS_LIST+=$'\n'"${u}: online"
        IP_LIST+=$'\n'"${u}: ${IPS_BY_USER[$u]}"
        done < <(printf '%s\n' "${!IPS_BY_USER[@]}" | sort)

        if [[ -n "$STATUS_LIST" ]]; then
            echo "Online users${STATUS_LIST}"
            echo "Users IP addresses${IP_LIST}"
        fi
        exit 0
    ;;

    statistic)
        readonly RAW="$(cat "/var/log/xray/TR_DB")"

        # parse json to name:name:number
        stat_lines() {
        local json="$1"
        jq -r '
            .stat[]
            | (.name | split(">>>")) as $p
            | "\($p[0]):\($p[1]):\(.value // 0)"
        ' <<<"$json"
        }
        DATA="$(stat_lines "$RAW")"

        # calculate total server traffic
        sum_server() {
        local lines="$1"
        awk -F: '
            $1=="inbound" || $1=="outbound" { s += ($3+0) }
            END { print s+0 }
        ' <<<"$lines"
        }
        SERVER_TOTAL="$(sum_server "$DATA")"

        # calculate total traffic each user and cut | info
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
        USERS_TOTAL="$(sum_users "$DATA")"

        # formatting bytes
        fmt(){ numfmt --to=iec --suffix=B "$1"; }

        MESSAGE="Host traffic: $(fmt "$SERVER_TOTAL")"

        while IFS=$' ' read -r EMAIL TRAFF; do
            [[ -z "$EMAIL" ]] && continue
            TRAFFx2=$(( TRAFF * 2 ))
            MESSAGE+=$'\n'"User traffic: $EMAIL - $(fmt "$TRAFFx2")"
        done <<< "$USERS_TOTAL"

        # output
        echo "$MESSAGE"
        exit 0
    ;;

    *)
        echo "❌ Error: wrong option, read help again, exit"
        exit 1
    ;;
esac