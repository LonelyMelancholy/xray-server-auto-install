#!/bin/bash

set -euo pipefail

ENV_FILE="/usr/local/etc/telegram/secrets.env"
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"

STATUS="${1:-success}"   # "success" | "failure"
HOST="$(hostname)"
DATE=$(date '+%Y-%m-%d %H:%M:%S')
OS="$(. /etc/os-release && echo "$PRETTY_NAME")"

TODAY="$(date +%Y-%m-%d)"
CHANGES="$(awk -v d="$TODAY" '
  $1==d && ($3=="upgrade" || $3=="install" || $3=="remove" || $3=="purge") {
    pkg=$4; sub(/:.*/,"",pkg);
    if ($3=="upgrade") printf "[↻] upgrade %s %s -> %s\n", pkg, $5, $6;
    else if ($3=="install") printf "[↑] install %s %s\n", pkg, $6;
    else if ($3=="remove" || $3=="purge") printf "[↓] %s %s %s\n", $3, pkg, $5;
  }' /var/log/dpkg.log 2>/dev/null || true)"

if [ -z "$CHANGES" ]; then
  CHANGE_SUMMARY="➖ No package changes"
else
  COUNT="$(printf "%s\n" "$CHANGES" | sed '/^$/d' | wc -l)"
  CHANGE_SUMMARY="➕ $COUNT package changed:
$CHANGES"
fi

[ "$STATUS" = "success" ] && TITLE="✅ Upgrade report" || TITLE="❌ Upgrade error"

MSG="$TITLE

🖥️ Host: $HOST
⌚ Time: $DATE
💾 OS: $OS
$CHANGE_SUMMARY
🗄 Logfile: /var/log/unattended-upgrades/unattended-upgrades.log"

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d text="$MSG"

exit 0