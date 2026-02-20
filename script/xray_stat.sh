#!/bin/bash
# script for collecting xray traffic stat via cron every 10m
# all errors are logged in journald, see journalctl -t xray_stat
# */10 * * * * telegram_gateway /usr/local/bin/service/xray_stat.sh
# exit codes work to tell Cron about success

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# main variable
RC=1
TMP_TR_DB_COMMON="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
TMP_TR_DB_M_OLD="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
TMP_TR_DB_Y_OLD="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
TMP_TR_DB_M_NEW="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
TMP_TR_DB_Y_NEW="$(mktemp)" || { echo "Error: create temp file failed, exit" >&2; exit 1; }
readonly LOCK_FILE="/run/lock/xray_stat.lock"

# enable logging
exec > >(systemd-cat -t xray_stat -p info) 2> >(systemd-cat -t xray_stat -p err) 5> >(systemd-cat -t xray_stat -p notice)

# start logging message
echo "xray stat started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# user check
[[ "$(whoami)" != "telegram_gateway" ]] && { echo "Error: you are not the telegram_gateway user, exit" >&2; exit 1; }

# exit logging message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" -eq "0" ]]; then
        echo "xray stat ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "xray stat failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit rm tmp file function
# shellcheck disable=SC2329
rm_tmp_tr_db() {
    echo "cleaning start - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -f "$TMP_TR_DB_COMMON" "$TMP_TR_DB_M_OLD" "$TMP_TR_DB_Y_OLD" "$TMP_TR_DB_M_NEW" "$TMP_TR_DB_Y_NEW" > /dev/null; then
        echo "Success: delete tmp TR_DB file"
        echo "cleaning ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "Error: delete tmp TR_DB file" >&2
        echo "cleaning failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# trap for the end log message for the end log
trap 'end_log; rm_tmp_tr_db;' EXIT

# check another instanсe of the script is not running
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance is running, exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
run_lock_retry_check "tr_db"

# read and write conf check
read_and_write_check "$TR_DB_M"
read_and_write_check "$TR_DB_Y"

# helper func
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "Success: $action"
    else
        echo "Error: $action, exit" >&2
        exit 1
    fi
}

# function for get xray stat and reset
# shellcheck disable=SC2329
fresh_stat() { xray api statsquery --reset > "$1"; }

# function for statistic reset in json file
# shellcheck disable=SC2329
reset_stat_file() { printf '{"stat":[]}\n' > "$1"; }

# install new TR_DB with save original permission
# shellcheck disable=SC2329
install_new_tr_db() { cat "$1" > "$2"; }

# merge json stat old + new -> out
# shellcheck disable=SC2329
merge_old_new() {
jq -s '
    def to_int:
        if . == null then 0
        elif type=="number" then .
        elif type=="string" then (tonumber? // 0)
        else 0 end;

    def stat_map:
        reduce (.stat[]? | select(.name? != null)) as $i
            ({};
                .[$i.name] = (.[$i.name] // 0) + (($i.value // 0) | to_int)
            );

    .[0] as $old
    | .[1] as $new
    | ($old | stat_map) as $o
    | ($new | stat_map) as $n
    | ( reduce ((($o|keys_unsorted)+($n|keys_unsorted))|unique[]) as $k
        ({};
            .[$k] = ($o[$k]//0) + ($n[$k]//0)
        )
    ) as $m
    | {
        stat: (
            ($m|keys|sort)
            | map(
                . as $name
                | ($m[$name]) as $v
                | if $v == 0
            then {name:$name}
            else {name:$name, value:$v}
            end
            )
        )
    }
' "$1" "$2" >"$3"
}

# main logic start here
# get xray stat and reset
run_and_check "xray stat request and reset" fresh_stat "$TMP_TR_DB_COMMON"

# if empty set tmp stat to 0
if [[ ! -s "$TMP_TR_DB_COMMON" ]]; then
    echo "Error: new xray stat empty, exit" >&2
    exit 1
fi

# new JSON check valid, if not - save and exit
if ! jq empty "$TMP_TR_DB_COMMON" &> /dev/null; then
    cp -f "$TMP_TR_DB_COMMON" "${TR_DB_M}.bad_new_${TS}.json" 
    echo "Error: cannot parse xray new stats JSON; saved raw to ${TR_DB_M}.bad_new_${TS}.json, exit" >&2
    cp -f "$TMP_TR_DB_COMMON" "${TR_DB_Y}.bad_new_${TS}.json"
    echo "Error: cannot parse xray new stats JSON; saved raw to ${TR_DB_Y}.bad_new_${TS}.json, exit" >&2
    exit 1
fi

# if old M empty or not valid, start stat from 0
if [[ -s "$TR_DB_M" ]] && jq empty "$TR_DB_M" &> /dev/null; then
    run_and_check "copy old stat to tmp file" install_new_tr_db "$TR_DB_M" "$TMP_TR_DB_M_OLD"
else
    run_and_check "old stat not valid or empty, start stat from 0 in TR_DB_M" reset_stat_file "$TR_DB_M"
    run_and_check "old stat not valid or empty, set stat to 0 in TMP_TR_DB_M_OLD file" reset_stat_file "$TMP_TR_DB_M_OLD"
fi

# if old Y empty or not valid, start stat from 0
if [[ -s "$TR_DB_Y" ]] && jq empty "$TR_DB_Y" &> /dev/null; then
    run_and_check "copy old stat to tmp file" install_new_tr_db "$TR_DB_Y" "$TMP_TR_DB_Y_OLD"
else
    run_and_check "old stat not valid or empty, start stat from 0 in TR_DB_Y" reset_stat_file "$TR_DB_Y"
    run_and_check "old stat not valid or empty, set stat to 0 in TMP_TR_DB_Y_OLD file" reset_stat_file "$TMP_TR_DB_Y_OLD"
fi

run_and_check "merge TMP_TR_DB_M file" merge_old_new "$TMP_TR_DB_M_OLD" "$TMP_TR_DB_COMMON" "$TMP_TR_DB_M_NEW"
run_and_check "merge TMP_TR_DB_Y file" merge_old_new "$TMP_TR_DB_Y_OLD" "$TMP_TR_DB_COMMON" "$TMP_TR_DB_Y_NEW"

run_and_check "install new TR_DB_M file" install_new_tr_db "$TMP_TR_DB_M_NEW" "$TR_DB_M"
run_and_check "install new TR_DB_Y file" install_new_tr_db "$TMP_TR_DB_Y_NEW" "$TR_DB_Y"

RC=0
exit $RC