# shellcheck disable=SC2148
# lock library, for checking running another instance working on file which we also need
# lock waiting for background script, lock whichout waiting for manually running script
# read and write check, checking permission on file
#
# for use run lock - run_lock_check "lock_name", run_lock_wait "lock_name" "time"
# for output with emoji - run_lock_check "lock_name" "console", run_lock_wait "lock_name" "time" "console"
#
# for use permission check - read_check "file", read_and_write_check "file"
# for output with emoji read_check "file" "console", read_and_write_check "file" "console"
# no external variable, only local
#
# for use xray status check - xray_status_check
# for emoji output - xray_status_check "console"

# check status xray for script who need xray api interaction
# we launch it after locking all files, so as not to exit 
# if another script is already running and is currently restarting xray.
xray_status_check() {
    local output_variant="$1"
    local error

    case "$output_variant" in
        console) error="❌ Error" ;;
              *) error="Error" ;;
    esac

    systemctl is-active -q xray || { echo "$error: Xray not running, exit" >&2; exit 1; }
}

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

    [[ ! -f "$file" ]] && { echo "$error: check '$file' is not a file, exit" >&2; exit 1; }
    [[ ! -r "$file" || ! -w "$file" ]] && { echo "$error: check '$file' it's missing or you do not have read or write permissions, exit" >&2; exit 1; }
}

# lock file with random file descriptor, no waiting, for check another instance already working 
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

# lock file with random file descriptor, adjusting waiting time, for shared file
run_lock_wait() {
    local lock="$1"
    local sec="$2"
    local output_variant="$3"

    local lock_file="/run/lock/${lock}.lock"
    local error fd info

    case "$output_variant" in
        console) error="❌ Error"; info="📢 Info" ;;
              *) error="Error"; info="Info" ;;
    esac

    exec {fd}< "$lock_file" || { echo "$error: cannot open lock file '$lock_file', exit" >&2; exit 1; }
    echo "$info: wait for lock '$lock_file'"
    flock -w "$sec" "$fd" || { echo "$error: after '$sec' seconds lock is not taken '$lock_file', exit" >&2; exit 1; }
    echo "$info: '$lock_file' locked, continue work"
}
