#!/bin/bash
# auto install upgrade (unattended-upgrade) and send notify via systemd timer every first day month, 5:00-6:00 night time
# all errors are logged in journald, see journalctl -t unattended_upgrade
# exit codes work to tell systemd about success complete work, message status not matter

# enable logging
exec > >(systemd-cat -t unattended_upgrade -p info) 2> >(systemd-cat -t unattended_upgrade -p err) 5> >(systemd-cat -t unattended_upgrade -p notice)

# start logging message
echo "unattended upgrade started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "unattended upgrade ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
        [[ "$REBOOT" -eq "1" ]] && { echo "reboot required, start reboot system"; reboot || echo "reboot failed" >&2; }
    else
        echo "unattended upgrade failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# root check
[[ $EUID -ne 0 ]] && { echo "Error: you are not the root user, exit" >&2; exit 1; }

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "unattended_upgrade"

# check another update script not running and wait for exit
run_lock_wait "common_update" "3600"

# function section
# function for update and upgrade with retry
update_and_upgrade() {
    local action="$1"
    shift 1
    local attempt=1
    local max_attempts=10
    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first one)
        if "$@"; then
            echo "Success: $action completed"
            RC=0
            return 0
        fi
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            sleep 60
            echo "Info: $action failed, trying again"
            ((attempt++))
            continue
        else
            echo "Error: $action failed, attempts ended, check 'journalctl -t unattended_upgrade' for info, exit" >&2
            return 1
        fi
    done
}

# function for checking fail in update/upgrade step
check_fail() {
    if [[ -n "${FAIL_STEP:-}" ]]; then
        MESSAGE="❌ <b>Scheduled security update</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
❌ <b>Action:</b> upgrade failed
❌ <b>Step:</b> ${FAIL_STEP}
💾 <b>UN-UP log:</b> /var/log/unattended-upgrades/unattended-upgrades.log
💾 <b>Update log:</b> journalctl -t unattended_upgrade
💾 <b>Dpkg log:</b> /var/log/dpkg.log"

        # logging message
        echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$MESSAGE"

        #sending message and exit with error code
        telegram_message "$MESSAGE"
        exit $RC
    fi
}

# main logic start here
# send start update message
MESSAGE="⚠️ <b>Scheduled security update</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
☑️ <b>Action:</b> update started"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message "$MESSAGE"

# call update and fail check
update_and_upgrade "update packages list" apt-get update || { FAIL_STEP="apt-get update"; check_fail; }
update_and_upgrade "upgrade" unattended-upgrade || { FAIL_STEP="unattended-upgrade"; check_fail; }

# parse package changes from dpkg.log for name+version, not use unattended log because he dont have version
CHANGES="$(awk -v d="$TODAY" '
  function numver(v,    m) {
    sub(/^[0-9]+:/, "", v)
    if (match(v, /^[0-9]+(\.[0-9]+)*/))
      return substr(v, RSTART, RLENGTH)
    return v
  }
  $1==d && ($3=="upgrade" || $3=="install" || $3=="remove") {
    pkg=$4; sub(/:.*/,"",pkg);
    if ($3=="upgrade")
      printf "[↻] upgrade %s %s -> %s\n", pkg, numver($5), numver($6);
    else if ($3=="install")
      printf "[↑] install %s %s\n", pkg, numver($6);
    else if ($3=="remove")
      printf "[↓] %s %s %s\n", $3, pkg, numver($5);
  }' /var/log/dpkg.log)"

# set variable for message
if [[ -z "$CHANGES" ]]; then
    CHANGE_SUMMARY="➖ No package changes"
else
    COUNT="$(printf "%s\n" "$CHANGES" | wc -l)"
    CHANGE_SUMMARY="➕ $COUNT package changed:
$CHANGES"
fi

# start collecting final message
MESSAGE="<b>✅ Scheduled security update</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
☑️ <b>Action:</b> update success
$CHANGE_SUMMARY
💾 <b>UN-UP log:</b> /var/log/unattended-upgrades/unattended-upgrades.log
💾 <b>Update log:</b> journalctl -t unattended_upgrade
💾 <b>Dpkg log:</b> /var/log/dpkg.log"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message "$MESSAGE"

# check reboot requiers, if reboot need - send message
if [[ -f /var/run/reboot-required ]]; then
    PKGS_REBOOT="$(cat /var/run/reboot-required.pkgs)"
    PKGS_REBOOT="$(printf '%s\n' "$PKGS_REBOOT" | sed 's/^/[→] /')"
    MESSAGE="⚠️ <b>Scheduled security update</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
☑️ <b>Action:</b> reboot after 1 min
🔎 <b>Reboot request from packages:</b>
${PKGS_REBOOT}"

    # logging message
    echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "$MESSAGE"

    # sending message
    telegram_message "$MESSAGE"

    # pause before reboot
    sleep 60

    # set reboot flag
    REBOOT=1
fi

# exit with work success status
exit $RC
