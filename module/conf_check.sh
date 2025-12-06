# Config file read check
CFG_FILE="configuration.cfg"
if [ ! -r "$CFG_FILE" ]; then
    echo "❌ Error: check $CFG_FILE it's missing or you not have right to read"
    exit 1
fi

# Username check
SECOND_USER=$(awk -F'"' '/^Server administrator username/ {print $2}' "$CFG_FILE")

if [[ -z "$SECOND_USER" ]]; then
    echo "❌ Error: 'Server administrator username' is empty in $CFG_FILE"
    exit 1
fi

if [[ "$SECOND_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#SECOND_USER} -le 32 ]]; then
    echo "✅ Name '$SECOND_USER' accepted"
else
    echo "❌ Error: name '$SECOND_USER' does not comply with Linux rules"
    exit 1
fi

#Password check
PASS=$(awk -F'"' '/^Password for root and new user/ {print $2}' "$CFG_FILE")

if [[ -z "$PASS" ]]; then
    echo "❌ Error: 'Password for root and new user' is empty in $CFG_FILE"
    exit 1
else
    echo "✅ Password accepted"
    trap 'unset -v PASS' EXIT
fi

# Check token
READ_BOT_TOKEN=$(awk -F'"' '/^Telegram Bot Token/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_BOT_TOKEN" ]]; then
    echo "❌ Error: 'Telegram Bot Token' is empty in $CFG_FILE"
    exit 1
else
    echo "✅ Bot token accepted"
fi

# Check id
READ_CHAT_ID=$(awk -F'"' '/^Telegram Chat id/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_CHAT_ID" ]]; then
    echo "❌ Error: 'Telegram Chat id' is empty in $CFG_FILE"
    exit 1
else
    echo "✅ Chat id accepted"
fi

# Check Ubuntu Pro Token
UBUNTU_PRO_TOKEN=$(awk -F'"' '/^Ubuntu Pro Token/ {print $2}' "$CFG_FILE")
if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
    echo "⚠️ Warning: 'Ubuntu Pro Token' is empty in $CFG_FILE, skip ubuntu pro section"
else
    echo "✅ Ubuntu Pro Token accepted"
fi