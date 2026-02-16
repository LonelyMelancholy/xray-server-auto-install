# shellcheck disable=SC2148
# shellcheck disable=SC2034
# source this library for common variable across scripts

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
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.bak.$(date '+%Y%m%d_%H%M%S')"
readonly URI_DB_BACKUP="${URI_DB}.bak.$(date '+%Y%m%d_%H%M%S')"
readonly TR_DB_M_BACKUP="${TR_DB_M}.bak.$(date '+%Y%m%d_%H%M%S')"

# inbound tag for users
readonly INBOUND_TAG="Vless"

# blocked outbound tag
readonly BLOCK_OUTBOUND_TAG="blocked"