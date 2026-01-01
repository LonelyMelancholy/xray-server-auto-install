#!/bin/bash

# test for all script with telegramm notify
echo "Test script for test all messages, 1 sec pause"

# fail2ban
echo "Check ssh f2b notify script, 3 message - ban, unban and no arguments"
/usr/local/bin/telegram/ssh_f2b_notify.sh ban   "111.111.111.111" "12345698765"
sleep 1
/usr/local/bin/telegram/ssh_f2b_notify.sh unban "255.255.255.255" "98765432198"
sleep 1
/usr/local/bin/telegram/ssh_f2b_notify.sh
sleep 1

# ssh notify
echo "Check ssh pam notify script, 3 message - login, unlogin and no arguments"
env PAM_USER="testuser" PAM_RHOST="255.255.255.255" PAM_TYPE="open_session" /usr/local/bin/telegram/ssh_pam_notify.sh
sleep 1
env PAM_USER="testuser" PAM_RHOST="111.111.111.111" PAM_TYPE="close_session" /usr/local/bin/telegram/ssh_pam_notify.sh
sleep 1
env PAM_TYPE="no" /usr/local/bin/telegram/ssh_pam_notify.sh
sleep 1

# user daily notify
echo "Daily user report, one time, server must be running"
/usr/local/bin/telegram/user_notify.sh
sleep 1

# boot notify
echo "Test boot notify, one time, all service must be running"
systemctl start boot_notify.service
sleep 1

# unatended upgrade
#echo "Test unattended upgrade"
#/usr/local/bin/telegram/unattended_upgrade.sh
#sleep 1

# geodat update








