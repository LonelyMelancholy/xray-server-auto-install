#!/bin/bash
# auto install xray update and send notify via systemd timer every first day month, 1:00-5:00 night time
# all errors are logged in journald, see journalctl -t xray_update
# exit codes work to tell systemd about update success, message status not matter

# enable logging
exec > >(systemd-cat -t xray_update -p info) 2> >(systemd-cat -t xray_update -p err) 5> >(systemd-cat -t xray_update -p notice)

# start logging message
echo "xray update started - $(date '+%Y-%m-%d %H:%M:%S')" >&5

# exit log message function
# shellcheck disable=SC2329
end_log() {
    if [[ "$RC" = "0" ]]; then
        echo "xray update ended - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    else
        echo "xray update failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# exit cleanup and log message function
# shellcheck disable=SC2329
rm_tmp() {
    echo "cleanup started - $(date '+%Y-%m-%d %H:%M:%S')" >&5
    if rm -rf "$TMP_DIR"; then
        echo "Success: delete tmp files"
        echo "cleanup ended - $(date '+%Y-%m-%d %H:%M:%S')"  >&5
    else
        echo "Error: delete tmp files" >&2
        echo "cleanup failed - $(date '+%Y-%m-%d %H:%M:%S')" >&2
    fi
}

# error exit log message for end log
trap 'end_log; rm_tmp;' EXIT

# create working directory
TMP_DIR="$(mktemp -d)" || { echo "Error: failed to create temporary directory, exit" >&2; exit 1; }
readonly TMP_DIR

# root checking
[[ $EUID -ne 0 ]] && { echo "Error: you are not the root user, exit" >&2; exit 1; }

# common variables source
# shellcheck source=share/variables.lib.sh
source "/usr/local/lib/service/variables.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/variables.lib.sh', exit" >&2; exit 1; }

# source Telegram func library
# shellcheck source=share/telegram.lib.sh
source "/usr/local/lib/service/telegram.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/telegram.lib.sh', exit" >&2; exit 1; }

# source library for run_lock and file permission cheking
# shellcheck source=share/run_lock.lib.sh
source "/usr/local/lib/service/run_lock.lib.sh" || { echo "Error: failed to source '/usr/local/lib/service/run_lock.lib.sh', exit" >&2; exit 1; }

# check another instanсe of the script is not running
run_lock_check "xray_update"

# check another update script not running and wait for exit
run_lock_wait "common_update" "3600"

# lock check
run_lock_wait "xray" "600"
run_lock_wait "uri_db" "600"
run_lock_wait "tr_db" "600"

# xray running check
# shellcheck disable=SC2119
xray_status_check

# function section
# helper function
# shellcheck disable=SC2329
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "Success: $action"
    else
        echo "Error: $action" >&2
        return 1
    fi
}

# download function
# shellcheck disable=SC2329
_dl() { curl -fsSL --max-time 60 "$1" -o "$2"; }

# download with retry function
# shellcheck disable=SC2329
_dl_with_retry() {
    local url="$1"
    local outfile="$2"
    local label="$3"
    local attempt=1
    local max_attempts=10

    while true; do
        echo "Info: download ${label}, attempt ${attempt}, please wait"
        if ! _dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$max_attempts" ]; then
                echo "Error: download ${label} after ${attempt} attempts" >&2
                return 1
            fi
            sleep 60
            ((attempt++))
            continue
        else
            echo "Success: download ${label} after ${attempt} attempts"
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

    # download main file
    _dl_with_retry "$url" "$outfile" "$name" || return 1

    # download checksum depending on the name there are two ways
    # download .dgst checksum if name xray
    if [ "$name" = "xray" ]; then
        _dl_with_retry "${url}.dgst" "$dgst_file" "${name}.dgst" || return 1
    # download checksum if other name (geoip.dat, geosite.dat)
    else
        _dl_with_retry "${url}.sha256sum" "$sha256sum_file" "${name}.sha256sum" || return 1
    fi

    # extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
    # reset sha
    expected_sha=""
    # extract sha256sum from .dgst if name xray
    if [ "$name" = "xray" ]; then
        expected_sha="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
        if [ -z "$expected_sha" ]; then
            echo "Error: failed to parse SHA256 from ${dgst_file}" >&2
            return 1
        else
            echo "Success: successful parse SHA256 from ${dgst_file}"
        fi
    # extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
    else
        expected_sha="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
        if [ -z "$expected_sha" ]; then
            echo "Error: failed to parse SHA256 from ${sha256sum_file}" >&2
            return 1
        else
            echo "Success: successful parse SHA256 from ${sha256sum_file}"
        fi
    fi

    # extract actual sha256sum from .zip or .dat
    # reset sha
    actual_sha=""
    actual_sha="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
    if [ -z "$actual_sha" ]; then
        echo "Error: failed to extract SHA256 from ${outfile}" >&2
        return 1
    else
        echo "Success: successful extraction SHA256 from ${outfile}"
    fi

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
        echo "Info: expected SHA256 from ${expected_label}: $expected_sha"
        echo "Info: actual SHA256 from ${actual_label}: $actual_sha"
        echo "Error: failed to compare, actual and expected SHA256 do not match for ${name}" >&2
        return 1
    else
        echo "Info: expected SHA256 from ${expected_label}: $expected_sha"
        echo "Info: actual SHA256 from ${actual_label}: $actual_sha"
        echo "Success: actual and expected SHA256 match for ${name}"
    fi

    # unzip archive if name xray
    if [ "$name" = "xray" ]; then
        if ! unzip -o "$outfile" -d "$TMP_DIR" &> /dev/null; then
            echo "Error: failed to extract ${outfile}" >&2
            return 1
        else
            echo "Success: ${outfile} successfully extracted"
        fi
        # check xray binary
        if [ ! -f "$TMP_DIR/xray" ]; then
            echo "Error: xray is missing from folder after unpacking ${outfile}" >&2
            return 1
        else
            echo "Success: xray exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
}

# function for start xray and check status
_xray_start_on_fail() {
    if systemctl start xray.service &> /dev/null; then
        echo "Success: xray.service started, try updating again later"
    else
        echo "Error: xray.service does not start" >&2
    fi
}

# install function for install bin and dat files
_install() {
    local install_mode="$1"
    local install_src="$2"
    local install_dest="$3"
    local name="$4"

        if install -m "$install_mode" -g root -o root "$install_src" "$install_dest"; then
            echo "Success: $name installed"
        else
            echo "Error: $name not installed, trying rollback" >&2
            run_and_check "rollback $name" cp -p "${install_dest}.bak.${TS}" "$install_dest"
            _xray_start_on_fail
            return 1
        fi
}

# install all files function
install_xray() {
    XRAY_NEW_VER=""
    XRAY_OLD_VER=""

    # check xray version
    if [ -x "$TMP_DIR/xray" ]; then
        XRAY_NEW_VER="$("$TMP_DIR/xray" --version | awk 'NR==1 {print $2; exit}')"
    else
        echo "Error: unknown new xray version" >&2
        return 1
    fi

    if [ -x "$XRAY_BIN" ]; then
        XRAY_OLD_VER="$("$XRAY_BIN" --version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
        echo "Error: unknown old xray version" >&2
        return 1
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" == "$XRAY_OLD_VER" ]; then
        echo "Info: xray already up to date $XRAY_NEW_VER, skip xray update"
        XRAY_UP_TO_DATE=1
    else
        echo "Info: current xray version is $XRAY_OLD_VER, latest is $XRAY_NEW_VER, preparing to update"
        XRAY_UP_TO_DATE=0
        run_and_check "backup xray" cp -p "$XRAY_BIN" "$XRAY_BIN_BACKUP" || return 1
    fi

    # backup geo*.dat
    run_and_check "backup geoip.dat" cp -p "$GEOIP_DAT"     "$GEOIP_DAT_BACKUP" || return 1
    run_and_check "backup geosite.dat" cp -p "$GEOSITE_DAT" "$GEOSITE_DAT_BACKUP" || return 1

    # stop xray service
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if systemctl stop xray.service &> /dev/null; then
            echo "Success: xray.service stopped, starting the update"
        else
            echo "Error: failed to stop xray.service, cancelling update" >&2
            echo "Info: checking status xray.service"
            if systemctl is-active --quiet xray.service; then
                echo "Success: xray.service is running, try updating again later"
                return 1
            else
                echo "Error: xray.service is not running, trying to start" >&2
                _xray_start_on_fail
                return 1
            fi 
        fi
    fi

    # install bin and geo*.dat
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        _install "755" "${TMP_DIR}/xray"  "$XRAY_BIN"     "xray" || return 1
    else
        echo "Info: xray installation skipped"
    fi

    _install "644" "${TMP_DIR}/geoip.dat"    "$GEOIP_DAT"    "geoip.dat" || return 1
    _install "644" "${TMP_DIR}/geosite.dat"  "$GEOSITE_DAT"  "geosite.dat" || return 1

    # start xray
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if systemctl start xray.service > /dev/null 2>&1; then
            echo "Success: xray.service updated and started"
        else
            echo "Error: xray.service does not start" >&2
            return 1
        fi
    fi

    return 0
}

# main logic start here
# send start update message
MESSAGE="⚠️ <b>Scheduled xray update</b>

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
☑️ <b>Action:</b> update started"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# sending message
telegram_message "$MESSAGE"

# download xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray"; then
    XRAY_DOWNLOAD=0
    STATUS_XRAY_DOWNLOAD="❌ <b>Error:</b> xray download"
else
    STATUS_XRAY_DOWNLOAD="☑️ <b>Success:</b> xray download"
    XRAY_DOWNLOAD=1
fi

# download geoip if xray success
if [[ "$XRAY_DOWNLOAD" == 1 ]]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat"; then
        GEOIP_DOWNLOAD=0
        STATUS_GEOIP_DOWNLOAD="❌ <b>Error:</b> geoip.dat download"
    else
        STATUS_GEOIP_DOWNLOAD="☑️ <b>Success:</b> geoip.dat download"
        GEOIP_DOWNLOAD=1
    fi
else
    GEOIP_DOWNLOAD=0
    STATUS_GEOIP_DOWNLOAD="⚠️ <b>Skip:</b> geoip.dat download"
fi

# download geosite if geoip success
if [[ "$XRAY_DOWNLOAD" == 1 && "$GEOIP_DOWNLOAD" == 1 ]]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOSITE_DOWNLOAD=0
        STATUS_GEOSITE_DOWNLOAD="❌ <b>Error:</b> geosite.dat download"
    else
        STATUS_GEOSITE_DOWNLOAD="☑️ <b>Success:</b> geosite.dat download"
        GEOSITE_DOWNLOAD=1
    fi
else
    GEOSITE_DOWNLOAD=0
    STATUS_GEOSITE_DOWNLOAD="⚠️ <b>Skip:</b> geosite.dat download"
fi

# if all downlad success, install
if [[ "$XRAY_DOWNLOAD" == 1 && "$GEOIP_DOWNLOAD" == 1 && "$GEOSITE_DOWNLOAD" == 1 ]]; then
    if ! install_xray; then
        STATUS_XRAY_GEODAT_INSTALL="❌ <b>Error:</b> xray and geo*.dat install"
        XRAY_GEODAT_INSTALL=0
    else
        if [[ "$XRAY_UP_TO_DATE" == 1 ]]; then
            STATUS_XRAY_GEODAT_INSTALL="☑️ <b>Success:</b> geo*.dat install"$'\n'
            STATUS_XRAY_GEODAT_INSTALL+="☑️ <b>Success:</b> xray already updated $XRAY_OLD_VER"
            XRAY_GEODAT_INSTALL=1
        else
            STATUS_XRAY_GEODAT_INSTALL="☑️ <b>Success:</b> xray and geo*.dat install"$'\n'
            STATUS_XRAY_GEODAT_INSTALL+="☑️ <b>Success:</b> xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
            XRAY_GEODAT_INSTALL=1
        fi
    fi
else
    XRAY_GEODAT_INSTALL=0
    STATUS_XRAY_GEODAT_INSTALL="⚠️ <b>Skip:</b> xray and geo*.dat install"
fi

# check final xray status
if systemctl is-active --quiet xray.service; then
    STATUS_XRAY_RUNNING="☑️ <b>Success:</b> xray.service is running"
    XRAY_RUNNING=1
else
    STATUS_XRAY_RUNNING="❌ <b>Error:</b> xray.service does not start"
    XRAY_RUNNING=0
fi

# select a title for the telegram message
if [[ "$XRAY_GEODAT_INSTALL" == 1 && "$XRAY_RUNNING" == 1 ]]; then
    MESSAGE_TITLE="✅ <b>Scheduled xray update</b>"
    STATUS_UPDATE="☑️ <b>Action:</b> update success"
    RC=0
else
    MESSAGE_TITLE="❌ <b>Scheduled xray update</b>"
    STATUS_UPDATE="☑️ <b>Action:</b> update failed"
fi

# collecting report for telegram message
MESSAGE="$MESSAGE_TITLE

🖥️ <b>Host:</b> ${HOST_TAG}
⌚ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
${STATUS_UPDATE}
${STATUS_XRAY_DOWNLOAD}
${STATUS_GEOIP_DOWNLOAD}
${STATUS_GEOSITE_DOWNLOAD}
${STATUS_XRAY_GEODAT_INSTALL}
${STATUS_XRAY_RUNNING}
💾 <b>Update log:</b> journalctl -t xray_update"

# logging message
echo "collected message - $(date '+%Y-%m-%d %H:%M:%S')"
echo "$MESSAGE"

# send result message
telegram_message "$MESSAGE"

# if update successuful, delete all old backups
if [[ $RC == 0 ]]; then
    run_and_check "delete all old '.bak' files" rm -f -- /usr/local/bin/xray.bak.* /usr/local/share/xray/*.bak.*
fi

# exit with work success status
exit $RC
