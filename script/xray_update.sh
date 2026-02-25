#!/bin/bash
# auto install xray update and send notify via systemd timer every first day month, 2:01 night time
# all errors are logged in journald, see journalctl -t xray_update
# exit codes work to tell systemd about success

# main variables
readonly DATE="$(date '+%F')"
DATE_START=$(date '+%Y-%m-%d %H:%M:%S')
readonly LOCK_FILE="/run/lock/xray_update.lock"
readonly ASSET_DIR="/usr/local/share/xray"
readonly XRAY_DIR="/usr/local/bin"
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
readonly XRAY_URL="https://github.com/XTLS/xray-core/releases/latest/download/xray-linux-64.zip"
STAGE=0
FAIL_TD=0
RC=1

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# enable logging
exec > >(systemd-cat -t xray_update -p info) 2> >(systemd-cat -t xray_update -p err) 5> >(systemd-cat -t xray_update -p notice)

# start logging message
echo "xray update started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# root checking
[[ $EUID -ne 0 ]] && { echo "Error: you are not the root user, exit" >&2; exit 1; }

# create working directory
TMP_DIR="$(mktemp -d)" || { echo "Error: failed to create temporary directory, exit" >&2; exit 1; }
readonly TMP_DIR

# exit log message function
# shellcheck disable=SC2329
on_exit() {
    if [[ "$RC" = "0" ]]; then
        echo "xray update ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "xray update failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit cleanup and log message function
# shellcheck disable=SC2329
exit_cleanup() {
    echo "cleanup started - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -rf "$TMP_DIR"; then
        echo "Success: temporary directory $TMP_DIR was deleted"
        echo "cleanup ended - $(date '+%Y-%m-%d %H:%M:%S')"  >&5
    else
        echo "Error: temporary directory $TMP_DIR was not deleted" >&2
        echo "cleanup failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2

        # set error message for telegram
        MESSAGE="❌ <b>Scheduled cleanup after xray update</b>
🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time error:</b> $(date '+%Y-%m-%d %H:%M:%S')
❌ <b>Error:</b> temporary directory $TMP_DIR for xray update was not deleted"
        
        # send message
        telegram_message
    fi
}

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# error exit log message for end log
trap 'on_exit; exit_cleanup;' EXIT

# check another instanсe of the script is not running
exec {fd}> "$LOCK_FILE" || { echo "Error: cannot open lock file '$LOCK_FILE', exit" >&2; exit 1; }
flock -n ${fd} || { echo "Error: another instance working on backup, exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# lock check
run_lock_retry_check "xray"
run_lock_retry_check "uri_db"
run_lock_retry_check "tr_db"

# cleanup old backup and log
cleanup_old() {
    local dir="$1"
    local pattern="$2"
    local keep="$3"
    local name="$4"
    local has_old=0
    local f
    local glob="${dir}/${pattern}"

    if ! compgen -G "$glob" > /dev/null; then
        STATUS_OLD_BACKUP_DEL+="☑️ old ${name} missing, skipping deletion"$'\n'
        return
    fi

    for f in "$dir"/$pattern; do
        [[ -n "$keep" && "$f" == "$keep" ]] && continue

        has_old=1
        echo "Info: stage ${STAGE}, deleting old ${name} $f"
        if rm -f -- "$f"; then
            echo "Success: stage ${STAGE}, old ${name} $f deleted"
            STATUS_OLD_BACKUP_DEL+="☑️ old ${name} deletion success"$'\n'
        else
            echo "Error: stage ${STAGE}, failed to delete old ${name} $f" >&2
            STATUS_OLD_BACKUP_DEL+="⚠️ old ${name} deletion failed"$'\n'
            FAIL_TD=1
        fi
    done

    if [[ $has_old == 0 ]]; then
        STATUS_OLD_BACKUP_DEL+="☑️ old ${name} missing, skipping deletion"$'\n'
    fi
}

# download function
_dl() { curl -fsSL --max-time 60 "$1" -o "$2"; }

# download with retry function
_dl_with_retry() {
    local url="$1"
    local outfile="$2"
    local label="$3"
    local attempt=1
    local max_attempts=3

    while true; do
        if ! _dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$max_attempts" ]; then
                echo "Error: stage ${STAGE}, failed to download ${label} after ${attempt} attempts, exit" >&2
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "Success: stage ${STAGE}, successful download ${label} after ${attempt} attempts"
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
                echo "Error: stage ${STAGE}, failed to parse SHA256 from ${dgst_file}, exit" >&2
                return 1
            else
                echo "Success: stage ${STAGE}, successful parse SHA256 from ${dgst_file}"
            fi
        # extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha" ]; then
                echo "Error: stage ${STAGE}, failed to parse SHA256 from ${sha256sum_file}, exit" >&2
                return 1
            else
                echo "Success: stage ${STAGE}, successful parse SHA256 from ${sha256sum_file}"
            fi
        fi

    # increase stage count
    STAGE=$((STAGE+1))

    # extract actual sha256sum from .zip or .dat
    # reset sha
    actual_sha=""
    actual_sha="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
        if [ -z "$actual_sha" ]; then
            echo "Error: stage ${STAGE}, failed to extract SHA256 from ${outfile}, exit" >&2
            return 1
        else
            echo "Success: stage ${STAGE}, successful extraction SHA256 from ${outfile}"
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
        echo "Info: stage ${STAGE}, expected SHA256 from ${expected_label}: $expected_sha"
        echo "Info: stage ${STAGE}, actual SHA256 from ${actual_label}: $actual_sha"
        echo "Error: stage ${STAGE}, failed to compare, actual and expected SHA256 do not match for ${name}, exit" >&2
        return 1
    else
        echo "Info: stage ${STAGE}, expected SHA256 from ${expected_label}: $expected_sha"
        echo "Info: stage ${STAGE}, actual SHA256 from ${actual_label}: $actual_sha"
        echo "Success: stage ${STAGE}, actual and expected SHA256 match for ${name}"
    fi

    # unzip archive if name xray
    if [ "$name" = "xray" ]; then
        # increase stage count
        STAGE=$((STAGE+1))
            # unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            echo "Error: stage ${STAGE}, failed to create directory for unpacking ${outfile}, exit" >&2
            return 1
        else
            echo "Success: stage ${STAGE}, the directory for unpacking ${outfile} has been created"
        fi
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" &> /dev/null; then
            echo "Error: stage ${STAGE}, failed to extract ${outfile}, exit" >&2
            return 1
        else
            echo "Success: stage ${STAGE}, ${outfile} successfully extracted"
        fi
        # check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            echo "Error: stage ${STAGE}, xray binary is missing from folder after unpacking ${outfile}, exit" >&2
            return 1
        else
            echo "Success: stage ${STAGE}, xray binary exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
}

# function for start xray and check status
_xray_start_on_fail() {
    if systemctl start xray.service &> /dev/null; then
        echo "Success: stage ${STAGE}, xray.service started, try updating again later, exit"
    else
        echo "Critical Error: stage ${STAGE}, xray.service does not start, exit" >&2
    fi
}

# backup function
_backup_old_file() {
    local backup_src="$1"
    local backup_dest="$2"
    local label="$3"
    if cp -p "$backup_src" "$backup_dest"; then
        echo "Success: stage ${STAGE}, ${label} backup completed"
    else
        echo "Error: stage ${STAGE}, ${label} backup failed, exit" >&2
        return 1
    fi
}

# install function for install bin and dat files
_install() {
    local install_mode="$1"
    local install_src="$2"
    local install_dest="$3"
    local name="$4"

        if install -m "$install_mode" -g root -o root "$install_src" "$install_dest"; then
            echo "Success: stage ${STAGE}, $name installed"
        else
            echo "Error: stage ${STAGE}, $name not installed, trying rollback" >&2
            if ! cp -p "${install_dest}.${DATE}.bak" "$install_dest"; then
                echo "Error: stage ${STAGE}, $name rollback failed" >&2
            else
                echo "Success: stage ${STAGE}, $name rolled back successfully"
            fi
            _xray_start_on_fail
            return 1
        fi
}

# install all files function
install_xray() {
    XRAY_NEW_VER=""
    XRAY_OLD_VER=""

    # increase stage count
    STAGE=$((STAGE+1))
    
    # check xray version
    if [ -x "$UNPACK_DIR/xray" ]; then
        XRAY_NEW_VER="$("$UNPACK_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        echo "Error: stage ${STAGE}, unknown new xray version, exit" >&2
        return 1
    fi

    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_OLD_VER="$("$XRAY_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
        echo "Error: stage ${STAGE}, unknown old xray version, exit" >&2
        return 1
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" = "$XRAY_OLD_VER" ]; then
        echo "Info: stage ${STAGE}, xray already up to date $XRAY_NEW_VER, skip xray update"
        XRAY_UP_TO_DATE=1
    else
        echo "Info: stage ${STAGE}, current xray version is $XRAY_OLD_VER, latest is $XRAY_NEW_VER, preparing to update"
        XRAY_UP_TO_DATE=0
    fi

    # increase stage count
    STAGE=$((STAGE+1))
    # old file backup
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        # backup
        _backup_old_file "$XRAY_DIR/xray" "$XRAY_DIR/xray.${DATE}.bak" "xray bin" || return 1
    else
        echo "Info: stage ${STAGE}, xray already up to date, backup not needed"
    fi

    # backup
    _backup_old_file "$ASSET_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat.${DATE}.bak"   "geoip.dat"   || return 1
    _backup_old_file "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.${DATE}.bak" "geosite.dat" || return 1

    # increase stage count
    STAGE=$((STAGE+1))
    
    # stop xray service
    if systemctl stop xray.service &> /dev/null; then
        echo "Success: stage ${STAGE}, xray.service stopped, starting the update"
    else
        echo "Error: stage ${STAGE}, failed to stop xray.service, cancelling update" >&2
        echo "Info: stage ${STAGE}, checking status xray.service"
        if systemctl is-active --quiet xray.service; then
            echo "Success: stage ${STAGE}, xray.service is running, try updating again later, exit"
            return 1
        else
            echo "Error: stage ${STAGE}, xray.service is not running, trying to start" >&2
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
        echo "Info: stage ${STAGE}, xray binary installation skipped"
    fi

    _install "644" "${TMP_DIR}/geoip.dat"    "${ASSET_DIR}/geoip.dat"    "geoip.dat" || return 1
    _install "644" "${TMP_DIR}/geosite.dat"  "${ASSET_DIR}/geosite.dat"  "geosite.dat" || return 1

    # increase stage count
    STAGE=$((STAGE+1))
    # start xray
    if systemctl start xray.service > /dev/null 2>&1; then
        echo "Success: stage ${STAGE}, xray.service updated and started"
    else
        echo "Critical Error: stage ${STAGE}, xray.service does not start" >&2
        return 1
    fi

    return 0
}

# main logic start here
# call the function to clear old logs before starting work
cleanup_old "$XRAY_DIR"      "xray.*.bak"         "$XRAY_DIR/xray.${DATE}.bak"          "xray backup"
cleanup_old "$ASSET_DIR"     "geoip.dat.*.bak"    "$ASSET_DIR/geoip.dat.${DATE}.bak"    "geoip.dat backup"
cleanup_old "$ASSET_DIR"     "geosite.dat.*.bak"  "$ASSET_DIR/geosite.dat.${DATE}.bak"  "geosite.dat backup"


# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray"; then
    XRAY_DOWNLOAD=0
    STATUS_XRAY_MESSAGE="❌ xray download failed"
else
    STATUS_XRAY_MESSAGE="☑️ xray binary download success"
    XRAY_DOWNLOAD=1
fi

# update geoip if xray success
if [ "$XRAY_DOWNLOAD" = "1" ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat"; then
        GEOIP_DOWNLOAD=0
        STATUS_GEOIP_MESSAGE="❌ geoip.dat download failed"
    else
        STATUS_GEOIP_MESSAGE="☑️ xray geoip.dat download success"
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
        STATUS_GEOSITE_MESSAGE="☑️ xray geosite.dat download success"
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
            STATUS_INSTALL_MESSAGE="☑️ geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="☑️ xray already up to date $XRAY_OLD_VER"
            XRAY_INSTALL=1
        else
            STATUS_INSTALL_MESSAGE="☑️ xray and geo*.dat install success"$'\n'
            STATUS_INSTALL_MESSAGE+="☑️ xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
            XRAY_INSTALL=1
        fi
    fi
else
    XRAY_INSTALL=0
    STATUS_INSTALL_MESSAGE="⚠️ xray and geo*.dat install skip"
fi

# check final xray status
if systemctl is-active --quiet xray.service; then
    STATUS_XRAY="☑️ Success: xray.service is running"
else
    STATUS_XRAY="❌ Critical Error: xray.service does not start"
fi

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

🖥️ <b>Host:</b> $(hostname)
⌚ <b>Time start:</b> $DATE_START
⌚ <b>Time end:</b> $(date +%Y-%m-%d %H:%M:%S)
${STATUS_OLD_BACKUP_DEL}${STATUS_XRAY_MESSAGE}
${STATUS_GEOIP_MESSAGE}
${STATUS_GEOSITE_MESSAGE}
${STATUS_INSTALL_MESSAGE}
${STATUS_XRAY}
💾 <b>Update log:</b> journalctl -t xray_update"

telegram_message

exit $RC
