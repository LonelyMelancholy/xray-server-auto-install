#!/usr/bin/env bash

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit"; exit 1; }

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "❌ Error: you are not the telegram_gateway user, exit"; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit"; exit 1; }

# lock check
run_lock_check tr_db "console"

# permission check
read_and_write_check "$TR_DB_M"
read_and_write_check "$TR_DB_Y"

# Network avg func for 10 seconds using ifstat function
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

# critical daemon status function
daemon_status() {
    local service="$1"
    local name="$2"
    if systemctl is-active --quiet "$service" &> /dev/null; then
        echo "☑️ Status $name: running"
    else
        echo "❌ Status $name: fail"
    fi
}

# function to convert kilobytes to megabytes
kb_to_mb() { awk -v x="$1" 'BEGIN{ printf "%.0f", x/1024 }'; }

# function parse traffic json to name:name:number
stat_lines() {
    local json="$1"
    jq -r '
        .stat[]
        | (.name | split(">>>")) as $p
        | "\($p[0]):\($p[1]):\(.value // 0)"
        ' <<<"$json"
}

# function calculate sum server traffic inbound+outbound (in all direction)
sum_server() {
    local lines="$1"
    awk -F: '
        $1=="inbound" || $1=="outbound" { s += ($3+0) }
        END { print s+0 }
        ' <<<"$lines"
}

# function for formatting bytes to human read
fmt(){ numfmt --to=iec --suffix=B "$1"; }

# system uptime
UPTIME_SEC="$(awk '{print int($1)}' /proc/uptime)"
UPTIME_STRING=$(printf "%dd %02dh:%02dm:%02ds" "$((UPTIME_SEC/86400))" \
    "$((UPTIME_SEC%86400/3600))" "$((UPTIME_SEC%3600/60))" "$((UPTIME_SEC%60))")

# uptime xray
UPTIME_XRAY_SEC=$(( $(date +%s) - $(date -d "$(systemctl show -p ActiveEnterTimestamp --value xray.service)" +%s) ))
UPTIME_XRAY_STRING=$(printf "%dd %02dh:%02dm:%02ds" "$((UPTIME_XRAY_SEC/86400))" \
    "$((UPTIME_XRAY_SEC%86400/3600))" "$((UPTIME_XRAY_SEC%3600/60))" "$((UPTIME_XRAY_SEC%60))")

# load average
read -r LOAD_1 LOAD_5 LOAD_15 < <(awk '{print $1, $2, $3}' /proc/loadavg)

# memory (KB) from /proc/meminfo
while read -r key value; do
    case "$key" in
        MemTotal:)     MEM_TOTAL_MB="$(kb_to_mb "$value")" ;;
        MemFree:)      MEM_FREE_MB="$(kb_to_mb "$value")" ;;
        MemAvailable:) MEM_AVAILABLE_MB="$(kb_to_mb "$value")" ;;
        Buffers:)      BUFFERS_MB="$(kb_to_mb "$value")" ;;
        Cached:)       CACHED_MB="$(kb_to_mb "$value")" ;;
        SReclaimable:) SRECLAIMABLE_MB="$(kb_to_mb "$value")" ;;
    esac
done < <(awk '{print $1, $2}' /proc/meminfo)

# calculate buff+cached mb
BUFF_CACH_MB=$(( BUFFERS_MB + CACHED_MB + SRECLAIMABLE_MB ))
# calculate mem load mb
MEM_LOAD_MB=$(( MEM_TOTAL_MB - MEM_AVAILABLE_MB ))
# calculate mem load %
MEM_LOAD_PCT=$(( 100 * ( MEM_TOTAL_MB - MEM_AVAILABLE_MB ) / MEM_TOTAL_MB ))

# get all online user list in json
# call "xray api statsgetallonlineusers" make reset online device to offline if he real offline
XRAY_API_JSON="$(xray api statsgetallonlineusers)"

#reset user count and device count
ONLINE_USERS=0
ONLINE_DEVICES=0

# if not empty, (xray offline), or if not {} (no online users) try get user status and device count
if ! [[ -z "$XRAY_API_JSON" || "$XRAY_API_JSON" == "{}" ]]; then
    # collect full username massive from json
    mapfile -t USERS_ONLINE_EMAIL_FULL < <(
        jq -r '.users // []
            | .[]
            | sub("^user>>>";"")
            | sub(">>>online$";"")
            ' <<<"$XRAY_API_JSON" 2>/dev/null | awk 'NF'
    )

    # online users = number element in massive
    ONLINE_USERS="${#USERS_ONLINE_EMAIL_FULL[@]}"

    # cycle for every user get number online device
    for username in "${USERS_ONLINE_EMAIL_FULL[@]}"; do
        online_json="$(xray api statsonline --email "$username" 2>/dev/null)"
        online_val="$(jq -r '.stat.value // 0' <<<"$online_json" 2>/dev/null || echo 0)"
        [[ "$online_val" =~ ^[0-9]+$ ]] || online_val=0
        ONLINE_DEVICES="$(( ONLINE_DEVICES + online_val ))"
    done
fi

# get default route ip address
IP_4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
IP_6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

# if ip empty, print "none" value
[[ -z $IP_4 ]] && IP_4=none
[[ -z $IP_6 ]] && IP_6=none

# get traffic base
RAW_M="$(cat "$TR_DB_M")"
RAW_Y="$(cat "$TR_DB_Y")"

# parse lines to name:name:number
DATA_M="$(stat_lines "$RAW_M")"
DATA_Y="$(stat_lines "$RAW_Y")"

# calculate sum server traffic inbound+outbound
SERVER_TOTAL_M="$(sum_server "$DATA_M")"
SERVER_TOTAL_Y="$(sum_server "$DATA_Y")"

# formatting bytes
TFAFFIC_M="$(fmt "$SERVER_TOTAL_M")"
TFAFFIC_Y="$(fmt "$SERVER_TOTAL_Y")"

# init system status
SYSTEM_STATUS="☑️ Init system: $(systemctl is-system-running)"

# critical daemon status
SSH_STATUS="$(daemon_status ssh.socket ssh)"
CRON_STATUS="$(daemon_status cron.service cron)"
FAIL2BAN_STATUS="$(daemon_status fail2ban.service fail2ban)"
NGINX_STATUS="$(daemon_status nginx.service nginx)"
XRAY_STATUS="$(daemon_status xray.service xray)"

# count total and free space in / directory
TOTAL_SPACE_GB=$(df -B1 --output=size / | awk 'NR==2 { printf "%.2f", $1/1024/1024/1024 }')
FREE_SPACE_GB=$(df -B1 --output=avail / | awk 'NR==2 { printf "%.2f", $1/1024/1024/1024 }')

# collect network stat
NETWORK_STAT="$(network_stat)"

# Output
echo "🖥️ Hostname: $(hostname)"
echo "🌐 IPv4: ${IP_4}"
echo "🌐 IPv6: ${IP_6}"
echo "⏱️ Uptime server: ${UPTIME_STRING}"
echo "⏱️ Uptime xray: ${UPTIME_XRAY_STRING}"
echo "${SYSTEM_STATUS}"
echo "${SSH_STATUS}"
echo "${CRON_STATUS}"
echo "${FAIL2BAN_STATUS}"
echo "${NGINX_STATUS}"
echo "${XRAY_STATUS}"
echo "🧑🏿‍💻 Online users: ${ONLINE_USERS}"
echo "📱 Online devices: ${ONLINE_DEVICES}"
echo "📈 Load average (1/5/15m): ${LOAD_1} ${LOAD_5} ${LOAD_15}"
echo "🧠 Mem total: ${MEM_TOTAL_MB} MB"
echo "🗃 Mem available: ${MEM_AVAILABLE_MB} MB"
echo "🆓 Mem free: ${MEM_FREE_MB} MB"
echo "🗂️ Mem buff+cache: ${BUFF_CACH_MB} MB"
echo "🧮 Mem load: ${MEM_LOAD_MB} MB (${MEM_LOAD_PCT}%)"
echo "📁 Storage total: ${TOTAL_SPACE_GB} GB"
echo "📂 Storage free: ${FREE_SPACE_GB} GB"
echo "📅 Host annual traffic: ${TFAFFIC_Y}"
echo "🗓️ Host monthly traffic: ${TFAFFIC_M}"
echo "📡 $NETWORK_STAT"

exit 0