# lock library, for checking running another instance working on file which we also need
# lock which retry for background script, lock whichout retry for manualy running script
# for use just call xray_lock, uri_db_lock, tr_db_lock, xray_lock_retry, uri_db_lock_retry, tr_db_lock_retry
# no external variable

xray_lock() {
    local lock_file="/run/lock/xray_config.lock"
    exec 8> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    flock -n 8 || { echo "❌ Error: another instance working on xray config, exit"; exit 1; }
}

uri_db_lock() {
    local lock_file="/run/lock/uri_db.lock"
    exec 9> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    flock -n 9 || { echo "❌ Error: another instance working on URI_DB, exit"; exit 1; }
}

tr_db_lock() {
    local lock_file="/run/lock/tr_db.lock"
    exec 10> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    flock -n 10 || { echo "❌ Error: another instance working on TR_DB, exit"; exit 1; }
}

xray_lock_retry() {
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local max_attempt="3"
    local lock_file="/run/lock/xray_config.lock"
    exec 8> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    for ((attempt=1; attempt<=max_attempt; attempt++)); do
        if flock -n 8; then
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            echo "⚠️  Non-critical error: Lock busy ($lock_file). Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep "$wait_sec"
        else
            echo "❌ Error: lock ($lock_file) is still busy after $max_attempt attempts, exit"
            exit 1
        fi
    done
}

uri_db_lock_retry() {
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local max_attempt="3"
    local lock_file="/run/lock/uri_db.lock"
    exec 9> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    for ((attempt=1; attempt<=max_attempt; attempt++)); do
        if flock -n 9; then
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            echo "⚠️  Non-critical error: Lock busy ($lock_file). Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep "$wait_sec"
        else
            echo "❌ Error: lock ($lock_file) is still busy after $max_attempt attempts, exit"
            exit 1
        fi
    done
}

tr_db_lock_retry() {
    local wait_sec="$(shuf -i "10-60" -n 1)"
    local max_attempt="3"
    local lock_file="/run/lock/tr_db.lock"
    exec 10> "$lock_file" || { echo "❌ Error: cannot open lock file '$lock_file', exit"; exit 1; }
    for ((attempt=1; attempt<=max_attempt; attempt++)); do
        if flock -n 10; then
            break
        fi
        if [ "$attempt" -lt "$max_attempt" ]; then
            echo "⚠️  Non-critical error: Lock busy ($lock_file). Waiting ${wait_sec}s... (attempt $attempt/$max_attempt)"
            sleep "$wait_sec"
        else
            echo "❌ Error: lock ($lock_file) is still busy after $max_attempt attempts, exit"
            exit 1
        fi
    done
}