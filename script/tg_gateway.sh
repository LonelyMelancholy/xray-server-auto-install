#!/bin/bash
set -u

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# check secret file, file already source it via systemd
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%a' "$ENV_FILE" 2> /dev/null)" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in '$ENV_FILE', exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in '$ENV_FILE', exit"; exit 1; }

API="https://api.telegram.org/bot${BOT_TOKEN}"
TIMEOUT=50
OFFSET=0
readonly HOSTNAME="$(hostname)"

# Track bot messages so we can delete old output/menu and keep only the latest.
# (Single admin chat assumed.)
declare -a BOT_MSG_IDS=()

# Bot state (single admin only)
STATE=""   # "", "WAIT_BLOCK", "WAIT_UNBLOCK", "WAIT_DELETE", "WAIT_ADD", "WAIT_EXP"
# pending action is implied by STATE

MAIN_KB_JSON='{
    "inline_keyboard":[
        [
            {"text":"Server information","callback_data":"SHOW_STAT"},
            {"text":"Server backup","callback_data":"SEND_BACKUP"}  
        ],
        [
            {"text":"Server reboot","callback_data":"ASK_SERVER_REBOOT"},
            {"text":"Xray restart","callback_data":"ASK_XRAY_RESTART"}
        ],
        [
            {"text":"🔎 Show users links","callback_data":"SHOW_LINK"},
            {"text":"🔎 Show users info","callback_data":"SHOW_ALL"}
        ],
        [
            {"text":"🔒 Block user","callback_data":"ASK_BLOCK"},
            {"text":"🔓 Unblock user","callback_data":"ASK_UNBLOCK"}
            
        ],
        [
            {"text":"🧑🏿‍💻 Add new user","callback_data":"ASK_ADD"},
            {"text":"☠️ Delete user","callback_data":"ASK_DELETE"}
        ],
        [
            {"text":"⌚ Add time expired user","callback_data":"ASK_EXP"}
        ]
    ]
}'

api_post() {
  local method="$1"; shift
  curl -sS --max-time 70 -X POST "${API}/${method}" "$@"
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
  if (( $# > 0 )); then
    extra_ids=("$@")
  fi

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

send_chunks_4000() {
  local chat_id="$1"
  local text="$2"
  local max=4000

  # Telegram hard limit is 4096; we use 4000 as requested
  while (( ${#text} > max )); do
    send_message "$chat_id" "${text:0:max}"
    text="${text:max}"
    # small pause to reduce rate-limit risk
    sleep 0.15
  done
  # send the rest (including empty)
  send_message "$chat_id" "$text"
}

answer_callback() {
  local cb_id="$1"
  api_post "answerCallbackQuery" \
    --data-urlencode "callback_query_id=${cb_id}" >/dev/null
}

show_menu() {
  local chat_id="$1"
  send_message "$chat_id" "Menu $HOSTNAME management bot.\nPlease choose command:" "$MAIN_KB_JSON"
}

is_admin_chat() {
  local chat_id="$1"
  [[ "$chat_id" == "$CHAT_ID" ]]
}

# Validate single argument: 1..30 chars, only A-Z a-z 0-9 and '-'
valid_arg() {
  local s="$1"
  [[ ${#s} -ge 1 && ${#s} -le 30 && "$s" =~ ^[A-Za-z0-9-]+$ ]]
}

valid_arg_answer() {
    local s="$1"
    [[ "$s" == "yes" ]]
}

valid_arg_num() {
  local s="$1"
  [[ ${#s} -ge 1 && ${#s} -le 10 && "$s" =~ ^[0-9]+$ ]]
}

run_and_send_output() {
  local chat_id="$1"; shift

  local tmp
  tmp="$(mktemp)"
  # run, capture stdout+stderr
    local cmd=( sudo -n -- "$@" )
    "${cmd[@]}" >"$tmp" 2>&1
    local rc=$?

    local cmd_str
    cmd_str="$(printf "%q " "${cmd[@]}")"
    cmd_str="${cmd_str% }"

    local body
    if [[ -s "$tmp" ]]; then
        body="$(cat "$tmp")"
    else
        body="(no output)"
    fi

    rm -f "$tmp"
    # send as chunks
    send_chunks_4000 "$chat_id" "$(printf "%s" "$body")"
}

prompt_one() {
  local chat_id="$1"
  local action_text="$2"
  send_message "$chat_id" "${action_text}\nEnter username (or /cancel):"
}

prompt_two() {
  local chat_id="$1"
  local action_text="$2"
  send_message "$chat_id" "${action_text}\nEnter username and number of days, separated by a space or line break (or /cancel):"
}

handle_callback() {
  local upd="$1"

  local cb_id data chat_id
  cb_id="$(jq -r '.callback_query.id' <<<"$upd")"
  data="$(jq -r '.callback_query.data' <<<"$upd")"
  chat_id="$(jq -r '.callback_query.message.chat.id' <<<"$upd")"

  # Always answer callback to stop Telegram "loading"
  answer_callback "$cb_id"

  if ! is_admin_chat "$chat_id"; then
    # silently ignore (or you can notify)
    return
  fi

  # Remove previous bot output/menu so only the latest stays in the chat.
  # Also try to delete the menu message that was clicked (helps after restarts).
  local clicked_msg_id
  clicked_msg_id="$(jq -r '.callback_query.message.message_id // empty' <<<"$upd")"
  cleanup_old_bot_messages "$chat_id" "$clicked_msg_id"

    case "$data" in
        SHOW_STAT)
            STATE=""
            run_and_send_output "$chat_id" echo "Wait 10 sec, network statistic accumulate process"
            run_and_send_output "$chat_id" /usr/local/bin/service/system_info.sh
            show_menu "$chat_id"
            ;;
        SEND_BACKUP)
            run_and_send_output "$chat_id" /usr/local/bin/service/xray_backup.sh
            show_menu "$chat_id"
            ;;
        SHOW_LINK)
            STATE=""
            run_and_send_output "$chat_id" /usr/local/bin/service/usershow.sh links
            show_menu "$chat_id"
            ;;
        SHOW_ALL)
            STATE=""
            run_and_send_output "$chat_id" /usr/local/bin/service/usershow.sh all
            show_menu "$chat_id"
            ;;

        ASK_SERVER_REBOOT)
            STATE="WAIT_REBOOT"
            prompt_one "$chat_id" "Server reboot."
        ;;
        ASK_XRAY_RESTART)
            STATE="WAIT_RESTART"
            prompt_one "$chat_id" "Xray restart."
        ;;
        ASK_BLOCK)
            STATE="WAIT_BLOCK"
            prompt_one "$chat_id" "Blocking user."
            ;;
        ASK_UNBLOCK)
            STATE="WAIT_UNBLOCK"
            prompt_one "$chat_id" "Unblocking user."
            ;;
        ASK_DELETE)
            STATE="WAIT_DELETE"
            prompt_one "$chat_id" "Deleting user."
            ;;
        ASK_ADD)
            STATE="WAIT_ADD"
            prompt_two "$chat_id" "Adding new user."
            ;;
        ASK_EXP)
            STATE="WAIT_EXP"
            prompt_two "$chat_id" "Adding time to user."
            ;;
        *)
            send_message "$chat_id" "Unknown button. Showing menu." "$MAIN_KB_JSON"
            ;;
    esac
}

handle_message() {
  local upd="$1"

  local chat_id text user_msg_id
  chat_id="$(jq -r '.message.chat.id' <<<"$upd")"
  text="$(jq -r '.message.text // empty' <<<"$upd")"
  user_msg_id="$(jq -r '.message.message_id // empty' <<<"$upd")"

  if ! is_admin_chat "$chat_id"; then
    # Optional: tell unknown chat it is private
    # send_message "$chat_id" "Unauthorized."
    return
  fi

  # Keep chat clean:
  # - delete previous bot output/menu
  # - try to delete user's message (works in groups/supergroups if bot can delete)
  cleanup_old_bot_messages "$chat_id"
  [[ -n "${user_msg_id:-}" && "${user_msg_id}" != "null" ]] && delete_message "$chat_id" "$user_msg_id"

  # Commands
  if [[ "$text" == "/start" || "$text" == "/help" ]]; then
    local first last who
    first="$(jq -r '.message.from.first_name // empty' <<<"$upd")"
    last="$(jq -r '.message.from.last_name // empty' <<<"$upd")"

    who="${first} ${last}"
    who="$(tr -s ' ' <<<"$who")"
    who="${who#"${who%%[! ]*}"}"
    who="${who%"${who##*[! ]}"}"
    [[ -z "$who" ]] && who="User"

    STATE=""
    send_message "$chat_id" "Hello ${who}\nWelcome to $HOSTNAME management bot.\nPlease choose command:" "$MAIN_KB_JSON"
    return
  fi

  if [[ "$text" == "/cancel" ]]; then
    STATE=""
    send_message "$chat_id" "Canceled." "$MAIN_KB_JSON"
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
        WAIT_BLOCK|WAIT_UNBLOCK|WAIT_DELETE)
            local username action
            username="$norm"

        case "$STATE" in
            WAIT_BLOCK)   action="Blocking user." ;;
            WAIT_UNBLOCK) action="Unblocking user." ;;
            WAIT_DELETE)  action="Deleting user." ;;
        esac

        if ! valid_arg "$username"; then
            send_message "$chat_id" "❌ Error: username must be 1..30 characters long and contain only '-', letters, and numbers.\n${action}\nEnter username (or /cancel):"
            return
        fi

        case "$STATE" in
            WAIT_BLOCK)
                STATE=""
                run_and_send_output "$chat_id" /usr/local/bin/service/userblock.sh "$username" block
                show_menu "$chat_id"
                ;;
            WAIT_UNBLOCK)
                STATE=""
                run_and_send_output "$chat_id" /usr/local/bin/service/userblock.sh "$username" unblock
                show_menu "$chat_id"
                ;;
            WAIT_DELETE)
                STATE=""
                run_and_send_output "$chat_id" /usr/local/bin/service/userdel.sh "$username"
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

        if ! valid_arg_answer "$answer"; then
            send_message "$chat_id" "❌ Error: only yes or /cancel is valid input.\n${action}\nEnter yes or /cancel:"
            return
        fi
        
        case "$STATE" in
        WAIT_REBOOT)
            STATE=""
            run_and_send_output "$chat_id" echo "Server reboot started"
            show_menu "$chat_id"
            run_and_send_output "$chat_id" reboot
            ;;
        WAIT_RESTART)
            STATE=""
            run_and_send_output "$chat_id" systemctl restart xray.service && \
            run_and_send_output "$chat_id" echo "Xray restarted" || \
            run_and_send_output "$chat_id" echo "Xray fail to restart"
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
                send_message "$chat_id" "❌ Error: need 2 argument. Format: username number.\n${action}\nEnter username and number of days, separated by a space or line break (or /cancel):"
                return
            fi

            if ! valid_arg "$a"; then
                send_message "$chat_id" "❌ Error: username must be 1..30 characters long and contain only '-', letters, and numbers.\n${action}\nEnter username and number of days, separated by a space or line break (or /cancel):"
                return
            fi

            if ! valid_arg_num "$b"; then
                send_message "$chat_id" "❌ Error: number must be 1..10 characters long and contain only numbers.\n${action}\nEnter username and number of days, separated by a space or line break (or /cancel):"
                return
            fi

        case "$STATE" in
            WAIT_ADD)
                STATE=""
                run_and_send_output "$chat_id" /usr/local/bin/service/useradd.sh "$a" "$b"
                show_menu "$chat_id"
                ;;
            WAIT_EXP)
                STATE=""
                run_and_send_output "$chat_id" /usr/local/bin/service/userexp.sh "$a" "$b"
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
    resp="$(curl -sS --max-time 70 \
      --data-urlencode "timeout=${TIMEOUT}" \
      --data-urlencode "offset=${OFFSET}" \
      "${API}/getUpdates")" || {
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