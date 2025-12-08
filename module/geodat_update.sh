#!/usr/bin/env bash

# main variables
ENV_FILE="/usr/local/etc/telegram/secrets.env"
ASSET_DIR="/usr/local/share/xray"
XRAY_BIN="/usr/local/bin/xray"
UPDATE_LOG="/var/log/xray/update.log"
TMP_DIR="$(mktemp -d)"
MAX_ATTEMPTS=3
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

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
    local dgst_file="${zip_file}.dgst"
    local unpack_dir="$2/xray-unpacked"
    local attempt=1
    local next_file=$4

# download main file
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        if ! dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                REASON="Stage 1. Failed to download $outfile after $attempt attempts${next_file}"
                return 1
            fi
            attempt=$((attempt + 1))
            continue
        else
            REASON+=$'\n'"Stage 1. Success download $outfile ${next_file}"
        fi
    done

# reset attempt
    attempt=1

# download checksum depending on the name there are two ways
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        if [ "$name" = "xray" ]; then
# download .dgst checksum if name xray
            if ! dl "${url}.dgst" "$dgst_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON="Stage 1. Failed to download ${name}.dgst after $attempt attempts"
                    return 1
                fi
                attempt=$((attempt + 1))
                continue
            fi
        else
# download checksum if other name (geo*.dat)
            if ! dl "${url}.sha256sum" "$sha256sum_file"; then
                if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                    REASON="Stage 1. Failed to download ${name}.sha256sum after $attempt attempts"
                    return 1
                fi
                attempt=$((attempt + 1))
                continue
            fi
        fi
    done

if [ "$name" = "xray" ]; then
    # 3. Достаём sha256 из .dgst
    local expected_sha actual_sha
    # В .dgst обычно строка вида: "SHA256 (Xray-linux-64.zip) = abcdef..."
    expected_sha="$(awk -F'= ' '/^SHA2-256/ {print $2}' "$dgst_file")"

    if [ -z "$expected_sha" ]; then
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "xray update: unable to parse SHA256 from .dgst"
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    actual_sha="$(sha256sum "$zip_file" 2>/dev/null | awk '{print $1}')"

    if [ -z "$actual_sha" ]; then
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "xray update: sha256sum failed"
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    if [ "$expected_sha" != "$actual_sha" ]; then
      echo "xray update: checksum mismatch (expected $expected_sha, got $actual_sha)"
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    # если дошли сюда — архив ок
    break
  done



# читаем ожидаемый и фактический sha256
    local expected actual
    expected="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null || true)"
    actual="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}' || true)"

    # если что-то пошло не так — считаем это ошибкой и пробуем ещё раз
    if [ -z "$expected" ] || [ -z "$actual" ]; then
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        return 1
      fi
      attempt=$((attempt + 1))
      continue
    fi

    # success
    if [ "$expected" = "$actual" ]; then
      return 0
    fi

    # checksum не совпала — пробуем ещё раз, если не исчерпали попытки
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      return 1
    fi

    attempt=$((attempt + 1))
  done

-------






    тут надо логику когда успех заполнять переменную ризон
    REASON="Stage 1. All files downloaded successfully"

  # сюда по идее не дойдём
  return 1
}


тут функции обновления которые мы будем вызывать позже или 
после скачки зделать вызов

  if [ "$success" = true ]; then
  mkdir -p "$ASSET_DIR"

  # бэкапы старых файлов, если есть
  [ -f "$ASSET_DIR/geoip.dat" ]   && cp "$ASSET_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat.bak"
  [ -f "$ASSET_DIR/geosite.dat" ] && cp "$ASSET_DIR/geosite.dat" "$ASSET_DIR/geosite.dat.bak"

  install -m 644 "$TMP_DIR/geoip.dat"   "$ASSET_DIR/geoip.dat"
  install -m 644 "$TMP_DIR/geosite.dat" "$ASSET_DIR/geosite.dat"

  if ! systemctl restart xray >/dev/null 2>&1; then
    success=false
    ERROR_REASON="Не удалось перезапустить Xray (systemctl restart xray)"
  fi
fi


# main logic start here
GEOBASE_UPDATE=true
XRAY_UPDATE=true

# update xray
if ! download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray" ", skip download geoip.dat, geosite.dat"; then
    XRAY_UPDATE=false
    STATUS_XRAY_MESSAGE="Xray update failed"
else
    STATUS_XRAY_MESSAGE="[↻] Xray unit update success from $XRAY_OLD_VER to $XRAY_NEW_VER"
fi

# update geoip if xray success
if [ "$XRAY_UPDATE" = true ]; then
    if ! download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat" ", skip download geosite.dat"; then
        GEOBASE_UPDATE=false
        STATUS_GEOIP_MESSAGE="geoip.dat update failed"
    else
        STATUS_GEOIP_MESSAGE="[↻] Xray geoip.dat update success"
    fi
fi

# update geosite if geoip success
if [ "$GEOBASE_UPDATE" = true ]; then
    if ! download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"; then
        GEOBASE_UPDATE=false
        STATUS_GEODAT_MESSAGE="geosite.dat update failed"
        else
        STATUS_GEODAT_MESSAGE="[↻] Xray geosite.dat update success"
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
${REASON}
"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    -d "text=${MESSAGE}" \
    > /dev/null 2>&1

exit 0