#!/bin/bash
# auto install xray update and send notify via cron every first day month, 2:01 night time
# all errors are logged, except the first three, for debugging, add a redirect to the debug log
# 1 2 1 * * root /usr/local/bin/service/xray_update.sh &> /dev/null
# exit codes work to tell Cron about success

# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging, the directory should already be created, but let's check just in case
readonly DATE="$(date +"%Y-%m-%d")"
readonly LOG_DIR="/var/log/service"
readonly UPDATE_LOG="${LOG_DIR}/xray_update.${DATE}.log"
mkdir -p "$LOG_DIR" || { echo "❌ Error: cannot create log dir '$LOG_DIR', exit"; exit 1; }
exec &>> "$UPDATE_LOG" || { echo "❌ Error: cannot write to log '$UPDATE_LOG', exit"; exit 1; }

# start logging message
readonly DATE_START="$(date "+%Y-%m-%d %H:%M:%S")"
echo "   ########## xray update started - $DATE_START ##########   "

# exit log message function
on_exit() {
    if [[ "$RC" = "0" ]]; then
        local date_end=$(date "+%Y-%m-%d %H:%M:%S")
        echo "   ########## xray update ended - $date_end ##########   "
    else
        local date_fail="$(date "+%Y-%m-%d %H:%M:%S")"
        echo "   ########## xray update failed - $date_fail ##########   "
    fi
}

# error exit log message for end log
trap 'on_exit' EXIT
RC=1

# check another instanсe of the script is not running
readonly LOCK_FILE="/var/run/xray_update.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }

# main variables
readonly ASSET_DIR="/usr/local/share/xray"
readonly XRAY_DIR="/usr/local/bin"
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
readonly XRAY_URL="https://github.com/XTLS/xray-core/releases/latest/download/xray-linux-64.zip"
readonly HOSTNAME="$(hostname)"
readonly MAX_ATTEMPTS=3
STAGE="0"

cleanup_old_backups_and_logs() {
    FAIL_TD=0
    cleanup_old() {
        local dir="$1"
        local pattern="$2"
        local keep="$3"
        local name="$4"
        local has_old=0
        local f
        local glob="${dir}/${pattern}"

        if ! compgen -G "$glob" > /dev/null; then
            STATUS_OLD_BACKUP_DEL+="⚫ old ${name} missing, skipping deletion"$'\n'
            return
        fi

        for f in "$dir"/$pattern; do
            [[ -n "$keep" && "$f" == "$keep" ]] && continue

            has_old=1
            echo "📢 Info: stage ${STAGE}, deleting old ${name} $f"
            if rm -f -- "$f"; then
                echo "✅ Success: stage ${STAGE}, old ${name} $f deleted"
                STATUS_OLD_BACKUP_DEL+="⚫ old ${name} deletion success"$'\n'
            else
                echo "⚠️  Non-critical error: stage ${STAGE}, failed to delete old ${name} $f"
                STATUS_OLD_BACKUP_DEL+="⚠️ old ${name} deletion failed"$'\n'
                FAIL_TD=1
            fi
        done

        if (( has_old == 0 )); then
            STATUS_OLD_BACKUP_DEL+="⚫ old ${name} missing, skipping deletion"$'\n'
        fi
    }

    cleanup_old "$XRAY_DIR"      "xray.*.bak"         "$XRAY_DIR/xray.${DATE}.bak"          "xray backup"
    cleanup_old "$ASSET_DIR"     "geoip.dat.*.bak"    "$ASSET_DIR/geoip.dat.${DATE}.bak"    "geoip.dat backup"
    cleanup_old "$ASSET_DIR"     "geosite.dat.*.bak"  "$ASSET_DIR/geosite.dat.${DATE}.bak"  "geosite.dat backup"
    cleanup_old "$LOG_DIR"       "xray_update.*.log"  "$LOG_DIR/xray_update.${DATE}.log"    "xray update log backup"
}

# check secret file
readonly ENV_FILE="/usr/local/etc/telegram/secrets.env"
if [[ ! -f "$ENV_FILE" ]] || [[ "$(stat -L -c '%U:%a' "$ENV_FILE")" != "root:600" ]]; then
    echo "❌ Error: env file '$ENV_FILE' not found or has wrong permissions, exit"
    exit 1
fi
source "$ENV_FILE"

# check token from secret file
[[ -z "$BOT_TOKEN" ]] && { echo "❌ Error: Telegram bot token is missing in $ENV_FILE, exit"; exit 1; }

# check id from secret file
[[ -z "$CHAT_ID" ]] && { echo "❌ Error: Telegram chat ID is missing in $ENV_FILE, exit"; exit 1; }

# pure telegram message function with checking the sending status
_tg_m() {
    local response
    response="$(curl -fsS -m 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${MESSAGE}")" || return 1
    grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "$response" || return 1
    return 0
}

# Telegram message with logging and retry
telegram_message() {
    local attempt=1
    while true; do
        if ! _tg_m; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "❌ Error: failed to send telegram message after $attempt attempts, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: message was sent to telegram after $attempt attempts"
            return 0
        fi
    done
}

# exit cleanup and log message function
exit_cleanup() {
    local date_del_start=$(date "+%Y-%m-%d %H:%M:%S")
    echo "########## cleanup started - $date_del_start ##########"
    if rm -rf "$TMP_DIR"; then
        echo "✅ Success: temporary directory $TMP_DIR was deleted"
        local date_del_success=$(date "+%Y-%m-%d %H:%M:%S")
        echo "########## cleanup ended - $date_del_success ##########"
    else
        echo "❌ Error: temporary directory $TMP_DIR was not deleted"
        local date_del_error=$(date "+%Y-%m-%d %H:%M:%S")
        echo "########## cleanup failed - $date_del_error ##########"
        MESSAGE="❌ <b>Scheduled cleanup after xray update</b>
🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time error:</b> $date_del_error
❌ <b>Error:</b> temporary directory $TMP_DIR for xray update was not deleted"
        telegram_message
        trap - EXIT
        exit 1
    fi
}

# create working directory
TMP_DIR="$(mktemp -d)" || { echo "❌ Error: failed to create temporary directory, exit"; exit 1; }
readonly TMP_DIR

# rewrite trap exit, now error exit log message for end log and cleanup temp directory
trap 'on_exit; exit_cleanup' EXIT

# download function
_dl() { curl -fsSL --max-time 60 "$1" -o "$2"; }

_dl_with_retry() {
    local url="$1"
    local outfile="$2"
    local label="$3"
    local attempt=1

    while true; do
        if ! _dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "❌ Error: stage ${STAGE}, failed to download ${label} after ${attempt} attempts, exit"
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "✅ Success: stage ${STAGE}, successful download ${label} after ${attempt} attempts"
            return 0
        fi
    done
}

# download and check checksum function
download_and_verify() {
    local url="$1"
    local outfile="$2"
    local name="$3"
    local sha256sum_file="${outfile}.sha256sum"
    local dgst_file="${outfile}.dgst"
    local expected_sha actual_sha
    UNPACK_DIR="$TMP_DIR/xray-unpacked"

    # increase stage count
    STAGE=$((STAGE+1))

    # download main file
    _dl_with_retry "$url" "$outfile" "$name" || return 1

    # increase stage count
    STAGE=$((STAGE+1))

    # download checksum depending on the name there are two ways
    # download .dgst checksum if name xray
    if [ "$name" = "xray" ]; then
        _dl_with_retry "${url}.dgst" "$dgst_file" "${name}.dgst" || return 1
    # download checksum if other name (geoip.dat, geosite.dat)
    else
        _dl_with_retry "${url}.sha256sum" "$sha256sum_file" "${name}.sha256sum" || return 1
    fi

# increase stage count
    STAGE=$((STAGE+1))

# extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
# reset sha
    expected_sha=""
# extract sha256sum from .dgst if name xray
        if [ "$name" = "xray" ]; then
            expected_sha="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
            if [ -z "$expected_sha" ]; then
                echo "❌ Error: stage ${STAGE}, failed to parse SHA256 from ${dgst_file}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful parse SHA256 from ${dgst_file}"
            fi
# extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha" ]; then
                echo "❌ Error: stage ${STAGE}, failed to parse SHA256 from ${sha256sum_file}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful parse SHA256 from ${sha256sum_file}"
            fi
        fi

# increase stage count
    STAGE=$((STAGE+1))

# extract actual sha256sum from .zip or .dat
# reset sha
        actual_sha=""
            actual_sha="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha" ]; then
                echo "❌ Error: stage ${STAGE}, failed to extract SHA256 from ${outfile}, exit"
                return 1
            else
                echo "✅ Success: stage ${STAGE}, successful extraction SHA256 from ${outfile}"
            fi

# increase stage count
    STAGE=$((STAGE+1))

    local expected_label actual_label
    # compare sha256sum checksum depending on the name there are two ways
    # compare sha256sum checksum if name xray
    if [ "$name" = "xray" ]; then
        expected_label=".dgst"
        actual_label=".zip"
    # compare sha256sum checksum if other name (geoip.dat, geosite.dat)
    else
        expected_label=".sha256sum"
        actual_label=".dat"
    fi

    if [ "$expected_sha" != "$actual_sha" ]; then
        echo "📢 Info: stage ${STAGE}, expected SHA256 from ${expected_label}: $expected_sha"
        echo "📢 Info: stage ${STAGE}, actual SHA256 from ${actual_label}: $actual_sha"
        echo "❌ Error: stage ${STAGE}, failed to compare, actual and expected SHA256 do not match for ${name}, exit"
        return 1
    else
        echo "📢 Info: stage ${STAGE}, expected SHA256 from ${expected_label}: $expected_sha"
        echo "📢 Info: stage ${STAGE}, actual SHA256 from ${actual_label}: $actual_sha"
        echo "✅ Success: stage ${STAGE}, actual and expected SHA256 match for ${name}"
    fi

# unzip archive if name xray
    if [ "$name" = "xray" ]; then
# increase stage count
        STAGE=$((STAGE+1))
# unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            echo "❌ Error: stage ${STAGE}, failed to create directory for unpacking ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, the directory for unpacking ${outfile} has been created"
        fi
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" >/dev/null 2>&1; then
            echo "❌ Error: stage ${STAGE}, failed to extract ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, ${outfile} successfully extracted"
        fi
# check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            echo "❌ Error: stage ${STAGE}, xray binary is missing from folder after unpacking ${outfile}, exit"
            return 1
        else
            echo "✅ Success: stage ${STAGE}, xray binary exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
}

# function for start xray and check status
_xray_start_on_fail() {
    if systemctl start xray.service > /dev/null 2>&1; then
        echo "✅ Success: stage ${STAGE}, xray.service started, try updating again later, exit"
    else
        echo "❌ Critical Error: stage ${STAGE}, xray.service does not start, exit"
    fi
}

_backup_old_file() {
    local backup_src="$1"
    local backup_dest="$2"
    local label="$3"
    if cp -p "$backup_src" "$backup_dest"; then
        echo "✅ Success: stage ${STAGE}, ${label} backup completed"
    else
        echo "❌ Error: stage ${STAGE}, ${label} backup failed, exit"
        return 1
    fi
}

_install() {
    local install_mode="$1"
    local install_src="$2"
    local install_dest="$3"
    local name="$4"

        if install -m "$install_mode" "$install_src" "$install_dest"; then
            echo "✅ Success: stage ${STAGE}, $name installed"
        else
            echo "❌ Error: stage ${STAGE}, $name not installed, trying rollback"
            if ! cp -p "${install_dest}.${DATE}.bak" "$install_dest"; then
                echo "❌ Error: stage ${STAGE}, $name rollback failed"
            else
                echo "✅ Success: stage ${STAGE}, $name rolled back successfully"
            fi
            _xray_start_on_fail
            return 1
        fi
}

install_xray() {
    XRAY_NEW_VER=""
    XRAY_OLD_VER=""

# increase stage count
    STAGE=$((STAGE+1))
# check xray version
    if [ -x "$UNPACK_DIR/xray" ]; then
        XRAY_NEW_VER="$("$UNPACK_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        echo "❌ Error: stage ${STAGE}, unknown new xray version, exit"
        return 1
    fi

    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_OLD_VER="$("$XRAY_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
        echo "❌ Error: stage ${STAGE}, unknown old xray version, exit"
        return 1
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" = "$XRAY_OLD_VER" ]; then
        echo "📢 Info: stage ${STAGE}, xray already up to date $XRAY_NEW_VER, skip xray update"
        XRAY_UP_TO_DATE=1
    else
        echo "📢 Info: stage ${STAGE}, current xray version is $XRAY_OLD_VER, latest is $XRAY_NEW_VER, preparing to update"
        XRAY_UP_TO_DATE=0
    fi

# increase stage count
    STAGE=$((STAGE+1))
# old file backup
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        _backup_old_file "$XRAY_DIR/xray" "$XRAY_DIR/xray.${DATE}.bak" "xray bin" || return 1
    else
        echo "📢 Info: stage ${STAGE}, xray already up to date, backup not needed"
    fi

    _backup_old_file "$ASSET_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat.${DATE}.bak"   "geoip.dat"   || return 1
    _backup_old_file "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.${DATE}.bak" "geosite.dat" || return 1

# increase stage count
    STAGE=$((STAGE+1))
# stop xray service
    if systemctl stop xray.service > /dev/null 2>&1; then
        echo "✅ Success: stage ${STAGE}, xray.service stopped, starting the update"
    else
        echo "❌ Error: stage ${STAGE}, failed to stop xray.service, cancelling update"
        echo "📢 Info: stage ${STAGE}, checking status xray.service"
        if systemctl is-active --quiet xray.service; then
            echo "✅ Success: stage ${STAGE}, xray.service is running, try updating again later, exit"
            return 1
        else
            echo "❌ Error: stage ${STAGE}, xray.service is not running, trying to start"
            _xray_start_on_fail
            return 1
        fi 
    fi

    # increase stage count
    STAGE=$((STAGE+1))
    # install bin and geo*.dat
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        _install "755" "${UNPACK_DIR}/xray"      "${XRAY_DIR}/xray"         "xray binary" || return 1
    else
        echo "📢 Info: stage ${STAGE}, xray binary installation skipped"
    fi

    _install "644" "${TMP_DIR}/geoip.dat"    "${ASSET_DIR}/geoip.dat"    "geoip.dat" || return 1
    _install "644" "${TMP_DIR}/geosite.dat"  "${ASSET_DIR}/geosite.dat"  "geosite.dat" || return 1


    # increase stage count
    STAGE=$((STAGE+1))
    # start xray
    if systemctl start xray.service > /dev/null 2>&1; then
        echo "✅ Success: stage ${STAGE}, xray.service updated and started"
    else
        echo "❌ Critical Error: stage ${STAGE}, xray.service does not start"
        return 1
    fi

    return 0
}

# main logic start here
# call the function to clear old logs before starting work
cleanup_old_backups_and_logs
# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray"; then
    XRAY_DOWNLOAD=0
    STATUS_XRAY_MESSAGE="❌ xray download failed"
else
    STATUS_XRAY_MESSAGE="⚫ xray binary download success"
    XRAY_DOWNLOAD=1
fi

# update geoip if xray success
if [ "$XRAY_DOWNLOAD" = "1" ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat"; then
        GEOIP_DOWNLOAD=0
        STATUS_GEOIP_MESSAGE="❌ geoip.dat download failed"
    else
        STATUS_GEOIP_MESSAGE="⚫ xray geoip.dat download success"
        GEOIP_DOWNLOAD=1
    fi
else
    GEOIP_DOWNLOAD=0
    STATUS_GEOIP_MESSAGE="⚠️ geoip.dat download skip"
fi

# update geosite if geoip success
if [ "$XRAY_DOWNLOAD" = "1" ] && [ "$GEOIP_DOWNLOAD" = "1" ]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOSITE_DOWNLOAD=0
        STATUS_GEOSITE_MESSAGE="❌ geosite.dat download failed"
    else
        STATUS_GEOSITE_MESSAGE="⚫ xray geosite.dat download success"
        GEOSITE_DOWNLOAD=1
    fi
else
    GEOSITE_DOWNLOAD=0
    STATUS_GEOSITE_MESSAGE="⚠️ geosite.dat download skip"
fi

if [ "$XRAY_DOWNLOAD" = "1" ] && [ "$GEOIP_DOWNLOAD" = "1" ] && [ "$GEOSITE_DOWNLOAD" = "1" ]; then
    if ! install_xray; then
        STATUS_INSTALL_MESSAGE="❌ xray and geo*.dat install failed"
        XRAY_INSTALL=0
    else
        if [ "$XRAY_UP_TO_DATE" = "1" ]; then
            STATUS_INSTALL_MESSAGE="⚫ geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="⚫ xray already up to date $XRAY_OLD_VER"
            XRAY_INSTALL=1
        else
            STATUS_INSTALL_MESSAGE="⚫ xray and geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="⚫ xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
            XRAY_INSTALL=1
        fi
    fi
else
    XRAY_INSTALL=0
    STATUS_INSTALL_MESSAGE="⚠️ xray and geo*.dat install skip"
fi

# check final xray status
if systemctl is-active --quiet xray.service; then
    STATUS_XRAY="⚫ Success: xray.service is running"
else
    STATUS_XRAY="❌ Critical Error: xray.service does not start"
fi

DATE_END=$(date "+%Y-%m-%d %H:%M:%S")

# select a title for the telegram message
if [ "$XRAY_DOWNLOAD" = "1" ] && [ "$GEOIP_DOWNLOAD" = "1" ] && [ "$GEOSITE_DOWNLOAD" = "1" ] && [ "$XRAY_INSTALL" = "1" ]; then
    if [ "$FAIL_TD" = "0" ]; then
        MESSAGE_TITLE="<b>✅ Scheduled xray update</b>"
        RC=0
    else
        MESSAGE_TITLE="<b>⚠️ Scheduled xray update</b>"
        RC=0
    fi
else
    MESSAGE_TITLE="<b>❌ Scheduled xray update</b>"
    RC=1
fi

# collecting report for telegram message
MESSAGE="$MESSAGE_TITLE

🖥️ <b>Host:</b> $HOSTNAME
⌚ <b>Time start:</b> $DATE_START
⌚ <b>Time end:</b> $DATE_END
${STATUS_OLD_BACKUP_DEL}${STATUS_XRAY_MESSAGE}
${STATUS_GEOIP_MESSAGE}
${STATUS_GEOSITE_MESSAGE}
${STATUS_INSTALL_MESSAGE}
${STATUS_XRAY}
💾 <b>Update log:</b> ${UPDATE_LOG}"

telegram_message

exit $RC