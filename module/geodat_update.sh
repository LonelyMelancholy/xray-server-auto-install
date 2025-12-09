#!/bin/bash

# enable logging
exec >>"$UPDATE_LOG" 2>&1

# root checking
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: you are not root user, exit"
    exit 1
fi

# main variables
ENV_FILE="/usr/local/etc/telegram/secrets.env"
ASSET_DIR="/usr/local/share/xray"
XRAY_DIR="/usr/local/bin/"
UPDATE_LOG="/var/log/xray/update.log"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
MAX_ATTEMPTS=3
STAGE="0"

TMP_DIR="$(mktemp -d)" || {
    echo "❌ Error: Failed to create temporary directory, exit"
    exit 1
}


# check secret file
if [ ! -r "$ENV_FILE" ]; then
    echo "❌ Error: env file $ENV_FILE not found or not readable"
    exit 1
fi
source "$ENV_FILE"

# Check token from secret file
if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Error: telegram Bot Token is missing in $ENV_FILE"
    exit 1
fi

# Check id from secret file
if [[ -z "$CHAT_ID" ]]; then
    echo "❌ Error: telegram Chat id is missing in $ENV_FILE"
    exit 1
fi

# exit cleanup
trap 'rm -rf "$TMP_DIR"' EXIT

dl() { curl -fsSL "$1" -o "$2"; }

download_and_verify() {
    local url="$1"
    local outfile="$2"
    local name="$3"
    local sha256sum_file="${outfile}.sha256sum"
    local dgst_file="${outfile}.dgst"
    local attempt=1
    local next_file=$4
    local expected_sha_dgst actual_sha_zip
    local expected_sha_dat actual_sha_dat

    UNPACK_DIR="$TMP_DIR/xray-unpacked"
# Increase stage count
    STAGE=$((STAGE+1))

# download main file
    while true; do
        if ! dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "Stage ${STAGE}. Failed to download $outfile after $attempt attempts${next_file}"
                return 1
            fi
            sleep 10
            attempt=$((attempt + 1))
            continue
        else
            echo "Stage ${STAGE}. Success download $outfile after $attempt attempts${next_file}"
            break
        fi
    done

# reset attempt for next while
    attempt=1
# Increase stage count
    STAGE=$((STAGE+1))

# download checksum depending on the name there are two ways
    while true; do
# download .dgst checksum if name xray
        if [ "$name" = "xray" ]; then
            if ! dl "${url}.dgst" "$dgst_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    echo "Stage ${STAGE}. Failed to download ${dgst_file} after $attempt attempts"
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                echo "Stage ${STAGE}. Success download ${dgst_file} after $attempt attempts"
                break
            fi
# download checksum if other name (geoip.dat, geosite.dat)
        else
            if ! dl "${url}.sha256sum" "$sha256sum_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    echo "Stage ${STAGE}. Failed to download ${name}.sha256sum after $attempt attempts" 
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                echo "Stage ${STAGE}. Success download ${name}.sha256sum after $attempt attempts"
                break
            fi
        fi
    done

# Increase stage count
    STAGE=$((STAGE+1))

# extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
# reset sha
        expected_sha_dgst=""
        expected_sha_dat=""
# extract sha256sum from .dgst if name xray
        if [ "$name" = "xray" ]; then
            expected_sha_dgst="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
            if [ -z "$expected_sha_dgst" ]; then
                echo "Stage ${STAGE}. Failed to parse SHA256 from ${dgst_file}"
                return 1
            else
                echo "Stage ${STAGE}. Success parse SHA256 from ${dgst_file}"
            fi
# extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha_dat="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha_dat" ]; then
                echo "Stage ${STAGE}. Failed to parse SHA256 from ${sha256sum_file}"
                return 1
            else
                echo "Stage ${STAGE}. Success parse SHA256 from ${sha256sum_file}"
            fi
        fi

# Increase stage count
    STAGE=$((STAGE+1))

# extract actual sha256sum from .zip or .dat depending on the name there are two ways
# reset sha
        actual_sha_zip=""
        actual_sha_dat=""
# extract sha256sum from .zip if name xray
        if [ "$name" = "xray" ]; then
            actual_sha_zip="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_zip" ]; then
                echo "Stage ${STAGE}. Failed to extract SHA256 from ${outfile}"
                return 1
            else
                echo "Stage ${STAGE}. Success extraction SHA256 from ${outfile}"
            fi
# extract sha256sum from .dat if other name (geoip.dat, geosite.dat)
        else
            actual_sha_dat="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_dat" ]; then
                echo "Stage ${STAGE}. Failed to extract SHA256 from ${outfile}"
                return 1
            else
                echo "Stage ${STAGE}. Success extraction SHA256 from ${outfile}"
            fi
        fi

# Increase stage count
    STAGE=$((STAGE+1))

# compare sha256sum checksum depending on the name there are two ways
# compare sha256sum checksum if name xray
    if [ "$name" = "xray" ]; then
        if [ "$expected_sha_dgst" != "$actual_sha_zip" ]; then
            echo "Stage ${STAGE}. Error: failed to compare, actual and expected SHA256 do not match for ${name}"
            echo "Stage ${STAGE}. expected sha from .dgst=$expected_sha_dgst"
            echo "Stage ${STAGE}. actual sha from .zip=$actual_sha_zip"
            return 1
        else
            echo "Stage ${STAGE}. Success: actual and expected SHA256 match for ${name}"

        fi
# compare sha256sum checksum if other name (geoip.dat, geosite.dat)
    else
        if [ "$expected_sha_dat" != "$actual_sha_dat" ]; then
            echo "Stage ${STAGE}. Error: failed to compare, actual and expected SHA256 do not match for ${name}"
            echo "Stage ${STAGE}. expected sha from .sha256sum=$expected_sha_dat"
            echo "Stage ${STAGE}. actual sha from .dat=$actual_sha_dat"
            return 1
        else
            echo "Stage ${STAGE}. Success: actual and expected SHA256 match for ${name}"
        fi
    fi

# unzip archive if name=xray
    if [ "$name" = "xray" ]; then
# Increase stage count
        STAGE=$((STAGE+1))
# unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            echo "Stage ${STAGE}. Error: failed to create directory for unpacking ${outfile}"
            return 1
        else
            echo "Stage ${STAGE}. Success: the directory for unpacking ${outfile} has been created"
        fi
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" >/dev/null 2>&1; then
            echo "Stage ${STAGE}. Error: failed to extract ${outfile}"
            return 1
        else
            echo "Stage ${STAGE}. Success: ${outfile} successfully extracted"
        fi
# check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            echo "Stage ${STAGE}. Error: Xray binary is missing from folder after unpacking ${outfile}"
            return 1
        else
            echo "Stage ${STAGE}. Success: Xray binary exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
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
        echo "Stage ${STAGE}. Error: unknown Xray version"
        return 1
    fi

    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_OLD_VER="$("$XRAY_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" = "$XRAY_OLD_VER" ]; then
        echo "Stage ${STAGE}. Info: xray already up to date ($XRAY_NEW_VER)"
        XRAY_UP_TO_DATE=1
    else
        echo "Stage ${STAGE}. Info: current xray version $XRAY_OLD_VER, actual ($XRAY_NEW_VER) get ready for the update"
        XRAY_UP_TO_DATE=0
    fi

# increase stage count
    STAGE=$((STAGE+1))
# old file backup
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if cp "$XRAY_DIR/xray" "$XRAY_DIR/xray.bak.${DATE}"; then
            echo "Stage ${STAGE}. Success: xray bin backup completed"
        else
            echo "Stage ${STAGE}. Error: xray bin backup failed"
            return 1
        fi
    else
        echo "Stage ${STAGE}. Skip: xray already up to date, backup not needed"
    fi

    if cp "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geoip.dat.bak.${DATE}"; then
        echo "Stage ${STAGE}. Success: geoip.dat backup completed"
    else
        echo "Stage ${STAGE}. Error: geoip.dat backup failed"
        return 1
    fi

    if cp "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.bak.${DATE}"; then
        echo "Stage ${STAGE}. Success: geosite.dat backup completed"
    else
        echo "Stage ${STAGE}. Error: geosite.dat backup failed"
        return 1
    fi

# increase stage count
    STAGE=$((STAGE+1))
# stop xray service
    if systemctl stop xray.service > /dev/null 2>&1; then
        echo "Stage ${STAGE}. Success: xray.service stopped, starting the update"
    else
        echo "Stage ${STAGE}. Error: xray.service failure to stop, canceling update"
        echo "Stage ${STAGE}. Info: checking status xray.service "
        if systemctl status xray.service > /dev/null 2>&1; then
            echo "Stage ${STAGE}. Success: xray.service running, try updating again later"
            return 1
        else
            echo "Stage ${STAGE}. Error: xray.service status failed, trying to start"
            if systemctl start xray.service > /dev/null 2>&1; then
                echo "Stage ${STAGE}. Success: xray.service started, try updating again later."
                return 1
            else
                echo "Stage ${STAGE}. Critical Error: xray.service does not start"
                return 1
            fi
        fi 
    fi

# increase stage count
    STAGE=$((STAGE+1))
# install bin and geo*.dat
    if [ "$XRAY_UP_TO_DATE" = "0" ]; then
        if install -m 755 -o xray -g xray "$UNPACK_DIR/xray" "$XRAY_DIR/xray"; then
            echo "Stage ${STAGE}. Success: xray bin installed"
        else
            echo "Stage ${STAGE}. Error: xray bin not installed"
            if systemctl start xray.service > /dev/null 2>&1; then
                echo "Stage ${STAGE}. Success: xray.service started, try updating again later."
                return 1
            else
                echo "Stage ${STAGE}. Critical Error: xray.service does not start"
                return 1
            fi
        fi
    else
        echo "Stage ${STAGE}. Skip: xray already up to date, xray bin not installed"
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geoip.dat" "$ASSET_DIR/geoip.dat"; then
        echo "Stage ${STAGE}. Success: geoip.dat installed"
    else
        echo "Stage ${STAGE}. Error: geoip.dat not installed"
        if systemctl start xray.service > /dev/null 2>&1; then
            echo "Stage ${STAGE}. Success: xray.service started, try updating again later."
            return 1
        else
            echo "Stage ${STAGE}. Critical Error: xray.service does not start"
            return 1
        fi
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"; then
        echo "Stage ${STAGE}. Success: geosite.dat installed"
    else
        echo "Stage ${STAGE}. Error: geosite.dat not installed"
        if systemctl start xray.service > /dev/null 2>&1; then
            echo "Stage ${STAGE}. Success: xray.service started, try updating again later."
            return 1
        else
            echo "Stage ${STAGE}. Critical Error: xray.service does not start"
            return 1
        fi
    fi

# increase stage count
    STAGE=$((STAGE+1))
# start xray
    if systemctl start xray.service > /dev/null 2>&1; then
        echo "Stage ${STAGE}. Success: xray.service updated and started"
    else
        echo "Stage ${STAGE}. Critical Error: xray.service does not start"
        return 1
    fi

    return 0
}

# main logic start here
# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray" ", skip download geoip.dat, geosite.dat"; then
    XRAY_DOWNLOAD=false
    STATUS_XRAY_MESSAGE="[↻] Xray download failed"
else
    STATUS_XRAY_MESSAGE="[↻] Xray binary download success"
    XRAY_DOWNLOAD=true
fi

# update geoip if xray success
if [ "$XRAY_DOWNLOAD" = "true" ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat" ", skip download geosite.dat"; then
        GEOIP_DOWNLOAD=false
        STATUS_GEOIP_MESSAGE="[↻] geoip.dat download failed"
    else
        STATUS_GEOIP_MESSAGE="[↻] Xray geoip.dat download success"
        GEOIP_DOWNLOAD=true
    fi
else
    GEOIP_DOWNLOAD=false
    STATUS_GEOIP_MESSAGE="[↻] geoip.dat download skip"
fi

# update geosite if geoip success
if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOSITE_DOWNLOAD=false
        STATUS_GEOSITE_MESSAGE="[↻] geosite.dat download failed"
        else
        STATUS_GEOSITE_MESSAGE="[↻] Xray geosite.dat download success"
        GEOSITE_DOWNLOAD=true
    fi
else
    GEOSITE_DOWNLOAD=false
    STATUS_GEOSITE_MESSAGE="[↻] geosite.dat download skip"
fi

if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ] && [ "$GEOSITE_DOWNLOAD" = "true" ]; then
    if ! install_xray; then
        STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install failed"
        XRAY_INSTALL=false
        else
        STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install success"$'\n'
        STATUS_INSTALL_MESSAGE+="[↻] Xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
        XRAY_INSTALL=true
    fi
else
    XRAY_INSTALL=false
    STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install skip"
fi

# create log file
echo "$DATE" >  "$UPDATE_LOG"
echo "$REASON" >> "$UPDATE_LOG"

# telegram report
if [ "$XRAY_DOWNLOAD" = "true" ] && [ "$GEOIP_DOWNLOAD" = "true" ] && [ "$GEOSITE_DOWNLOAD" = "true" ] && [ "$XRAY_INSTALL" = "true" ]; then
    MESSAGE_TITLE="✅ Upgrade report"
else
    MESSAGE_TITLE="❌ Upgrade error"
fi

MESSAGE="$MESSAGE_TITLE

🖥️ Host: $HOSTNAME
⌚ Time: $DATE
${STATUS_XRAY_MESSAGE}
${STATUS_GEOIP_MESSAGE}
${STATUS_GEOSITE_MESSAGE}
${STATUS_INSTALL_MESSAGE}
💾 Logfile: ${UPDATE_LOG}"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    > /dev/null 2>&1

exit 0