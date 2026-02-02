#!/usr/bin/env bash

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# check another instance working on tr_db
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }
tr_db_lock_retry

# system uptime
read -r up _ < /proc/uptime
up="${up%.*}"
days=$((up / 86400))
hrs=$(( (up % 86400) / 3600 ))
mins=$(( (up % 3600) / 60 ))
secs=$(( up % 60 ))
uptime_str=$(printf "%dd:%02dh:%02dm:%02ds" "$days" "$hrs" "$mins" "$secs")

# uptime xray
start_epoch_xray="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value xray.service)" +%s)"
runtime_xray=$(( $(date +%s) - start_epoch_xray ))
days_xray=$((runtime_xray/86400))
hrs_xray=$((runtime_xray%86400/3600))
mins_xray=$((runtime_xray%3600/60))
secs_xray=$((runtime_xray%60))
uptime_xray=$(printf "%dd:%02dh:%02dm:%02ds" "$days_xray" "$hrs_xray" "$mins_xray" "$secs_xray")


# Load average
read -r load1 load5 load15 _ < /proc/loadavg

# --- Memory (MB) from /proc/meminfo ---
declare -A m
while IFS=":" read -r key val; do
  key="${key// /}"
  val="${val%%kB*}"
  val="${val// /}"
  [[ -n "${key}" && -n "${val}" ]] && m["$key"]="$val"
done < /proc/meminfo

total_kb="${m[MemTotal]}"
free_kb="${m[MemFree]}"
buffers_kb="${m[Buffers]:-0}"
cached_kb="${m[Cached]:-0}"
sreclaim_kb="${m[SReclaimable]:-0}"
shmem_kb="${m[Shmem]:-0}"

# buff+cache (приближенно как в free): Buffers + Cached + SReclaimable - Shmem
buff_cache_kb=$((buffers_kb + cached_kb + sreclaim_kb - shmem_kb))

# mem load: total - free - buff/cache
used_kb=$((total_kb - free_kb - buff_cache_kb))

kb2mb() { awk -v kb="$1" 'BEGIN{printf "%.0f", kb/1024}'; }

total_mb="$(kb2mb "$total_kb")"
free_mb="$(kb2mb "$free_kb")"
bc_mb="$(kb2mb "$buff_cache_kb")"
used_mb="$(kb2mb "$used_kb")"
used_pct="$(awk -v u="$used_kb" -v t="$total_kb" 'BEGIN{printf "%.1f", (u/t)*100}')"  # %

# --- Network avg for 10 seconds using ifstat ---
network_stat() {
  ifstat 1 10 2>/dev/null | awk '
    NR>2 {rx+=$1; tx+=$2; n++}
    END {
      if (n>0) {
        printf "Net load: 🔽 receive - %.2f Mbit/s ⬆️ transmit - %.2f Mbit/s\n", (rx/n)*8/1000, (tx/n)*8/1000
      } else {
        print "Net load: no data"
      }
    }'
}
NET="$(network_stat)"

ONLINE_USERS=0
ACTIVE_DEVICES=0

# Собираем devices по username (как у тебя: uid%%|*)
declare -A DEVICES_BY_USER=()

stats_json="$(xray api statsquery 2>/dev/null)"
if [[ -z "$stats_json" ]]; then
  # нет статистики - значит онлайн никого
  ONLINE_USERS=0
  ACTIVE_DEVICES=0
else
  mapfile -t USER_IDS < <(
    jq -r '
      (.stat // [])[]
      | .name
      | select(type=="string")
      | select(startswith("user>>>"))
      | (split("user>>>")[1] | split(">>>traffic>>>")[0])
    ' <<<"$stats_json" 2>/dev/null | awk 'NF' | sort -u
  )

  for uid in "${USER_IDS[@]}"; do
    username="${uid%%|*}"
    [[ -z "$username" ]] && continue

    online_json="$(xray api statsonline --email "$uid" 2>/dev/null || true)"
    online_val="$(jq -r '.stat.value // 0' <<<"$online_json" 2>/dev/null || echo 0)"
    [[ "$online_val" =~ ^[0-9]+$ ]] || online_val=0

    if (( online_val > 0 )); then
      DEVICES_BY_USER["$username"]=$(( ${DEVICES_BY_USER["$username"]:-0} + online_val ))
    fi
  done

  # считаем итоговые переменные
  ONLINE_USERS=0
  ACTIVE_DEVICES=0
  for u in "${!DEVICES_BY_USER[@]}"; do
    d="${DEVICES_BY_USER[$u]:-0}"
    if (( d > 0 )); then
      ONLINE_USERS=$(( ONLINE_USERS + 1 ))
      ACTIVE_DEVICES=$(( ACTIVE_DEVICES + d ))
    fi
  done
fi

IFACE="$(ip route | awk '/^default/ {print $5; exit}')"
IP_4="$(ip -4 addr show dev "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
IP_6="$(ip -6 addr show dev "$IFACE" scope global | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n1)"
[[ -z $IP_6 ]] && IP_6=none

readonly RAW_M="$(cat "/var/log/xray/TR_DB_M")"
readonly RAW_Y="$(cat "/var/log/xray/TR_DB_Y")"
        # parse json to name:name:number
        stat_lines() {
        local json="$1"
        jq -r '
            .stat[]
            | (.name | split(">>>")) as $p
            | "\($p[0]):\($p[1]):\(.value // 0)"
        ' <<<"$json"
        }
        DATA_M="$(stat_lines "$RAW_M")"
        DATA_Y="$(stat_lines "$RAW_Y")"

        # calculate total server traffic
        sum_server() {
        local lines="$1"
        awk -F: '
            $1=="inbound" || $1=="outbound" { s += ($3+0) }
            END { print s+0 }
        ' <<<"$lines"
        }
        SERVER_TOTAL_M="$(sum_server "$DATA_M")"
        SERVER_TOTAL_Y="$(sum_server "$DATA_Y")"

        # formatting bytes
        fmt(){ numfmt --to=iec --suffix=B "$1"; }

        TFAFFIC_M="$(fmt "$SERVER_TOTAL_M")"
        TFAFFIC_Y="$(fmt "$SERVER_TOTAL_Y")"

systemctl is-active --quiet ssh.socket && SSH_STATUS="running" || SSH_STATUS="fail"
systemctl is-active --quiet cron.service && CRON_STATUS="running" || CRON_STATUS="fail"
systemctl is-active --quiet fail2ban.service && FAIL2BAN_STATUS="running" || FAIL2BAN_STATUS="fail"
systemctl is-active --quiet nginx.service && NGINX_STATUS="running" || NGINX_STATUS="fail"
systemctl is-active --quiet xray.service && XRAY_STATUS="running" || XRAY_STATUS="fail"

# helper func for make status
make_status() {
    if [[  "$1" ==  "running" ]]; then
        echo "☑️ ${2}: $1"
    else
        echo "❌ ${2}: $1"
    fi
}

SSH_STATUS="$(make_status "$SSH_STATUS" "Status ssh")"
CRON_STATUS="$(make_status "$CRON_STATUS" "Status cron")"
FAIL2BAN_STATUS="$(make_status "$FAIL2BAN_STATUS" "Status fail2ban")"
NGINX_STATUS="$(make_status "$NGINX_STATUS" "Status nginx")"
XRAY_STATUS="$(make_status "$XRAY_STATUS" "Status xray")"

# --- Output ---
echo "🖥️ Hostname: $(hostname)"
echo "🌐 IPv4 ${IP_4}"
echo "🌐 IPv6 ${IP_6}"
echo "⏱️ Uptime server: ${uptime_str}"
echo "⏱️ Uptime xray: ${uptime_xray}"
echo "${SSH_STATUS}"
echo "${CRON_STATUS}"
echo "${FAIL2BAN_STATUS}"
echo "${NGINX_STATUS}"
echo "${XRAY_STATUS}"
echo "🧑🏿‍💻 Online users ${ONLINE_USERS}"
echo "📱 Online devices ${ACTIVE_DEVICES}"
echo "📈 Load average (1/5/15m): ${load1} ${load5} ${load15}"
echo "🧠 Mem total: ${total_mb} MB"
echo "🆓 Mem free: ${free_mb} MB"
echo "🗂️ Mem buff+cache: ${bc_mb} MB"
echo "🧮 Mem load: ${used_mb} MB (${used_pct}%)"
echo "📅 Host annual traffic: $TFAFFIC_Y"
echo "🗓️ Host monthly traffic: $TFAFFIC_M"
echo "📡 $NET"

exit 0