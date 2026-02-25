#!/bin/bash
# script for notify ssh login/unlogin via PAM
# exit 0 to avoid bothering PAM with an incorrect error code
# all errors are logged in journald, see journalctl -t ssh_pam_notify

# main variables
RC_M="1"
readonly TARGET_USER="telegram_gateway"
readonly IP="$PAM_RHOST"
readonly USER="$PAM_USER"
readonly SESSION="$PAM_TYPE"

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# sends the script to the background from telegram_gateway, without delaying pam and send exit 0 to pam
if [[ -z "${TG_BG:-}" ]]; then
    export TG_BG=1
    if [[ "$(whoami)" != "$TARGET_USER" ]]; then
        /usr/bin/setpriv \
        --reuid="$TARGET_USER" \
        --regid="$TARGET_USER" \
        --init-groups \
        --inh-caps=-all \
        -- "$0" "$@" &
    else
        "$0" "$@" &
    fi
    exit 0
fi

# enable logging
exec > >(systemd-cat -t ssh_pam_notify -p info) 2> >(systemd-cat -t ssh_pam_notify -p err) 5> >(systemd-cat -t ssh_pam_notify -p notice)

# start logging message
echo "ssh pam notify started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC_M" -eq "0" ]]; then
        echo "ssh pam notify ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "ssh pam notify failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# user check
[[ "$(whoami)" != "$TARGET_USER" ]] && { echo "Error: you are not the $TARGET_USER user, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# main logic start here
# start collecting message parts
case "$SESSION" in
    open_session)
        MESSAGE_TITLE="📢 <b>SSH PAM notify (login)</b>"
        MESSAGE_ACTION="🧑🏿‍💻 <b>User:</b> $USER"$'\n'"🏴 <b>From:</b> $IP"
    ;;
    close_session)
        MESSAGE_TITLE="📢 <b>SSH PAM notify (logout)</b>"
        MESSAGE_ACTION="🧑🏿‍💻 <b>User:</b> $USER"$'\n'"🏴 <b>From:</b> $IP"
    ;;
    *)
        MESSAGE_TITLE="⚠️ <b>SSH PAM notify (unknown)</b>"
        MESSAGE_ACTION="❌ Error: unknown PAM session type, check settings"
    ;;
esac

# collecting full message
MESSAGE="${MESSAGE_TITLE}

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
${MESSAGE_ACTION}
💾 <b>Auth log:</b> /var/log/auth.log
💾 <b>Notify log:</b> journalctl -t ssh_pam_notify"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message

exit $RC_M
