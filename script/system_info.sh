#!/usr/bin/env bash

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the telegram-gateway user, exit"; exit 1; }

# main variables
readonly MAX_ATTEMPTS="3"
readonly WAIT_SEC="$(shuf -i "10-60" -n 1)"
readonly HOSTNAME="$(hostname)"

# check another instanсe of the script is not running
readonly LOCK_FILE_3="/run/lock/tr_db.lock"
exec 10> "$LOCK_FILE_3" || { echo "❌ Error: cannot open lock file '$LOCK_FILE_3', exit"; exit 1; }

# check another instance is not running (with retries)
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  if flock -n 10; then
    break
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "❌ Error: Lock busy ($LOCK_FILE_3). Waiting ${WAIT_SEC}s... (attempt $attempt/$MAX_ATTEMPTS)"
    sleep "$WAIT_SEC"
  else
    echo "❌ Error: lock ($LOCK_FILE_3) is still busy after $MAX_ATTEMPTS attempts, exit"
    exit 1
  fi
done

# Uptime (pretty) from /proc/uptime
read -r up _ < /proc/uptime
up="${up%.*}"

days=$((up / 86400))
hrs=$(( (up % 86400) / 3600 ))
mins=$(( (up % 3600) / 60 ))
secs=$(( up % 60 ))

uptime_str=""
if (( days > 0 )); then uptime_str+="${days}d "; fi
uptime_str+=$(printf "%02dh:%02dm:%02ds" "$hrs" "$mins" "$secs")

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
        printf "Net load: receive - %.2f Mbit/s transmit - %.2f Mbit/s\n", (rx/n)*8/1000, (tx/n)*8/1000
      } else {
        print "Net load: no data"
      }
    }'
}
NET="$(network_stat)"

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

        #annual traffic

# --- Output ---
echo "Hostname: ${HOSTNAME}"
echo "Uptime: ${uptime_str}"
echo "Load average (1/5/15m): ${load1} ${load5} ${load15}"
echo "Mem total: ${total_mb} MB"
echo "Mem free: ${free_mb} MB"
echo "Mem buff+cache: ${bc_mb} MB"
echo "Mem load: ${used_mb} MB (${used_pct}%)"
echo "Host annual traffic: $TFAFFIC_Y"
echo "Host monthly traffic: $TFAFFIC_M"
echo "$NET"
exit 0