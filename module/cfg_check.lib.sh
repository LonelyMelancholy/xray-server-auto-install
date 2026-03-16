# shellcheck disable=SC2148
# configuration file checking library

# config file read check
CFG_FILE="configuration.cfg"
if [[ ! -r "$CFG_FILE" || ! -f "$CFG_FILE" ]]; then
    echo "❌ Error: check '$CFG_FILE' it's missing or you don't have permission to read it, exit"
    exit 1
fi

# hostname check
XRAY_HOSTNAME=$(awk -F'"' '/^[[:space:]]*Server hostname/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_HOSTNAME" ]]; then
    echo "❌ Error: 'Server hostname' is empty in '$CFG_FILE', exit"
    exit 1
fi

# check unnecessary technical symbols and spaces
if [[ "$XRAY_HOSTNAME" =~ [[:space:]] || "$XRAY_HOSTNAME" == *"://"* || "$XRAY_HOSTNAME" == */* ]]; then
    echo "❌ Error: 'Server hostname' must contain only domain without protocol, spaces or path, exit"
    exit 1
fi

# check lengh
if [[ ${#XRAY_HOSTNAME} -gt 64 ]]; then
    echo "❌ Error: 'Server hostname' is too long, max length is 64 characters, exit"
    exit 1
fi

# domen validation
if [[ ! "$XRAY_HOSTNAME" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    echo "❌ Error: 'Server hostname' must be valid domain, exit"
    exit 1
else
    echo "✅ Success: 'Server hostname' accepted"
fi

# password check
PASS=$(awk -F'"' '/^[[:space:]]*Password for root and new user/ {print $2}' "$CFG_FILE")
if [[ -z "$PASS" ]]; then
    echo "❌ Error: 'Password for root and new user' is empty in '$CFG_FILE', exit"
    exit 1
fi

# check lengh
if [[ ${#PASS} -lt 8 || ${#PASS} -gt 512 ]]; then
    echo "❌ Error: 'Password for root and new user' must be at least 8 characters long, exit"
    exit 1
fi

# check spaces in password
if [[ "$PASS" =~ [[:space:]] ]]; then
    echo "❌ Error: 'Password for root and new user' must not contain spaces or tabs, exit"
    exit 1
else
    echo "✅ Success: 'Password for root and new user' accepted"
fi

# check token
READ_BOT_TOKEN=$(awk -F'"' '/^[[:space:]]*Telegram bot token/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_BOT_TOKEN" ]]; then
    echo "❌ Error: 'Telegram bot token' is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ ! "$READ_BOT_TOKEN" =~ ^[0-9]{8,10}:[A-Za-z0-9_-]{35,}$ ]]; then
    echo "❌ Error: 'Telegram bot token' has invalid format, expected like 123456789:AA... , exit"
    exit 1
else
    echo "✅ Success: 'Telegram bot token' accepted"
fi

# check ID
READ_CHAT_ID=$(awk -F'"' '/^[[:space:]]*Telegram chat ID/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_CHAT_ID" ]]; then
    echo "❌ Error: 'Telegram chat ID' is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ ! "$READ_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
    echo "❌ Error: 'Telegram chat ID' must contain only numbers and optional leading -, exit"
    exit 1
else
    echo "✅ Success: 'Telegram chat ID' accepted"
fi

# check group ID
READ_GROUP_ID=$(awk -F'"' '/^[[:space:]]*Telegram chat group ID/ {print $2}' "$CFG_FILE")
if [[ -z "$READ_GROUP_ID" ]]; then
    echo "❌ Error: 'Telegram group ID' is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ ! "$READ_GROUP_ID" =~ ^-[0-9]+$ ]]; then
    echo "❌ Error: 'Telegram group ID' must be negative numeric ID like -100..., exit"
    exit 1
else
    echo "✅ Success: 'Telegram group ID' accepted"
fi

# check Ubuntu Pro token
UBUNTU_PRO_TOKEN=$(awk -F'"' '/^[[:space:]]*Ubuntu Pro token/ {print $2}' "$CFG_FILE")
if [[ -z "$UBUNTU_PRO_TOKEN" ]]; then
    echo "📢 Info: 'Ubuntu Pro token' is empty in '$CFG_FILE', skip Ubuntu Pro section"
else
    if [[ "$UBUNTU_PRO_TOKEN" =~ [[:space:]] ]]; then
        echo "❌ Error: 'Ubuntu Pro token' must not contain spaces or tabs, exit"
        exit 1
    fi

    if [[ ! "$UBUNTU_PRO_TOKEN" =~ ^[A-Za-z0-9-]+$ ]]; then
        echo "❌ Error: 'Ubuntu Pro token' must contain only letters, numbers and -, exit"
        exit 1
    fi

    if [[ ${#UBUNTU_PRO_TOKEN} -lt 24 ]]; then
        echo "❌ Error: 'Ubuntu Pro token' looks too short, exit"
        exit 1
    else
        echo "✅ Success: 'Ubuntu Pro token' accepted"
    fi
fi

# check email
OWNER_EMAIL=$(awk -F'"' '/^[[:space:]]*Owner server email/ {print $2}' "$CFG_FILE")
if [[ -z "$OWNER_EMAIL" ]]; then
    echo "❌ Error: 'Owner server email' for certificates empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ "$OWNER_EMAIL" =~ [[:space:]] ]]; then
    echo "❌ Error: 'Owner server email' must not contain spaces or tabs, exit"
    exit 1
fi

if [[ ! "$OWNER_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "❌ Error: 'Owner server email' has invalid format, exit"
    exit 1
else
    echo "✅ Success: 'Owner server email' for certificates accepted"
fi

# check name
XRAY_NAME=$(awk -F'"' '/^[[:space:]]*Name/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_NAME" ]]; then
    echo "❌ Error: 'Name' for xray is empty in '$CFG_FILE', exit"
    exit 1
fi

if ! [[ $XRAY_NAME =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    echo "❌ Error: 'Name' for xray can contain only letters, numbers, '-' and '_', length 1-64 characters, exit"
    exit 1
fi

if [[ "$XRAY_NAME" =~ ^[-_]|[-_]$ ]]; then
    echo "❌ Error: 'Name' for xray must not start or end with '-' or '_', exit"
    exit 1
else
    echo "✅ Success: 'Name' for xray accepted"
fi

# check days
XRAY_DAYS=$(awk -F'"' '/^[[:space:]]*Days/ {print $2}' "$CFG_FILE")
if [[ -z "$XRAY_DAYS" ]]; then
    echo "❌ Error: 'Days' for xray is empty in '$CFG_FILE', exit"
    exit 1
fi

if [[ ! $XRAY_DAYS =~ ^[0-9]{1,10}$ ]]; then
    echo "❌ Error: 'Days' for xray can have only non negative numbers, lengh 1-10 characters, exit"
    exit 1
else
    echo "✅ Success: 'Days' for xray accepted"
fi
