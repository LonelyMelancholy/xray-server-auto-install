#!/usr/bin/env bash

# main variables
ENV_FILE="/usr/local/etc/telegram/secrets.env"
ASSET_DIR="/usr/local/share/xray"
XRAY_DIR="/usr/local/bin/"
UPDATE_LOG="/var/log/xray/update.log"
TMP_DIR="$(mktemp -d)"
MAX_ATTEMPTS=3
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
STAGE="0"

# check secret file
[ -r "$ENV_FILE" ] || exit 1
source "$ENV_FILE"

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

    UNPACK_DIR="$2/xray-unpacked"
# Increase stage count
    STAGE=$((STAGE+1))

# download main file
    while true; do
        if ! dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                REASON+="Stage ${STAGE}. Failed to download $outfile after $attempt attempts${next_file}"$'\n'
                return 1
            fi
            sleep 10
            attempt=$((attempt + 1))
            continue
        else
            REASON+="Stage ${STAGE}. Success download $outfile after $attempt attempts${next_file}"$'\n'
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
                    REASON+="Stage ${STAGE}. Failed to download ${dgst_file} after $attempt attempts"$'\n'
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                REASON+="Stage ${STAGE}. Success download ${dgst_file}.dgst after $attempt attempts"$'\n'
                break
            fi
# download checksum if other name (geoip.dat, geosite.dat)
        else
            if ! dl "${url}.sha256sum" "$sha256sum_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON+="Stage ${STAGE}. Failed to download ${name}.sha256sum after $attempt attempts"$'\n' 
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                REASON+="Stage ${STAGE}. Success download ${name}.sha256sum after $attempt attempts"$'\n'
                break
            fi
        fi
    done

# reset attempt for next while
    attempt=1
# Increase stage count
    STAGE=$((STAGE+1))

# extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
    while true; do
# reset sha
        expected_sha_dgst=""
        expected_sha_dat=""
# extract sha256sum from .dgst if name xray
        if [ "$name" = "xray" ]; then
            expected_sha_dgst="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
            if [ -z "$expected_sha_dgst" ]; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON+="Stage ${STAGE}. Failed to parse SHA256 from ${dgst_file}"$'\n'
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                REASON+="Stage ${STAGE}. Success parse SHA256 from ${dgst_file}"$'\n'
                break
            fi
# extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha_dat="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha_dat" ]; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON+="Stage ${STAGE}. Failed to parse SHA256 from ${sha256sum_file}"$'\n'
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
                REASON+="Stage ${STAGE}. Success parse SHA256 from ${sha256sum_file}"$'\n'
                break
            fi
        fi
    done

# reset attempt for next while
    attempt=1
# Increase stage count
    STAGE=$((STAGE+1))

# extract actual sha256sum from .zip or .dat depending on the name there are two ways
    while true; do
# reset sha
        actual_sha_zip=""
        actual_sha_dat=""
# extract sha256sum from .zip if name xray
        if [ "$name" = "xray" ]; then
            actual_sha_zip="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_zip" ]; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON+="Stage ${STAGE}. Failed to extract SHA256 from ${outfile}"$'\n'
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
            REASON+="Stage ${STAGE}. Success extraction SHA256 from ${outfile}"$'\n'
            break
            fi
# extract sha256sum from .zip if other name (geoip.dat, geosite.dat)
        else
            actual_sha_dat="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha_dat" ]; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON+="Stage ${STAGE}. Failed to extract SHA256 from ${outfile}"$'\n'
                    return 1
                fi
                sleep 10
                attempt=$((attempt + 1))
                continue
            else
            REASON+="Stage ${STAGE}. Success extraction SHA256 from ${outfile}"$'\n'
            break
            fi
        fi
    done

# Increase stage count
    STAGE=$((STAGE+1))

# compare sha256sum checksum depending on the name there are two ways
# compare sha256sum checksum if name xray
    if [ "$name" = "xray" ]; then
        if [ "$expected_sha_dgst" != "$actual_sha_zip" ]; then
            REASON+="Stage ${STAGE}. Error: failed to compare, actual and expected SHA256 do not match for ${name}"$'\n'
            REASON+="Stage ${STAGE}. expected sha from .dgst="$expected_sha_dgst""$'\n'
            REASON+="Stage ${STAGE}. actual sha from .zip="$actual_sha_zip""$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Success: actual and expected SHA256 match for ${name}"$'\n'

        fi
# compare sha256sum checksum if other name (geoip.dat, geosite.dat)
    else
        if [ "$expected_sha_dat" != "$actual_sha_dat" ]; then
            REASON+="Stage ${STAGE}. Error: failed to compare, actual and expected SHA256 do not match for ${name}"$'\n'
            REASON+="Stage ${STAGE}. expected sha from .sha256sum="$expected_sha_dat""$'\n'
            REASON+="Stage ${STAGE}. actual sha from .dat="$actual_sha_dat""$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Success: actual and expected SHA256 match for ${name}"$'\n'
        fi
    fi

# unzip archive if name=xray
    if [ "$name" = "xray" ]; then
# Increase stage count
        STAGE=$((STAGE+1))
# unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            REASON+="Stage ${STAGE}. Error: failed to create directory for unpacking ${outfile}"$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Success: the directory for unpacking ${outfile} has been created"$'\n'
        fi
        if ! unzip -o "$zip_file" -d "$UNPACK_DIR" >/dev/null 2>&1; then
            REASON+="Stage ${STAGE}. Error: failed to extract ${outfile}"$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Success: ${outfile} successfully extracted"$'\n'
        fi
# check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            REASON+="Stage ${STAGE}. Error: Xray binary is missing from folder after unpacking ${outfile}"$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Success: Xray binary exists in the folder after unpacking ${outfile}"$'\n'
        fi
    fi

    return 0
}

install() {
    XRAY_NEW_VER=""
    XRAY_OLD_VER=""

# increase stage count
    STAGE=$((STAGE+1))
# check xray version
    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_NEW_VER="$("$UNPACK_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        REASON+="Stage ${STAGE}. Error: unknown Xray version"$'\n'
        return 1
    fi

    if [ -x "$XRAY_DIR/xray" ]; then
        XRAY_OLD_VER="$("$XRAY_DIR/xray" -version | awk 'NR==1 {print $2; exit}')"
    else
        XRAY_OLD_VER=""
    fi

    if [ -n "$XRAY_NEW_VER" ] && [ -n "$XRAY_OLD_VER" ] && [ "$XRAY_NEW_VER" = "$XRAY_OLD_VER" ]; then
        REASON+="Stage ${STAGE}. Skip: xray already up to date ($XRAY_NEW_VER)"$'\n'
    else
        REASON+="Stage ${STAGE}. Info: current xray version $XRAY_OLD_VER, actual ($XRAY_NEW_VER) get ready for the update"$'\n'
    fi

# increase stage count
    STAGE=$((STAGE+1))
# old file backup
    if cp "$XRAY_DIR/xray" "$XRAY_DIR/xray.bak.${DATE}"; then
        REASON+="Stage ${STAGE}. Success: xray bin backup completed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: xray bin backup failed"$'\n'
        return 1
    fi

    if cp "$ASSET_DIR/geoip.dat" "$ASSET_DIR/geoip.dat.bak.${DATE}"
        REASON+="Stage ${STAGE}. Success: geoip.dat backup completed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: geoip.dat backup failed"$'\n'
        return 1
    fi

    if cp "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.bak.${DATE}"
        REASON+="Stage ${STAGE}. Success: geosite.dat backup completed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: geosite.dat backup failed"$'\n'
        return 1
    fi

# increase stage count
    STAGE=$((STAGE+1))
# stop xray service
    if systemctl stop xray.service > /dev/null 2>&1; then
        REASON+="Stage ${STAGE}. Success: xray.service stopped, starting the update"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: xray.service failure to stop, canceling update"$'\n'
        REASON+="Stage ${STAGE}. Info: checking status xray.service "$'\n'
        if systemctl status xray.service > /dev/null 2>&1; then
            REASON+="Stage ${STAGE}. Success: xray.service running, try updating again later"$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Error: xray.service status failed, trying to start"$'\n'
            if systemctl start xray.service > /dev/null 2>&1; then
                REASON+="Stage ${STAGE}. Success: xray.service started, try updating again later."$'\n'
                return 1
            else
                REASON+="Stage ${STAGE}. Critical Error: xray.service does not start"$'\n'
                return 1
            fi
        fi 
    fi

# increase stage count
    STAGE=$((STAGE+1))
# install bin and geo*.dat
    if install -m 755 -o xray -g xray "$UNPACK_DIR/xray" "$XRAY_DIR/xray"; then
        REASON+="Stage ${STAGE}. Success: xray bin installed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: xray bin not installed"$'\n'
        if systemctl start xray.service > /dev/null 2>&1; then
            REASON+="Stage ${STAGE}. Success: xray.service started, try updating again later."$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Critical Error: xray.service does not start"$'\n'
            return 1
        fi
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat"; then
        REASON+="Stage ${STAGE}. Success: geoip.dat installed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: geoip.dat not installed"$'\n'
        if systemctl start xray.service > /dev/null 2>&1; then
            REASON+="Stage ${STAGE}. Success: xray.service started, try updating again later."$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Critical Error: xray.service does not start"$'\n'
            return 1
        fi
    fi

    if install -m 644 -o xray -g xray "$TMP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"; then
        REASON+="Stage ${STAGE}. Success: geosite.dat installed"$'\n'
    else
        REASON+="Stage ${STAGE}. Error: geosite.dat not installed"$'\n'
        if systemctl start xray.service > /dev/null 2>&1; then
            REASON+="Stage ${STAGE}. Success: xray.service started, try updating again later."$'\n'
            return 1
        else
            REASON+="Stage ${STAGE}. Critical Error: xray.service does not start"$'\n'
            return 1
        fi
    fi

# increase stage count
    STAGE=$((STAGE+1))
# start xray
    if systemctl start xray.service > /dev/null 2>&1; then
        REASON+="Stage ${STAGE}. Success: xray.service updated and started"$'\n'
    else
        REASON+="Stage ${STAGE}. Critical Error: xray.service does not start"$'\n'
        return 1
    fi

    return 0
}

# main logic start here
GEOBASE_UPDATE=true
XRAY_UPDATE=true

# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray" ", skip download geoip.dat, geosite.dat"; then
    XRAY_UPDATE=false
    STATUS_XRAY_MESSAGE="[↻] Xray download failed"
else
    STATUS_XRAY_MESSAGE="[↻] Xray bin unit download success"
fi

# update geoip if xray success
if [ "$XRAY_UPDATE" = true ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat" ", skip download geosite.dat"; then
        GEOBASE_UPDATE=false
        STATUS_GEOIP_MESSAGE="[↻] geoip.dat download failed"
    else
        STATUS_GEOIP_MESSAGE="[↻] Xray geoip.dat download success"
    fi
fi

# update geosite if geoip success
if [ "$GEOBASE_UPDATE" = true ]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOBASE_UPDATE=false
        STATUS_GEODAT_MESSAGE="[↻] geosite.dat download failed"
        else
        STATUS_GEODAT_MESSAGE="[↻] Xray geosite.dat download success"
    fi
fi
if [ "$GEOBASE_UPDATE" = "true" ]; then
    if ! install; then
        STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install failed"
        else
        STATUS_INSTALL_MESSAGE="[↻] Xray and geo*.dat install success"$'\n'
        STATUS_INSTALL_MESSAGE+="[↻] Xray updated from $XRAY_OLD_VER to $XRAY_NEW_VER"
    fi
fi

# telegram report
if [[ "$GEOBASE_UPDATE" = true && "$XRAY_UPDATE" = true ]]; then
    MESSAGE_TITLE="✅ Upgrade report"
else
    MESSAGE_TITLE="❌ Upgrade error"
fi

MESSAGE="$MESSAGE_TITLE

🖥️ Host: $HOSTNAME
⌚ Time: $DATE
${STATUS_XRAY_MESSAGE}
${STATUS_GEOIP_MESSAGE}
${STATUS_GEODAT_MESSAGE}
${STATUS_INSTALL_MESSAGE}
${REASON}
"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MESSAGE}" \
    > /dev/null 2>&1

exit 0