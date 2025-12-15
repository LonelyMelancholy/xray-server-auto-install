#!/bin/bash
# test for all script with telegramm notify

# fail2ban
echo "Check fail2ban script, 3 message ban, unban and no arguments"
/usr/local/bin/telegram/ssh_ban_notify.sh ban   "111.111.111.111" "12345698765"
/usr/local/bin/telegram/ssh_ban_notify.sh unban "255.255.255.255" "98765432198"
/usr/local/bin/telegram/ssh_ban_notify.sh

# ssh enter
echo "Check ssh enter script login, unlogin and no arguments"
env PAM_USER="testuser" PAM_RHOST="255.255.255.255" PAM_TYPE="open_session" /usr/local/bin/telegram/ssh_enter_notify.sh
env PAM_USER="testuser" PAM_RHOST="111.111.111.111" PAM_TYPE="close_session" /usr/local/bin/telegram/ssh_enter_notify.sh
env PAM_USER="testuser" PAM_RHOST="111.111.111.111" PAM_TYPE="no" /usr/local/bin/telegram/ssh_enter_notify.sh

