# telegram sender message, if call telegram_message function, function send text in $MESSAGE variable
# if sending failed, RC_M not changed, if sending success RC_M=0
# RC_M - message sender return code
# telegram sender file, if call telegram_file function, function send file in $FILE_PATH with name $FILE_NAME
# if sending failed, RC_F not changed, if sending success RC_F=0
# RC_F - file sender return code
# external variable - $MESSAGE, $FILE_PATH, $FILE_NAME, $RC_M, $RC_F.
# external file /usr/local/etc/telegram/secrets.env [root:telegram-gateway 640] with $BOT_TOKEN and $GROUP_ID

# check secret file, if the file have right permissions, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%G:%a' "$ENV_FILE" 2> /dev/null)" != "root:telegram-gateway:640" ]]; then
    echo "Error: env file '$ENV_FILE' not found or has wrong permissions, exit" >&2
    exit 1
fi
source "$ENV_FILE" || { echo "Error: failed to source '$ENV_FILE', exit" >&2; exit 1; }

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "Error: Telegram bot token is missing in '$ENV_FILE', exit" >&2; exit 1; }

# check group id from secret file
[[ -z "$GROUP_ID" ]] && { echo "Error: Telegram group ID is missing in '$ENV_FILE', exit" >&2; exit 1; }

# pure Telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${GROUP_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${MESSAGE}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram message with final result logging and retry on failure
telegram_message() {
    local attempt=1
    local max_attempt=3
    local wait_sec=60
    while true; do
        if ! _tg_m; then
            if [[ "$attempt" -ge "$max_attempt" ]]; then
                echo "Error: failed to send Telegram message after $attempt attempts, exit" >&2
                exit 1
            fi
            echo "Info: failed to send Telegram message. Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep $wait_sec
            ((attempt++))
            continue
        else
            echo "Success: message was sent to Telegram after $attempt attempt"
            RC_M=0
            return 0
        fi
    done
}

# pure Telegram send file function with checking the sending status
_tg_f() {
    local response
    response="$(curl -fsS -m 60 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
            -F "chat_id=${GROUP_ID}" \
            -F "document=@${FILE_PATH};filename=${FILE_NAME}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram send file with final result logging and retry on failure
telegram_file() {
    local attempt=1
    local max_attempt=3
    local wait_sec=60
    while true; do
        if ! _tg_f; then
            if [[ "$attempt" -ge "$max_attempt" ]]; then
                echo "Error: failed to send Telegram file after $attempt attempt, exit" >&2
                return 1
            fi
            echo "Info: failed to send Telegram file. Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep $wait_sec
            ((attempt++))
            continue
        else
            echo "Success: file was sent to Telegram after $attempt attempt"
            RC_F=0
            return 0
        fi
    done
}