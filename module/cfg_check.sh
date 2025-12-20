# this file is intended to be connected via source, not run standalone
# done work
# done test

# config file read check
CFG_FILE="configuration.cfg"
if [[ ! -r "$CFG_FILE" ]]; then
    sleep 1
    echo "❌ Error: check '$CFG_FILE' it's missing or you don't have permission to read it, exit"
    exit 1
fi

# username check
SECOND_USER=$(awk -F'"' '/^[[:space:]]*Server administrator username/ {print $2}' "$CFG_FILE")
if [[ -z "$SECOND_USER" ]]; then
    sleep 1
    echo "❌ Error: 'Server administrator username' is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ "$SECOND_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,31}$ ]]; then
    sleep 1
    echo "✅ Success: username accepted"
else
    sleep 1
    echo "❌ Error: name '$SECOND_USER' does not comply with Linux rules, exit"
    exit 1
fi

# password check
PASS=$(awk -F'"' '/^[[:space:]]*Password for root and new user/ {print $2}' "$CFG_FILE")
if [[ -z "$PASS" ]]; then
    sleep 1
    echo "❌ Error: 'Password for root and new user' is empty in '$CFG_FILE', exit"
    exit 1
else
    sleep 1
    echo "✅ Success: password accepted"
fi

# check token
READ_BOT_TOKEN=$(awk -F'"' '/^[[:space:]]*Telegram bot token/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_BOT_TOKEN" ]]; then
    sleep 1
    echo "❌ Error: 'Telegram bot token' is empty in '$CFG_FILE', exit"
    exit 1
else
    sleep 1
    echo "✅ Success: Telegram bot token accepted"
fi

# check ID
READ_CHAT_ID=$(awk -F'"' '/^[[:space:]]*Telegram chat ID/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_CHAT_ID" ]]; then
    sleep 1
    echo "❌ Error: 'Telegram chat ID' is empty in '$CFG_FILE', exit"
    exit 1
else
    sleep 1
    echo "✅ Success: Telegram chat ID accepted"
fi

# check Ubuntu Pro token
UBUNTU_PRO_TOKEN=$(awk -F'"' '/^[[:space:]]*Ubuntu Pro token/ {print $2}' "$CFG_FILE")
if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
    sleep 1
    echo "⚠️  Non-critical error: 'Ubuntu Pro token' is empty in '$CFG_FILE', skip Ubuntu Pro section"
else
    sleep 1
    echo "✅ Success: Ubuntu Pro token accepted"
fi