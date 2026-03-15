#!/bin/bash
# for pred install all lock file, before other script start
# run from systemd, exit code work to tell systemd about success creating files

# enable logging
exec > >(systemd-cat -t precreate_lockfiles -p info) 2> >(systemd-cat -t precreate_lockfiles -p err) 5> >(systemd-cat -t precreate_lockfiles -p notice)

# start logging message
echo "precreate_lockfiles started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "precreate lockfiles ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "precreate lockfiles failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log' EXIT

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# root checking
[[ $EUID -ne 0 ]] && { echo "Error: you are not the root user, exit" >&2; exit 1; }

# check another instanсe of the script is not running
LOCK_FILE="/run/lock/precreate_lockfiles.lock"
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# main logic start here
for lock in "${LOCK_FILES[@]}"; do
    # if exist, delete and install new, else just install
    if [[ -e "$lock" ]]; then
        rm -rf "$lock" || { echo "Error: cannot be deleted '$lock', exit" >&2; exit 1; }
        install -m "$LOCK_MODE" -o "$LOCK_OWNER" -g "$LOCK_GROUP" "/dev/null" "$lock" || \
        { echo "Error: cannot be installed '$lock', exit" >&2; exit 1; }
    else
        install -m "$LOCK_MODE" -o "$LOCK_OWNER" -g "$LOCK_GROUP" "/dev/null" "$lock" || \
        { echo "Error: cannot be installed '$lock', exit" >&2; exit 1; }
    fi
done

# if we here, all files installed, no error
RC=0

# exit with file creating status
exit $RC
