# shellcheck disable=SC2148
# shellcheck disable=SC2034
# source this library for common variable across scripts

# dates
# today date
TODAY=$(date '+%Y-%m-%d')
readonly TODAY
# today in sec from start epoch
TODAY_EPOCH=$(date -d 'today 00:00' +%s)
readonly TODAY_EPOCH
# time stamp for backup file mostly
TS=$(date '+%Y%m%d_%H%M%S')
readonly TS

# hostname
HOST_TAG=$(hostname)
readonly HOST_TAG

# common traffic limit per user ((3000 * 1024 * 1024 * 1024)) - 3TB limits
# 3000 gigabytes convert to bytes
readonly MAX_TR=$((3000 * 1024 * 1024 * 1024))

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

# bin and data files
readonly XRAY_BIN="/usr/local/bin/xray"
readonly GEOIP_DAT="/usr/local/share/xray/geoip.dat"
readonly GEOSITE_DAT="/usr/local/share/xray/geosite.dat"

# xray config path
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"

# user traffic database monthly and annual
readonly TR_DB_M="/usr/local/etc/xray/TR_DB_M"
readonly TR_DB_Y="/usr/local/etc/xray/TR_DB_Y"

# database for user vless link
readonly URI_DB="/usr/local/etc/xray/URI_DB"

# path for backup
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.${TS}"
readonly URI_DB_BACKUP="${URI_DB}.bak.${TS}"
readonly TR_DB_M_BACKUP="${TR_DB_M}.bak.${TS}"
readonly XRAY_BIN_BACKUP="/usr/local/bin/xray.bak.${TS}"
readonly GEOIP_DAT_BACKUP="/usr/local/share/xray/geoip.dat.bak.${TS}"
readonly GEOSITE_DAT_BACKUP="/usr/local/share/xray/geosite.dat.bak.${TS}"

# inbound tag and flow for users
readonly INBOUND_TAG="Vless"
readonly DEFAULT_FLOW="xtls-rprx-vision"

# blocked outbound tag
readonly BLOCK_OUTBOUND_TAG="blocked"
readonly MANUAL_BLOCK_TAG="manual-block-users"
readonly EXPIRED_BLOCK_TAG="autoblock-expired-users"
readonly TRAFFIC_BLOCK_TAG="autoblock-traffic-users"

# usercheck variable
readonly TARGET_USER="telegram_gateway"

# error status flag for exit and logging
# main goal
RC=1
# message delivery success
RC_M=1
# file delivery success
RC_F=1
# xray status
XR_ST=1
# reboot flag for unattended upgrade
REBOOT=0

# cpu threshold in % and checking frequency in sec for alerting
readonly CPU_THRESHOLD=80
readonly CHECKING_FREQUENCY=60

# cursor file for journald_alert
readonly STATE_FILE="/var/tmp/journald_alert.last_cursor"

# array for decrypt error level in message
declare -A ERROR_LEVEL=( [0]="emergency" [1]="alert" [2]="critical" [3]="error" )

# lock files list to precreate
readonly LOCK_FILES=(
    "/run/lock/boot_notify.lock"
    "/run/lock/cpu_alert.lock"
    "/run/lock/journald_alert.lock"
    "/run/lock/telegram_gateway.lock"
    "/run/lock/time_block.lock"
    "/run/lock/traffic_block.lock"
    "/run/lock/unattended_upgrade.lock"
    "/run/lock/user_notify.lock"
    "/run/lock/xray_backup.lock"
    "/run/lock/xray_statistics.lock"
    "/run/lock/xray_update.lock"
    "/run/lock/common_update.lock"
    "/run/lock/xray.lock"
    "/run/lock/uri_db.lock"
    "/run/lock/tr_db.lock"
)

# permission for lock files, only for read
readonly LOCK_MODE=0644
readonly LOCK_OWNER=root
readonly LOCK_GROUP=root

# array for traffic block script
declare -A TOTAL_BYTES_BY_USERS
declare -a FULL_EMAILS=()
declare -a FULL_EMAILS_TO_BLOCK=()
declare -a USERNAME_TO_BLOCK=()

# array for usershow script
declare -A FULL_USERNAMES=()
declare -A DAYS_LEFT_BY_USER=()
declare -A STATUS_BY_USER=()
declare -A ONLINE_BY_USER=()
declare -A DEVICES_BY_USER=()
declare -A TRAFFIC_BY_USER=()

# backup variables
readonly FILES_TO_BACKUP=("$XRAY_CONFIG" "$URI_DB" "$TR_DB_M" "$TR_DB_Y")
readonly BACKUP_FILE_NAME="xray_backup_${HOST_TAG}_${TS}.tar.gz"
readonly BACKUP_FILE_PATH="/tmp/${BACKUP_FILE_NAME}"

# links for xray update
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
readonly XRAY_URL="https://github.com/XTLS/xray-core/releases/latest/download/xray-linux-64.zip"
