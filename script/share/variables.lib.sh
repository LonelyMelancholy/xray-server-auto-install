# shellcheck disable=SC2148
# shellcheck disable=SC2034
# source this library for common variable across scripts

# dates
readonly TODAY=$(date '+%F')
readonly TS=$(date '+%Y%m%d_%H%M%S')

# common traffic limit per user ((3000 * 1024 * 1024 * 1024)) - 3TB limits
readonly MAX_TR=$((3000 * 1024 * 1024 * 1024))

# export path just in case
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
export PATH

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

# inbound tag for users
readonly INBOUND_TAG="Vless"

# blocked outbound tag
readonly BLOCK_OUTBOUND_TAG="blocked"
readonly MANUAL_BLOCK_TAG="manual-block-users"
readonly EXPIRED_BLOCK_TAG="autoblock-expired-users"
readonly TRAFFIC_BLOCK_TAG="autoblock-traffic-users"