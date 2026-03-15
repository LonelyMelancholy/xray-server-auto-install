# shellcheck disable=SC2148
# telegram sender message, function send text, use telegram_message "text"
# if sending failed, RC_M not changed, if sending success RC_M=0
# RC_M - message sender return code
# telegram sender file, function send file, use telegram_file "file_path" "file_name"
# if sending failed, RC_F not changed, if sending success RC_F=0
# RC_F - file sender return code
# external variable - $RC_M, $RC_F.
# external file /usr/local/etc/telegram/secrets.env [root:telegram_gateway 640] with $BOT_TOKEN, $CHAT_ID and $GROUP_ID

# check secret file, if the file have right permissions, we source it.
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%G:%a' "$ENV_FILE" 2> /dev/null)" != "root:telegram_gateway:640" ]]; then
    echo "Error: env file '$ENV_FILE' not found or has wrong permissions, exit" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE" || { echo "Error: failed to source '$ENV_FILE', exit" >&2; exit 1; }

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "Error: Telegram bot token is missing in '$ENV_FILE', exit" >&2; exit 1; }

# check group id from secret file
[[ -z "$GROUP_ID" ]] && { echo "Error: Telegram group ID is missing in '$ENV_FILE', exit" >&2; exit 1; }

# check group id from secret file
[[ -z "$CHAT_ID" ]] && { echo "Error: Telegram chat ID is missing in '$ENV_FILE', exit" >&2; exit 1; }

# pure Telegram message function with checking the sending status
_tg_m() {
    local text="$1"
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${GROUP_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${text}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram message with final result logging and retry on failure
telegram_message() {
    local text="$1"
    local attempt=1
    local max_attempts=10
    local wait_sec=60
    while true; do
        if ! _tg_m "$text" ; then
            if [[ "$attempt" -ge "$max_attempts" ]]; then
                echo "Error: failed to send Telegram message after $attempt attempts, exit" >&2
                return 1
            fi
            echo "Info: failed to send Telegram message. Waiting ${wait_sec}s... attempt ${attempt}/${max_attempts}"
            sleep $wait_sec
            ((attempt++))
            continue
        else
            echo "Success: message was sent to Telegram after $attempt attempt"
            # shellcheck disable=SC2034
            RC_M=0
            return 0
        fi
    done
}

# pure Telegram send file function with checking the sending status
_tg_f() {
    local file_path="$1"
    local file_name="$2"
    local response
    response="$(curl -fsS -m 60 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
            -F "chat_id=${GROUP_ID}" \
            -F "document=@${file_path};filename=${file_name}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram send file with final result logging and retry on failure
telegram_file() {
    local file_path="$1"
    local file_name="$2"
    local attempt=1
    local max_attempts=10
    local wait_sec=60
    while true; do
        if ! _tg_f "$file_path" "$file_name"; then
            if [[ "$attempt" -ge "$max_attempts" ]]; then
                echo "Error: failed to send Telegram file after $attempt attempt, exit" >&2
                return 1
            fi
            echo "Info: failed to send Telegram file. Waiting ${wait_sec}s... attempt ${attempt}/${max_attempts}"
            sleep $wait_sec
            ((attempt++))
            continue
        else
            echo "Success: file was sent to Telegram after $attempt attempt"
            # shellcheck disable=SC2034
            RC_F=0
            return 0
        fi
    done
}
