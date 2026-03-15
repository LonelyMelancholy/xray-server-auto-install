#!/bin/bash
# script for cpu monitoring and send alert via Telegram
# all errors are logged in journald, see journalctl -t cpu_alert

# enable logging
exec > >(systemd-cat -t cpu_alert -p info) 2> >(systemd-cat -t cpu_alert -p err) 5> >(systemd-cat -t cpu_alert -p notice)

# start logging message
echo "cpu alert started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    echo "cpu alert stopped - $(date '+%Y-%m-%d %H:%M:%S')" >&5
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# user check
[[ "$(id -un)" != "$TARGET_USER" ]] && { echo "Error: you are not the '$TARGET_USER' user, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "cpu_alert"

# function for ger cpu usage from /proc/stat
get_cpu_usage() {
    local total_1 idle_1 total_2 idle_2 total_delta idle_delta usage
    local _ user nice system idle iowait irq softirq steal guest guest_nice

    # get first string /proc/stat
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    total_1=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_1=$((idle + iowait))

    sleep 1

    # shellcheck disable=SC2034
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    total_2=$((user + nice + system + idle + iowait + irq + softirq + steal))
    idle_2=$((idle + iowait))

    total_delta=$((total_2 - total_1))
    idle_delta=$((idle_2 - idle_1))

    if [ "$total_delta" -eq 0 ]; then
        echo 0
        return
    fi

    usage=$(( (100 * (total_delta - idle_delta)) / total_delta ))
    echo "$usage"
}

# main logic here
while true; do
    CPU=$(get_cpu_usage)

    if [ "$CPU" -ge "$CPU_THRESHOLD" ]; then
        # get top 3 process
        PROCESS=$(ps -eo pid=,comm=,%cpu= --sort=-%cpu | head -n 3)

        # make message
        MESSAGE="🚨 <b>High cpu usage alert</b> 

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
📈 <b>Treshold:</b> ${CPU_THRESHOLD}%
🚨 <b>Usage:</b> ${CPU}%
📉 <b>Top 1:</b> $(awk 'NR==1{printf "PID=%s CMD=%s CPU=%s%%\n",$1,$2,$3; exit}' <<< "$PROCESS")
📉 <b>Top 2:</b> $(awk 'NR==2{printf "PID=%s CMD=%s CPU=%s%%\n",$1,$2,$3; exit}' <<< "$PROCESS")
📉 <b>Top 3:</b> $(awk 'NR==3{printf "PID=%s CMD=%s CPU=%s%%\n",$1,$2,$3; exit}' <<< "$PROCESS")
💾 <b>Notify log:</b> journalctl -t cpu_alert"

        # logging message
        echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$MESSAGE"
        
        # send message
        telegram_message "$MESSAGE"
    fi

    sleep "$CHECKING_FREQUENCY"
done
