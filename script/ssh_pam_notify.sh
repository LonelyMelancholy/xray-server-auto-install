#!/bin/bash
# script for notify ssh login/unlogin via PAM
# exit 0 to avoid bothering PAM with an incorrect error code
# all errors are still logged, except the first three for debugging, add a redirect to the debug log

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

TARGET_USER="telegram-gateway"

# sends the script to the background from telegram-gateway, without delaying pam and send exit 0 to pam
if [[ -z "${TG_BG:-}" ]]; then
    export TG_BG=1
    if [[ "$(whoami)" != "$TARGET_USER" ]]; then
        /usr/bin/setpriv \
        --reuid="$TARGET_USER" \
        --regid="$TARGET_USER" \
        --init-groups \
        --inh-caps=-all \
        -- "$0" "$@" &> /dev/null &
    else
        "$0" "$@" &> /dev/null &
    fi
    exit 0
fi

# user check
[[ "$(whoami)" != "telegram-gateway" ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly NOTIFY_LOG="/var/log/telegram/ssh_pam.$(date '+%Y-%m-%d').log"
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# start logging message
echo "########## ssh pam notify started - $(date '+%Y-%m-%d %H:%M:%S') ##########"

# exit logging message function
RC_M="1"
on_exit() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "########## ssh pam notify ended - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    else
        echo "########## ssh pam notify failed - $(date '+%Y-%m-%d %H:%M:%S') ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

source "/usr/local/lib/service/telegram.lib.sh" || { echo "❌ Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit"; exit 1; }

# main variables
readonly HOSTNAME="$(hostname)"
readonly IP="$PAM_RHOST"
readonly USER="$PAM_USER"
readonly SESSION="$PAM_TYPE"

# start collecting message
case "$SESSION" in
    open_session)
    MESSAGE="📢 <b>SSH PAM notify (login)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
🧑🏿‍💻 <b>User:</b> $USER
🏴 <b>From:</b> $IP
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    close_session)
    MESSAGE="📢 <b>SSH PAM notify (logout)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
🧑🏿‍💻 <b>User:</b> $USER
🏴 <b>From:</b> $IP
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
    *)
    MESSAGE="⚠️ <b>SSH PAM notify (unknown)</b>

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
❌ Error: unknown PAM session type, check settings
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> $NOTIFY_LOG"
    ;;
esac

# logging message
echo "########## collected message - $(date '+%Y-%m-%d %H:%M:%S') ##########"
echo "$MESSAGE"

# send message
telegram_message

exit $RC_M