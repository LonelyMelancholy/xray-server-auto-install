#!/bin/bash

# |---------------|
# | Root checking |
# |---------------|
if [[ $EUID -ne 0 ]]; then
    echo "❌ You not root user, exit"
    exit 1
else
    echo "✅ You root user, continued"
fi

# |--------------------------|
# | Check configuration file |
# |--------------------------|
CFG_CHECK="module/conf_check.sh"
if [ ! -r "$CFG_CHECK" ]; then
    echo "❌ Error: check $CFG_CHECK it's missing or you not have right to read"
    exit 1
fi
source "$CFG_CHECK"

# |---------------|
# | Update system |
# |---------------|
if [[ -n "$UBUNTU_PRO_TOKEN" ]]; then
    if pro attach "$UBUNTU_PRO_TOKEN" > logs/ubuntu_pro.log 2>&1; then
        echo "✅ Ubuntu Pro activated"
    else
        echo "⚠️ Warning: Ubuntu Pro activation error, check "logs/ubuntu_pro.log" for more info, continued"
    fi
fi

export DEBIAN_FRONTEND=noninteractive
i=1
max_i=4
LOG_UPDATE_LIST="logs/update_list.log"
while true; do
    echo "⚠️ Updating packages list $i attempt, please wait"
    if apt-get update > "$LOG_UPDATE_LIST" 2>&1; then
        echo "✅ Update packages list completed"
        break
    fi
    if [ "$i" -lt "$max_i" ]; then
        sleep 10
        echo "❌ Updating package list failed, trying again"
        i=$((i+1))
        continue
    else
        echo "❌ Update packages list attempts ended, update failed check $LOG_UPDATE_LIST"
        exit 1
    fi
done

LOG_UPDATE_DIST="logs/update_dist.log"
i=1
while true; do
    echo "⚠️ Updating packages $i attempt, please wait"
    if apt-get dist-upgrade -y > "$LOG_UPDATE_DIST" 2>&1; then
        echo "✅ Package update completed"
        echo "✅ System will reboot"
        break
    fi
    if [ "$i" -lt "$max_i" ]; then
        sleep 10
        echo "❌ Updating package failed, trying again"
        i=$((i+1))
        continue
    else
        echo "❌ Update packages attempts ended, update failed check $LOG_UPDATE_DIST"
        exit 1
    fi
done

if ! reboot; then
    echo "❌ Reboot command failed"
    exit 1
fi

exit 0