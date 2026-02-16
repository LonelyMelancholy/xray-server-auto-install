# lock library, for checking running another instance working on file which we also need
# lock which retry for background script, lock whichout retry for manualy running script
# read and write check, checking permission on file
#
# for use run lock - run_lock_check "lock_name", run_lock_retry_check "lock_name"
# for output with emoji - run_lock_check "lock_name" console, run_lock_retry_check "lock_name" console
#
# for use permission check - read_check "file", read_and_write_check "file"
# for output with emoji read_check "file" console, read_and_write_check "file" console
# no external variable, only local, only one global array

# array for descriptor lock depending on name
declare -A LOCK_FDS=(
  [xray]=7
  [uri_db]=8
  [tr_db]=9
)

read_check() {
    local file="$1"
    local output_variant="$2"
    local error

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    [[ ! -f "$file" ]] && { echo "$error: check '$file' it's not file, exit" >&2; exit 1; }
    [[ ! -r "$file" ]] && { echo "$error: check '$file' it's missing or you do not have read permissions, exit" >&2; exit 1; }
}

read_and_write_check() {
    local file="$1"
    local output_variant="$2"
    local error

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    [[ ! -f "$file" ]] && { echo "$error: check '$file' it's not file, exit" >&2; exit 1; }
    [[ ! -r "$file" || ! -w "$file" ]] && { echo "$error: check '$file' it's missing or you do not have read or write permissions, exit" >&2; exit 1; }
}

run_lock_check() {
    local lock="$1"
    local output_variant="$2"
    local lock_file="/run/lock/${lock}.lock"
    local error
    local fd="${LOCK_FDS["$lock"]:-0}"

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    [[ $fd -eq 0 ]] && { echo "$error: wrong lock file, only xray, uri_db, tr_db, exit" >&2; exit 1; }
    
    exec "$fd"> "$lock_file" || { echo "$error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    flock -n "$fd" || { echo "$error: another instance working on '$lock', exit" >&2; exit 1; }
}

run_lock_retry_check() {
    local lock="$1"
    local output_variant="$2"
    local lock_file="/run/lock/${lock}.lock"
    local error info
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local attempt
    local max_attempt=3
    local fd="${LOCK_FDS["$lock"]:-0}"

    case "$output_variant" in
        console) error="❌ Error"; info="📢 Info" ;;
              *) error="Error"; info="Info" ;;
    esac

    [[ $fd -eq 0 ]] && { echo "$error: wrong lock file, only xray, uri_db, tr_db, exit" >&2; exit 1; }

    exec "$fd"> "$lock_file" || { echo "$error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    for ((attempt=1; attempt<=max_attempt; attempt++)); do
        if flock -n "$fd"; then
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            echo "$info: Lock busy '$lock'. Waiting ${wait_sec}s... attempt ${attempt}/${max_attempt}"
            sleep "$wait_sec"
        else
            echo "$error: lock '$lock' is still busy after $max_attempt attempts, exit" >&2
            exit 1
        fi
    done
}