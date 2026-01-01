#!/bin/bash
# script for collecting xray traffic stat via cron every hour
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 0 * * * * root /usr/local/bin/service/userstat.sh &> /dev/null
# exit codes work to tell Cron about success

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# root check
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# enable logging, the directory should already be created, but let's check just in case
readonly DATE_LOG="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly NOTIFY_LOG="${LOG_DIR}/userstat.${DATE_LOG}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$NOTIFY_LOG" || { echo "❌ Error: cannot write to log '$NOTIFY_LOG', exit"; exit 1; }

# exit logging message function
RC="1"
on_exit() {
    if [[ "$RC" -eq "0" ]]; then
        local DATE_END="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## user stat ended - $DATE_END ##########"
    else
        local DATE_FAIL="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "########## user stat failed - $DATE_FAIL ##########"
    fi
}

# trap for the end log message for the end log
trap 'on_exit' EXIT

# check another instanse of the script is not running
readonly LOCK_FILE="/var/run/userstat.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# helper func
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
        return 0
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}

# main variable
readonly OUT_FILE="/var/log/xray/TR_DB"
tmp_new="$(mktemp)"
tmp_old="$(mktemp)"
tmp_out="$(mktemp)"
trap 'on_exit; rm -f "$tmp_new" "$tmp_old" "$tmp_out";' EXIT

# get stat and reset
fresh_stat() {
    xray api statsquery --reset > "$tmp_new"
}
run_and_check "xray stat request and reset" fresh_stat

# if empty start stat from 0
if [[ ! -s "$tmp_new" ]]; then
    printf '{"stat":[]}\n' > "$tmp_new"
fi

# new JSON check valid, if not save and exit
if ! jq -e . &> /dev/null < "$tmp_new"; then
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -f "$tmp_new" "${OUT_FILE}.bad_new_${ts}.json"
    echo "❌ Error: cannot parse xray new stats JSON; saved raw to ${OUT_FILE}.bad_new_${ts}.json"
    exit 1
fi

# if old empty or not valid, start stat from 0
if [[ -s "$OUT_FILE" ]] && jq -e . &> /dev/null < "$OUT_FILE"; then
  cp -f "$OUT_FILE" "$tmp_old"
else
  printf '{"stat":[]}\n' >"$tmp_old"
fi

# merge old + new -> tmp_out
merge_old_new() {
    set -e
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
' "$tmp_old" "$tmp_new" >"$tmp_out"
}

run_and_check "start merge tmp file" merge_old_new

# install new TR_DB
run_and_check "install new TR_DB file" install -m 644 -o root -g root "$tmp_out" "$OUT_FILE"

RC=0