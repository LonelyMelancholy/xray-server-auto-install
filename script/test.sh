#!/bin/bash

# test for all script with telegramm notify
echo "Test script for test all messages, 1 sec pause"

# fail2ban
echo "Check fail2ban script, 3 message ban, unban and no arguments"
/usr/local/bin/telegram/ssh_ban_notify.sh ban   "111.111.111.111" "12345698765"
sleep 1
/usr/local/bin/telegram/ssh_ban_notify.sh unban "255.255.255.255" "98765432198"
sleep 1
/usr/local/bin/telegram/ssh_ban_notify.sh
sleep 1

# ssh enter
echo "Check ssh enter script login, unlogin and no arguments"
env PAM_USER="testuser" PAM_RHOST="255.255.255.255" PAM_TYPE="open_session" /usr/local/bin/telegram/ssh_enter_notify.sh
sleep 1
env PAM_USER="testuser" PAM_RHOST="111.111.111.111" PAM_TYPE="close_session" /usr/local/bin/telegram/ssh_enter_notify.sh
sleep 1
env PAM_USER="testuser" PAM_RHOST="111.111.111.111" PAM_TYPE="no" /usr/local/bin/telegram/ssh_enter_notify.sh
sleep 1

# traffic notify
echo "Traffic notify, one time, server must be running"
/usr/local/bin/telegram/traffic_notify.sh
sleep 1

#

