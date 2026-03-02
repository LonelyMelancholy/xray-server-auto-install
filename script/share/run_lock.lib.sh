# shellcheck disable=SC2148
# lock library, for checking running another instance working on file which we also need
# lock which retry for background script, lock whichout retry for manualy running script
# read and write check, checking permission on file
#
# for use run lock - run_lock_check "lock_name", run_lock_retry_check "lock_name"
# for output with emoji - run_lock_check "lock_name" console, run_lock_retry_check "lock_name" console
#
# for use permission check - read_check "file", read_and_write_check "file"
# for output with emoji read_check "file" console, read_and_write_check "file" console
# no external variable, only local

# checking read file rights and its existence
read_check() {
    local file="$1"
    local output_variant="$2"
    local error

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    [[ ! -f "$file" ]] && { echo "$error: check '$file' missing or not a file, exit" >&2; exit 1; }
    [[ ! -r "$file" ]] && { echo "$error: check '$file' missing or you do not have read permissions, exit" >&2; exit 1; }
}

# checking read and write file rights and its existence
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

# lock file with random file descriptor, no waiting
run_lock_check() {
    local lock="$1"
    local output_variant="$2"
    local lock_file="/run/lock/${lock}.lock"
    local error fd

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    exec {fd}< "$lock_file" || { echo "$error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    flock -n "$fd" || { echo "$error: another instance working on '$lock', exit" >&2; exit 1; }
}

# lock file with random file descriptor, waiting random time 10-60sec, 3 times try
run_lock_retry_check() {
    local lock="$1"
    local output_variant="$2"
    local lock_file="/run/lock/${lock}.lock"
    local error info fd
    # shellcheck disable=SC2155
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local attempt
    local max_attempt=3

    case "$output_variant" in
        console) error="❌ Error"; info="📢 Info" ;;
              *) error="Error"; info="Info" ;;
    esac

    exec {fd}< "$lock_file" || { echo "$error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
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