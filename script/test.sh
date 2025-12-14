#!/bin/bash
# test for all script with telegramm notify

#fail2ban
echo "Check fail2ban script, 3 message ban, unban and no arguments"
/usr/local/bin/ssh_ban_notify.sh ban   "111.111.111.111" "12345698765"
/usr/local/bin/ssh_ban_notify.sh unban "255.255.255.255" "98765432198"
/usr/local/bin/ssh_ban_notify.sh