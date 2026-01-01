# this file is intended to be connected via source, not run standalone

# config file read check
CFG_FILE="configuration.cfg"
if [[ ! -r "$CFG_FILE" ]]; then
    echo "❌ Error: check '$CFG_FILE' it's missing or you don't have permission to read it, exit"
    exit 1
fi

# username check
SECOND_USER=$(awk -F'"' '/^[[:space:]]*Server administrator username/ {print $2}' "$CFG_FILE")
if [[ -z "$SECOND_USER" ]]; then
    echo "❌ Error: 'Server administrator username' is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ "$SECOND_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
    echo "✅ Success: server administrator username accepted"
else
    echo "❌ Error: 'Server administrator username' '$SECOND_USER' does not comply with Linux rules, exit"
    exit 1
fi

# password check
PASS=$(awk -F'"' '/^[[:space:]]*Password for root and new user/ {print $2}' "$CFG_FILE")
if [[ -z "$PASS" ]]; then
    echo "❌ Error: 'Password for root and new user' is empty in '$CFG_FILE', exit"
    exit 1
else
    echo "✅ Success: password accepted"
fi

# check token
READ_BOT_TOKEN=$(awk -F'"' '/^[[:space:]]*Telegram bot token/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_BOT_TOKEN" ]]; then
    echo "❌ Error: 'Telegram bot token' is empty in '$CFG_FILE', exit"
    exit 1
else
    echo "✅ Success: Telegram bot token accepted"
fi

# check ID
READ_CHAT_ID=$(awk -F'"' '/^[[:space:]]*Telegram chat ID/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_CHAT_ID" ]]; then
    echo "❌ Error: 'Telegram chat ID' is empty in '$CFG_FILE', exit"
    exit 1
else
    echo "✅ Success: Telegram chat ID accepted"
fi

# check Ubuntu Pro token
UBUNTU_PRO_TOKEN=$(awk -F'"' '/^[[:space:]]*Ubuntu Pro token/ {print $2}' "$CFG_FILE")
if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
    echo "⚠️  Non-critical error: 'Ubuntu Pro token' is empty in '$CFG_FILE', skip Ubuntu Pro section"
else
    echo "✅ Success: Ubuntu Pro token accepted"
fi

# check dest
XRAY_HOST=$(awk -F'"' '/^[[:space:]]*Dest/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_HOST" ]]; then
    echo "❌ Error: 'Dest' is empty in '$CFG_FILE', exit"
    exit 1
else
    echo "✅ Success: dest for xray accepted"
fi

# check name
XRAY_NAME=$(awk -F'"' '/^[[:space:]]*Name/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_NAME" ]]; then
    echo "❌ Error: 'Name' for xrayis empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ ! $XRAY_NAME =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "❌ Error: 'Name' for xray can have only letters, numbers and - in name, exit"
    exit 1
else
    echo "✅ Success: name for xray accepted"
fi

# check days
XRAY_DAYS=$(awk -F'"' '/^[[:space:]]*Days/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_DAYS" ]]; then
    echo "❌ Error: 'Days' is empty in '$CFG_FILE', exit"
    exit 1
else
    echo "✅ Success: days for xray accepted"
fi