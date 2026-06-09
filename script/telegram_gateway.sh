#!/bin/bash

# main variables
readonly TIMEOUT=60
OFFSET=0

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t telegram_gateway -p info) 2> >(systemd-cat -t telegram_gateway -p err) 5> >(systemd-cat -t telegram_gateway -p notice)

# start logging message
echo "telegram gateway started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    echo "telegram gateway stopped - $(date '+%Y-%m-%d %H:%M:%S')" >&5
}
# trap for the end log message for the end log
trap 'end_log' EXIT

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "telegram_gateway"

# Track bot messages so we can delete old output/menu and keep only the latest.
# (Single admin chat assumed.)
declare -a BOT_MSG_IDS=()

# Bot state (single admin only)
STATE=""   # "", "WAIT_BLOCK", "WAIT_UNBLOCK", "WAIT_DELETE", "WAIT_ADD", "WAIT_EXP"
# pending action is implied by STATE

MAIN_KB_JSON='{
    "inline_keyboard":[
        [
            {"text":"🔎🖥️ Server information","callback_data":"SHOW_STAT"},
            {"text":"🗄️🖥️ Server backup","callback_data":"SEND_BACKUP"}  
        ],
        [
            {"text":"🔄🖥️ Server reboot","callback_data":"ASK_SERVER_REBOOT"},
            {"text":"🔄🌐 Xray restart","callback_data":"ASK_XRAY_RESTART"}
        ],
        [
            {"text":"🔎🧑🏿‍💻 Show all users","callback_data":"SHOW_ALL"},
            {"text":"🔎🧑🏿‍💻 Show user info","callback_data":"ASK_SHOW"}
        ],
        [
            {"text":"🔒🧑🏿‍💻 Block user","callback_data":"ASK_BLOCK"},
            {"text":"🔓🧑🏿‍💻 Unblock user","callback_data":"ASK_UNBLOCK"}
            
        ],
        [
            {"text":"➕🧑🏿‍💻 Add user","callback_data":"ASK_ADD"},
            {"text":"☠️🧑🏿‍💻 Delete user","callback_data":"ASK_DELETE"}
        ],
        [
            {"text":"⌚🧑🏿‍💻 Change user time","callback_data":"ASK_EXP"},
            {"text":"⌚🧑🏿‍💻 Reset user traffic","callback_data":"ASK_TR"}
        ]
    ]
}'

api_post() {
    local method="$1"; shift
    curl -sS --connect-timeout 10 --max-time 80 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@"
}

delete_message() {
  local chat_id="$1"
  local msg_id="$2"

  # ignore errors (no rights / too old / already deleted)
  api_post "deleteMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "message_id=${msg_id}" >/dev/null 2>&1 || true
}

cleanup_old_bot_messages() {
  local chat_id="$1"; shift
  local extra_ids=()  # optional IDs to delete even if not tracked
  [[ $# -gt 0 ]] && extra_ids=("$@")

  local mid
  for mid in "${BOT_MSG_IDS[@]}" "${extra_ids[@]}"; do
    [[ -n "${mid:-}" && "${mid}" != "null" ]] || continue
    delete_message "$chat_id" "$mid"
  done
  BOT_MSG_IDS=()
}

send_message() {
    local chat_id="$1"
    local raw_text="$2"
    local text
    text="$(printf '%b' "$raw_text")"
    local reply_markup="${3-}"
    local resp mid

  if [[ -n "${reply_markup}" ]]; then
    resp="$(api_post "sendMessage" \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${text}" \
      --data-urlencode "reply_markup=${reply_markup}")"
  else
    resp="$(api_post "sendMessage" \
      --data-urlencode "chat_id=${chat_id}" \
      --data-urlencode "text=${text}")"
  fi

  # remember message_id so we can delete it on the next action
  mid="$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null || true)"
  [[ -n "${mid}" ]] && BOT_MSG_IDS+=("$mid")
}

# show menu and welcome message
show_menu() {
    local chat_id="$1"
    send_message "$chat_id" "Server management bot menu, please choose command:\nHost: $(hostname)" "$MAIN_KB_JSON"
}

# Validate single argument
valid_arg() {
    local arg="$1"
    local var="$2"
    case "$var" in
        username)
            # 3..64 chars, only A-Z a-z 0-9 and '-_'
            [[ "$arg" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,62}[A-Za-z0-9]$ ]] || return 1
            return 0
        ;;
        number)
            # 1..10 numbers only positive 0-9
            [[ "$arg" =~ ^[0-9]{1,10}$ ]] || return 1
            return 0
        ;;
        answer)
            # yes,Yes,YES accept
            [[ "$arg" =~ ^[Yy][Ee][Ss]$ ]] || return 1
            return 0
        ;;
        *)
            return 1
        ;;
    esac
}

run_and_send_output() {
    local chat_id="$1"; shift
    local max=4000
    local tmp text body
    tmp="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
    # run, capture stdout+stderr
    "$@" >"$tmp" 2>&1

    # if file empty, set no output message
    if [[ -s "$tmp" ]]; then
        body="$(cat "$tmp")"
    else
        body="[no output]"
    fi

    # delete tmp after write text to variable
    rm -f "$tmp"
    
    # send as chunks
    text="$body"
    
    # while number of characters > max 
    while (( ${#text} > max )); do
        # send first 4000 characters
        send_message "$chat_id" "${text:0:max}"
        # delete first 4000 characters from variable
        text="${text:max}"
        # small pause to reduce rate-limit risk
        sleep 0.2
    done
    # send the rest (including empty)
    send_message "$chat_id" "$text"
}

handle_callback() {
    local upd="$1"

    local cb_id data chat_id
    cb_id="$(jq -r '.callback_query.id' <<<"$upd")"
    data="$(jq -r '.callback_query.data' <<<"$upd")"
    chat_id="$(jq -r '.callback_query.message.chat.id' <<<"$upd")"

    # Always answer callback to stop Telegram "loading"
    api_post "answerCallbackQuery" --data-urlencode "callback_query_id=${cb_id}" >/dev/null

    # if chat id not match, silent exit
    [[ "$chat_id" != "$CHAT_ID" ]] && return 0

    # Remove previous bot output/menu so only the latest stays in the chat.
    # Also try to delete the menu message that was clicked (helps after restarts).
    local clicked_msg_id
    clicked_msg_id="$(jq -r '.callback_query.message.message_id // empty' <<<"$upd")"
    cleanup_old_bot_messages "$chat_id" "$clicked_msg_id"

    case "$data" in
        SHOW_STAT)
            STATE=""
            run_and_send_output "$chat_id" echo "Wait 10 sec, network statistics accumulate process"
            run_and_send_output "$chat_id" /usr/local/bin/service/system_info.sh
            show_menu "$chat_id"
        ;;
        SEND_BACKUP)
            run_and_send_output "$chat_id" /usr/local/bin/service/xray_backup.sh "manual"
            show_menu "$chat_id"
        ;;
        SHOW_ALL)
            STATE=""
            run_and_send_output "$chat_id" /usr/local/bin/service/user_show.sh "all"
            show_menu "$chat_id"
        ;;
        ASK_SHOW)
            STATE="WAIT_SHOW"
            send_message "$chat_id" "Show user info.\nEnter username [or /cancel]:"
        ;;
        ASK_SERVER_REBOOT)
            STATE="WAIT_REBOOT"
            send_message "$chat_id" "Server reboot.\nEnter yes for confirmation [or /cancel]:"
        ;;
        ASK_XRAY_RESTART)
            STATE="WAIT_RESTART"
            send_message "$chat_id" "Xray restart.\nEnter yes for confirmation [or /cancel]:"
        ;;
        ASK_BLOCK)
            STATE="WAIT_BLOCK"
            send_message "$chat_id" "Blocking user.\nEnter username [or /cancel]:"
        ;;
        ASK_UNBLOCK)
            STATE="WAIT_UNBLOCK"
            send_message "$chat_id" "Unblocking user.\nEnter username [or /cancel]:"
        ;;
        ASK_DELETE)
            STATE="WAIT_DELETE"
            send_message "$chat_id" "Deleting user.\nEnter username [or /cancel]:"
        ;;
        ASK_ADD)
            STATE="WAIT_ADD"
            send_message "$chat_id" "Adding new user.\nEnter username and number of days, separated by a space [or /cancel]:"
        ;;
        ASK_EXP)
            STATE="WAIT_EXP"
            send_message "$chat_id" "Change user time.\nEnter username and number of days, separated by a space [or /cancel]:"
        ;;
        ASK_TR)
            STATE="WAIT_TR"
            send_message "$chat_id" "Reset user traffic.\nEnter username [or /cancel]:"
        ;;
        *)
            send_message "$chat_id" "Unknown button. Showing menu."
            show_menu "$chat_id"
        ;;
    esac
}

handle_message() {
    local upd="$1"

    local chat_id text user_msg_id
    chat_id="$(jq -r '.message.chat.id' <<<"$upd")"
    text="$(jq -r '.message.text // empty' <<<"$upd")"
    user_msg_id="$(jq -r '.message.message_id // empty' <<<"$upd")"

    # if chat id not match, silent exit
    [[ "$chat_id" != "$CHAT_ID" ]] && return 0

    # Keep chat clean:
    # - delete previous bot output/menu
    # - try to delete user's message (works in groups/supergroups if bot can delete)
    # IMPORTANT: do NOT delete /start (some Telegram clients will show the Start button again
    # if the /start message disappears, which creates an annoying loop).
    if [[ -n "${user_msg_id:-}" && "${user_msg_id}" != "null" ]]; then
        if [[ ! "$text" == "/start" ]]; then
            delete_message "$chat_id" "$user_msg_id"
        fi
    fi

    # Commands
    if [[ "$text" == "/start" || "$text" == "/help" ]]; then
        STATE=""
        show_menu "$chat_id"
        return
    fi

    if [[ "$text" == "/cancel" ]]; then
        STATE=""
        send_message "$chat_id" "Canceled."
        show_menu "$chat_id"
        return
    fi

    # If not waiting input, just show menu
    if [[ -z "$STATE" ]]; then
        show_menu "$chat_id"
        return
    fi

    # Normalize for 2-args inputs: newlines -> spaces, trim
    local norm
    norm="$(tr '\n' ' ' <<<"$text" | tr -s ' ' )"
    norm="${norm#"${norm%%[! ]*}"}"
    norm="${norm%"${norm##*[! ]}"}"

    case "$STATE" in
        WAIT_BLOCK|WAIT_UNBLOCK|WAIT_DELETE|WAIT_SHOW|WAIT_TR)
            local username action
            username="$norm"

            case "$STATE" in
                WAIT_BLOCK)
                    action="Blocking user."
                ;;
                WAIT_UNBLOCK)
                    action="Unblocking user."
                ;;
                WAIT_DELETE)
                    action="Deleting user."
                ;;
                WAIT_SHOW)
                    action="Show user info."
                ;;
                WAIT_TR)
                    action="Reset user traffic."
                ;;
            esac

            if ! valid_arg "$username" "username"; then
                send_message "$chat_id" "${action}\n❌ Error: username must be 3..64 characters long and contain only letters, numbers and '-' or '_', begin and end with a letter or number.\nEnter username [or /cancel]:"
                return
            fi

            case "$STATE" in
                WAIT_BLOCK)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/user_block.sh "$username" "block"
                    show_menu "$chat_id"
                ;;
                WAIT_UNBLOCK)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/user_block.sh "$username" "unblock"
                    show_menu "$chat_id"
                ;;
                WAIT_DELETE)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/user_delete.sh "$username"
                    show_menu "$chat_id"
                ;;
                WAIT_SHOW)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/user_info.sh "$username"
                    show_menu "$chat_id"
                ;;
                WAIT_TR)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/traffic_unblock.sh "$username"
                    show_menu "$chat_id"
                ;;
            esac
        ;;
        WAIT_REBOOT|WAIT_RESTART)
            local answer="$norm"
            
            case "$STATE" in
                WAIT_REBOOT)  action="Server reboot." ;;
                WAIT_RESTART) action="Xray restart." ;;
            esac

            if ! valid_arg "$answer" "answer"; then
                send_message "$chat_id" "${action}\n❌ Error: only yes [or /cancel] is valid input.\nEnter yes [or /cancel]:"
                return
            fi
            
            case "$STATE" in
            WAIT_REBOOT)
                STATE=""
                    run_and_send_output "$chat_id" echo "Server reboot started"
                    show_menu "$chat_id"
                    systemctl reboot || { run_and_send_output "$chat_id" echo "Server fail to reboot"; show_menu "$chat_id"; }
            ;;
            WAIT_RESTART)
                STATE=""
                    if systemctl restart xray.service; then
                        run_and_send_output "$chat_id" echo "Xray restarted"
                    else
                        run_and_send_output "$chat_id" echo "Xray fail to restart"
                    fi
                    show_menu "$chat_id"
            ;;
            esac
        ;;
        WAIT_ADD|WAIT_EXP)
            local a b action
            read -r a b _ <<<"$norm"

            case "$STATE" in
                WAIT_ADD) action="Adding new user." ;;
                WAIT_EXP) action="Adding time to user." ;;
            esac

            if [[ -z "${a:-}" || -z "${b:-}" ]]; then
                send_message "$chat_id" "${action}\n❌ Error: need 2 arguments.\nEnter username and number of days, separated by a space [or /cancel]:"
                return
            fi

            if ! valid_arg "$a" "username"; then
                send_message "$chat_id" "${action}\n❌ Error: username must be 3..64 characters long and contain only letters, numbers and '-' or '_', begin and end with a letter or number.\nEnter username and number of days, separated by a space [or /cancel]:"
                return
            fi

            if ! valid_arg "$b" "number"; then
                send_message "$chat_id" "${action}\n❌ Error: days must be non negative number, lenght 1-10 characters.\nEnter username and number of days, separated by a space [or /cancel]:"
                return
            fi

            case "$STATE" in
                WAIT_ADD)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/user_add.sh "$a" "$b"
                    show_menu "$chat_id"
                    ;;
                WAIT_EXP)
                    STATE=""
                    run_and_send_output "$chat_id" /usr/local/bin/service/time_unblock.sh "$a" "$b"
                    show_menu "$chat_id"
                    ;;
                esac
        ;;
        *)
            STATE=""
            show_menu "$chat_id"
        ;;
    esac
}

main_loop() {
    while true; do
        # Long polling
        local resp
        resp="$(curl -sS --connect-timeout 10 \
            --max-time 80 \
            --data-urlencode "timeout=${TIMEOUT}" \
            --data-urlencode "offset=${OFFSET}" \
            "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates")" || {
                sleep 1
                continue
            }

        local ok
        ok="$(jq -r '.ok' <<<"$resp" 2>/dev/null || echo "false")"
        [[ "$ok" == "true" ]] || { sleep 1; continue; }

        # Iterate updates in the same shell (avoid subshell OFFSET issues)
        while IFS= read -r upd; do
            local uid
            uid="$(jq -r '.update_id' <<<"$upd")"
            OFFSET=$((uid + 1))

            if jq -e '.callback_query' >/dev/null <<<"$upd"; then
                handle_callback "$upd"
            elif jq -e '.message' >/dev/null <<<"$upd"; then
                handle_message "$upd"
            fi
        done < <(jq -c '.result[]' <<<"$resp")
    done
}

main_loop
