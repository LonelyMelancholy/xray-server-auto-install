# lock library, for checking running another instance working on file which we also need
# lock which retry for background script, lock whichout retry for manualy running script
# read and write check, checking permission on file
# USECASE
# for use run lock - run_lock_check "lock_name", run_lock_retry_check "lock_name"
# for use permission check - read_check "file", read_and_write_check "file"
# no external variable, only local

read_check() {
    local file="$1"
    [[ ! -r "$file" ]] && { echo "Error: check '$file' it's missing or you do not have read permissions, exit" >&2; exit 1; }
}

read_and_write_check() {
    local file="$1"
    [[ ! -r "$file" || ! -w "$file" ]] && { echo "Error: check '$file' it's missing or you do not have read or write permissions, exit" >&2; exit 1; }
}

run_lock_check() {
    local lock_file="/run/lock/${1}.lock"
    exec 8> "$lock_file" || { echo "Error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    flock -n 8 || { echo "Error: another instance working on xray config, exit" >&2; exit 1; }
}

run_lock_retry_check() {
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local max_attempt=3
    local lock_file="/run/lock/${1}.lock"
    exec 8> "$lock_file" || { echo "Error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    for ((attempt=1; attempt<=max_attempt; attempt++)); do
        if flock -n 8; then
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            echo "Info: Lock busy ($lock_file). Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep "$wait_sec"
        else
            echo "Error: lock ($lock_file) is still busy after $max_attempt attempts, exit" >&2
            exit 1
        fi
    done
}