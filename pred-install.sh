#!/bin/bash
# pred install script

# main variables
LOG_UBUNTU_PRO="logs/ubuntu_pro.log"
LOG_UPDATE_LIST="logs/update_list.log"
LOG_INSTALL_UTILITIES="logs/install_utilities.log"
LOG_UPDATE_DIST="logs/update_dist.log"
LOG_CLEANUP="logs/cleanup.log"
MISSING_PACKAGE_LIST=()
CMD_LIST_UPDATE=(apt-get update)
CMD_INSTALL_PACKAGE=(env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew install)
CMD_DIST_UPGRADE=(env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew dist-upgrade)

# cd intro script folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# start logging in console
echo "📢 Info: starting the procedure for preparing the system for installation"

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# check another instance of the script is not running
readonly LOCK_FILE="/var/run/vpn_pred-install.lock"
exec {fd}> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n ${fd} || { echo "❌ Error: another instance is running, exit"; exit 1; }

# check os version
[[ -r /etc/os-release ]] || { echo "❌ Error: '/etc/os-release' missing or you do not have read permissions, exit"; exit 1; }
source /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ "${VERSION_ID%%.*}" -lt 24 ]]; then
    echo "❌ Error: this script requires Ubuntu 24.04 or higher, exit"
    exit 1
fi

# helper function
run_and_check() {
    local action="$1"
    local log="$2"
    shift 2
    if "$@" &> "$log"; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# function for install utilities an update
install_and_update() {
    local action="$1"
    local log="$2"
    shift 2
    local attempt=1
    local max_attempts=3

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first two)
        if "$@" &> "$log"; then
            echo "✅ Success: $action completed"
            return 0
        fi
        if [[ "$attempt" -lt "$max_attempts" ]]; then
            sleep 60
            echo "📢 Info: $action failed, trying again"
            ((attempt++))
            continue
        else
            echo "❌ Error: $action failed, after $attempt attempts, check '$log', exit"
            exit 1
        fi
    done
}

# function countdown before reboot
countdown() {
    local sec=$1
    while [[ "$sec" -gt 0 ]]; do
        printf "\r✅ Success: system will reboot after %2d sec, Ctrl+C to interrupt" "$sec"
        sleep 1
        ((sec--))
    done
    printf "\r✅ Success: launch server reboot                                      \n"
}

# main logic start here
# create log dir and check writable
mkdir -p logs &> /dev/null || { echo "❌ Error: cannot create 'logs' directory, exit"; exit 1; }

# check and source configuration file
CFG_CHECK="module/cfg_check.lib.sh"
[[ -r "$CFG_CHECK" ]] || { echo "❌ Error: check '$CFG_CHECK' it's missing or you do not have read permissions, exit"; exit 1; }
# shellcheck source=module/cfg_check.lib.sh
source "$CFG_CHECK" || { echo "❌ Error: failed to source '$CFG_CHECK', exit"; exit 1; }

# hostname change
if [[ $(hostname) != "$XRAY_HOSTNAME" ]]; then
    run_and_check "set new hostname" "/dev/null" hostnamectl set-hostname "$XRAY_HOSTNAME"
else
    echo "✅ Success: new hostname matches the old hostname, changes not needed"
fi

# utilities check, if missing add to array
for utility in curl unzip jq openssl ca-certificates ifstat nftables ubuntu-pro-client; do
    if ! command -v "$utility" &> /dev/null; then
        MISSING_PACKAGE_LIST+=("$utility")
    fi
done

# update list packages with logging
install_and_update "update packages list" "$LOG_UPDATE_LIST" "${CMD_LIST_UPDATE[@]}"

# install utilities if missing
if [[ "${#MISSING_PACKAGE_LIST[@]}" -gt 0 ]]; then
    echo "📢 Info: required utilities: '${MISSING_PACKAGE_LIST[*]}' not found, prepare for installation"
    install_and_update "install required utilities: '${MISSING_PACKAGE_LIST[*]}'" "$LOG_INSTALL_UTILITIES" \
        "${CMD_INSTALL_PACKAGE[@]}" "${MISSING_PACKAGE_LIST[@]}"
fi

# activate ubuntu pro
if [[ -n "$UBUNTU_PRO_TOKEN" ]]; then
    echo "📢 Info: try to activate Ubuntu Pro, please wait"
    if pro attach "$UBUNTU_PRO_TOKEN" &> "$LOG_UBUNTU_PRO"; then
        echo "✅ Success: Ubuntu Pro activated"
    else
        echo "📢 Info: Ubuntu Pro activation error, check '$LOG_UBUNTU_PRO' for more info, continue"
    fi
fi

# update packages
install_and_update "updating packages" "$LOG_UPDATE_DIST" "${CMD_DIST_UPGRADE[@]}"

# clean apt cache
echo "📢 Info: cleaning up package cache, please wait"
run_and_check "cleaning package cache" "$LOG_CLEANUP" apt-get clean

# countdown before reboot
countdown 10

# reboot after pause
reboot &> /dev/null || { echo "❌ Error: reboot command failed, exit"; exit 1; }