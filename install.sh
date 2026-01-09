#!/bin/bash
# installation script


# root checking
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: you are not the root user, exit"
    exit 1
else
    echo "✅ Success: you are root user, continued"
fi


# check another instanse of the script is not running
readonly LOCK_FILE="/run/lock/vpn_install.lock"
exec 9> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { echo "❌ Error: another instance is running, exit"; exit 1; }


# main variables
MAX_ATTEMPTS=3
export NEEDRESTART_SUSPEND=1

# helping functions
has_cmd() {
    command -v "$1" &> /dev/null
}

install_with_retry() {
    local action="$1"
    local attempt=1
    shift 1

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        if "$@" > /dev/null; then
            echo "✅ Success: $action, after ${attempt} attempts"
            return 0
        fi
        if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
            sleep 60
            ((attempt++))
            continue
        else
            echo "❌ Error: $action, after ${attempt} attempts, exit"
            exit 1
        fi
    done
}

# helper func
try() { "$@" || return 1; }

run_and_check() {
    action="$1"
    shift 1
    "$@" > /dev/null && echo "✅ Success: $action" || { echo "❌ Error: $action, exit"; exit 1; }
}


# check configuration file
CFG_CHECK="module/cfg_check.sh"
[[ -r "$CFG_CHECK" ]] || { echo "❌ Error: check '$CFG_CHECK' it's missing or you do not have read permissions, exit"; exit 1; }
source "$CFG_CHECK"


# settings for Telegram notify script
# write token and ID in secrets file
ENV_PATH="/usr/local/etc/telegram/"
ENV_FILE="/usr/local/etc/telegram/secrets.env"

# create user for telegram-gateway script
if ! getent shadow telegram-gateway &> /dev/null; then
    run_and_check "create user for the Telegram gateway" useradd -r -M -d /nonexistent -s /usr/sbin/nologin telegram-gateway
else
    echo "✅ Success: user 'telegram-gateway' already exists"
fi

install_tg_secret() {
    try mkdir -p "$ENV_PATH"
    try tee "$ENV_FILE" > /dev/null <<EOF
BOT_TOKEN="$READ_BOT_TOKEN"
CHAT_ID="$READ_CHAT_ID"
EOF
    try chown telegram-gateway:telegram-gateway "$ENV_FILE"
    try chmod 600 "$ENV_FILE"
}
run_and_check "install secret file with token and ID for Telegram scripts" install_tg_secret


# user settings
# create ssh group for login
SSH_GROUP="ssh-users"
if ! getent group "$SSH_GROUP" &> /dev/null; then
    run_and_check "creating SSH group" addgroup "$SSH_GROUP"
else 
    echo "✅ Success: group $SSH_GROUP already exists"
fi

# create user and add in ssh and sudo group
if ! getent shadow "$SECOND_USER" &> /dev/null; then
    run_and_check "creating user and added to $SSH_GROUP and sudo groups" useradd -m -s /bin/bash -G sudo,"$SSH_GROUP" "$SECOND_USER"
else 
    echo "✅ Success: user $SECOND_USER already exists"
    run_and_check "added $SECOND_USER to $SSH_GROUP and sudo groups" usermod -aG sudo,"$SSH_GROUP" "$SECOND_USER"
fi

# changing password for root and user
conf_pswd() {
    printf 'root:%s\n%s:%s\n' "$PASS" "$SECOND_USER" "$PASS" | chpasswd
}

run_and_check "changing root and $SECOND_USER passwords" conf_pswd


# SSH Configuration
# variables and port generation
SSH_CONF_SOURCE="cfg/ssh.cfg"
SSH_CONF_DEST="/etc/ssh/sshd_config.d/00-custom_security.conf"
LOW="40000"
HIGH="50000"
PORT="$(shuf -i "${LOW}-${HIGH}" -n 1)"

# deleting previous sshd configuration with high priority
if compgen -G "/etc/ssh/sshd_config.d/00*.conf" &> /dev/null; then
    run_and_check "deleting previous sshd configuration files" rm -f /etc/ssh/sshd_config.d/00*.conf
else
    echo "✅ Success: previous sshd configurations files not found"
fi

# creating a new sshd configuration
install_sshd() {
    try install -m 644 -o root -g root "$SSH_CONF_SOURCE" "$SSH_CONF_DEST"
    try sed -i "s/{PORT}/$PORT/g" "$SSH_CONF_DEST"
    try rm -f /etc/ssh/ssh_host_ecdsa_key
    try rm -f /etc/ssh/ssh_host_ecdsa_key.pub
    try rm -f /etc/ssh/ssh_host_rsa_key
    try rm -f /etc/ssh/ssh_host_rsa_key.pub
}
run_and_check "install new sshd configuration" install_sshd

# found second user home directory
USER_HOME="$(getent passwd "$SECOND_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
KEY_NAME="authorized_keys"
PRIV_KEY_PATH="${SSH_DIR}/${KEY_NAME}"
PUB_KEY_PATH="${PRIV_KEY_PATH}.pub"
USER_GROUP="$(id -gn "$SECOND_USER")"

# key generation for ssh
install_sshd_key() {
    try mkdir -p "$SSH_DIR"
    try rm -f "$PRIV_KEY_PATH"
    try ssh-keygen -t ed25519 -N "" -f "$PRIV_KEY_PATH" -q
    PRIV_KEY="$(cat "$PRIV_KEY_PATH")"
    try rm -f "$PRIV_KEY_PATH"
    try chmod 700 "$SSH_DIR"
    try chmod 600 "$PUB_KEY_PATH"
    try chown -R "$SECOND_USER:$USER_GROUP" "$SSH_DIR"
}
run_and_check "install new sshd keys" install_sshd_key


# reboot SSH
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "restart sshd" systemctl restart ssh.socket


# Install ssh login/logout notify and disable MOTD
# install log directory
install_tg_dir() {
    try mkdir -p /var/log/telegram
    try chmod 755 /var/log/telegram
    try chown telegram-gateway:telegram-gateway "/var/log/telegram"
    try mkdir -p /var/log/service
    try chmod 755 /var/log/service
    try chown telegram-gateway:telegram-gateway "/var/log/service"
    try mkdir -p /usr/local/bin/telegram
    try mkdir -p /usr/local/bin/service
}

run_and_check "creating directory for all telegram script and log" install_tg_dir

# install ssh pam script and enable script in PAM
SSH_PAM_NOTIFY_SCRIPT_SOURCE=script/ssh_pam_notify.sh
SSH_PAM_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/ssh_pam_notify.sh"
install_scr_ssh_pam() {
    try install -m 755 -o root -g root "$SSH_PAM_NOTIFY_SCRIPT_SOURCE" "$SSH_PAM_NOTIFY_SCRIPT_DEST"
    if ! grep -q "ssh-pam-telegram-notify" "/etc/pam.d/sshd"; then
        try tee -a /etc/pam.d/sshd > /dev/null <<EOF

# ssh-pam-telegram-notify
# Notify for success ssh login and logout via telegram bot
session optional pam_exec.so seteuid $SSH_PAM_NOTIFY_SCRIPT_DEST
EOF
    fi
}
run_and_check "ssh PAM notification script installation" install_scr_ssh_pam

# Disable message of the day
MOTD="/etc/pam.d/sshd"
run_and_check "disable MOTD in PAM setting" sed -ri 's/^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$/# \1/' "$MOTD"


# Install and setup fail2ban
install_with_retry "install fail2ban package" apt-get install -y fail2ban
F2B_CONF_SOURCE="cfg/jail.local"
F2B_CONF_DEST="/etc/fail2ban/jail.local"
TG_LOCAL_SOURCE="cfg/ssh_telegram.local"
TG_LOCAL_DEST="/etc/fail2ban/action.d/ssh_telegram.local"
conf_f2b() {
    try install -m 644 -o root -g root "$F2B_CONF_SOURCE" "$F2B_CONF_DEST"
    try sed -i "s/{PORT}/$PORT/g" "$F2B_CONF_DEST"
    try install -m 644 -o root -g root "$TG_LOCAL_SOURCE" "$TG_LOCAL_DEST"
}
run_and_check "install fail2ban configuration" conf_f2b

# Install ssh ban notify script
SSH_F2B_NOTIFY_SCRIPT_SOURCE="script/ssh_f2b_notify.sh"
SSH_F2B_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/ssh_f2b_notify.sh"
run_and_check "ssh f2b notification script installation" install -m 755 -o root -g root "$SSH_F2B_NOTIFY_SCRIPT_SOURCE" "$SSH_F2B_NOTIFY_SCRIPT_DEST"
# Start fail2ban
start_f2b() {
    try systemctl -q enable --now fail2ban.service
    try systemctl restart fail2ban.service
}
run_and_check "enable and start fail2ban service" start_f2b


# make BBR appear in "available" list (if it's a module)
modprobe tcp_bbr &>/dev/null || true

bbr_on() {
    try tee /etc/sysctl.d/99-bbr.conf > /dev/null <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    try echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    try sysctl --system &> /dev/null
}

# check availability
BBR_AVAILABLE="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
if ! grep -qw bbr <<<"$BBR_AVAILABLE"; then
    echo "⚠️  Non-critical error: BBR not available (net.ipv4.tcp_available_congestion_control = '${BBR_AVAILABLE}')"
else
    run_and_check "enable BBR" bbr_on
    
fi

# unattended upgrade and reboot script
install_with_retry "install unattended upgrades package" apt-get install -y unattended-upgrades

conf_un_up() {
    try tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    try systemctl disable --now apt-daily.timer apt-daily-upgrade.timer > /dev/null
}
run_and_check "changing unattended upgrades settings" conf_un_up

UNATTENDED_UPGRADE_SCRIPT_SOURCE="script/unattended_upgrade.sh"
UNATTENDED_UPGRADE_SCRIPT_DEST="/usr/local/bin/service/unattended_upgrade.sh"
un_up_scr() {
    try install -m 755 -o root -g root "$UNATTENDED_UPGRADE_SCRIPT_SOURCE" "$UNATTENDED_UPGRADE_SCRIPT_DEST"
    try tee /etc/cron.d/unattended-upgrade > /dev/null <<EOF
SHELL=/bin/bash
1 3 1 * * root "$UNATTENDED_UPGRADE_SCRIPT_DEST" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/unattended-upgrade"
}
run_and_check "security update script installation" un_up_scr


# boot notify script via Telegram
BOOT_SCRIPT_SOURCE="script/boot_notify.sh"
BOOT_SCRIPT_DEST="/usr/local/bin/telegram/boot_notify.sh"

install_scr_boot() {
    try install -m 755 -o root -g root "$BOOT_SCRIPT_SOURCE" "$BOOT_SCRIPT_DEST"
    try tee /etc/systemd/system/boot_notify.service > /dev/null <<EOF
[Unit]
Description=Telegram notify after boot
Wants=network-online.target
After=network-online.target

[Service]
User=telegram-gateway
Group=telegram-gateway
Type=oneshot
Restart=no
ExecStart=$BOOT_SCRIPT_DEST

[Install]
WantedBy=multi-user.target
EOF
    try systemctl daemon-reload
    try systemctl -q enable boot_notify.service
}

run_and_check "server boot notification script installation" install_scr_boot


# xray install
# create user for xray
if ! getent shadow xray &> /dev/null; then
    run_and_check "create user for the xray service" useradd -r -M -d /nonexistent -s /usr/sbin/nologin xray
else 
    echo "✅ Success: user 'xray' already exists"
fi

install_xray_dir() {
    try mkdir -p /usr/local/share/xray
    try chmod 755 /usr/local/share/xray
    try mkdir -p /usr/local/etc/xray
    try chmod 770 /usr/local/etc/xray
    try chown xray:telegram-gateway /usr/local/etc/xray
    try mkdir -p /var/log/xray
    try chmod 770 /var/log/xray
    try chown xray:telegram-gateway /var/log/xray
    TMP_DIR="$(mktemp -d)"
    readonly TMP_DIR
}
run_and_check "create directory for the xray service" install_xray_dir

# download function
_dl() { curl -fsSL --max-time 60 "$1" -o "$2"; }

_dl_with_retry() {
    local url="$1"
    local outfile="$2"
    local label="$3"
    local attempt=1

    while true; do
        echo "📢 Info: download ${label}, attempt ${attempt}, please wait"
        if ! _dl "$url" "$outfile"; then
            if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
                echo "❌ Error: download ${label} after ${attempt} attempts, exit"
                return 1
            fi
            sleep 60
            (($attempt++))
            continue
        else
            echo "✅ Success: download ${label} after ${attempt} attempts"
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

    # download main file
    _dl_with_retry "$url" "$outfile" "$name" || exit 1

    # download checksum depending on the name there are two ways
    # download .dgst checksum if name xray
    if [ "$name" = "xray" ]; then
        _dl_with_retry "${url}.dgst" "$dgst_file" "${name}.dgst" || exit 1
    # download checksum if other name (geoip.dat, geosite.dat)
    else
        _dl_with_retry "${url}.sha256sum" "$sha256sum_file" "${name}.sha256sum" || exit 1
    fi

# extract sha256sum from .dgst or .sha256sum depending on the name there are two ways
# reset sha
    expected_sha=""
# extract sha256sum from .dgst if name xray
        if [ "$name" = "xray" ]; then
            expected_sha="$(awk '/^SHA2-256/ {print $2}' "$dgst_file")"
            if [ -z "$expected_sha" ]; then
                echo "❌ Error: parse SHA256 from ${dgst_file}, exit"
                exit 1
            else
                echo "✅ Success: parse SHA256 from ${dgst_file}"
            fi
# extract sha256sum from .sha256sum if other name (geoip.dat, geosite.dat)
        else
            expected_sha="$(awk '{print $1}' "$sha256sum_file" 2>/dev/null)"
            if [ -z "$expected_sha" ]; then
                echo "❌ Error: parse SHA256 from ${sha256sum_file}, exit"
                exit 1
            else
                echo "✅ Success: parse SHA256 from ${sha256sum_file}"
            fi
        fi

# extract actual sha256sum from .zip or .dat
# reset sha
        actual_sha=""
            actual_sha="$(sha256sum "$outfile" 2>/dev/null | awk '{print $1}')"
            if [ -z "$actual_sha" ]; then
                echo "❌ Error: extract SHA256 from ${outfile}, exit"
                exit 1
            else
                echo "✅ Success: extraction SHA256 from ${outfile}"
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
        echo "📢 Info: expected SHA256 from ${expected_label}: $expected_sha"
        echo "📢 Info: actual SHA256 from ${actual_label}: $actual_sha"
        echo "❌ Error: compare, actual and expected SHA256 do not match for ${name}, exit"
        exit 1
    else
        echo "📢 Info: expected SHA256 from ${expected_label}: $expected_sha"
        echo "📢 Info: actual SHA256 from ${actual_label}: $actual_sha"
        echo "✅ Success: actual and expected SHA256 match for ${name}"
    fi

# unzip archive if name xray
    if [ "$name" = "xray" ]; then

# unpack archive
        if ! mkdir -p "$UNPACK_DIR"; then
            echo "❌ Error: create directory for unpacking ${outfile}, exit"
            exit 1
        else
            echo "✅ Success: directory for unpacking ${outfile} has been created"
        fi
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" &> /dev/null; then
            echo "❌ Error: extract ${outfile}, exit"
            exit 1
        else
            echo "✅ Success: ${outfile} successfully extracted"
        fi
# check xray binary
        if [ ! -f "$UNPACK_DIR/xray" ]; then
            echo "❌ Error: xray binary is missing from folder after unpacking ${outfile}, exit"
            exit 1
        else
            echo "✅ Success: xray binary exists in the folder after unpacking ${outfile}"
        fi
    fi

    return 0
}

readonly XRAY_URL="https://github.com/XTLS/xray-core/releases/latest/download/xray-linux-64.zip"
readonly GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

download_and_verify "$XRAY_URL" "$TMP_DIR/xray-linux-64.zip" "xray"
download_and_verify "$GEOIP_URL" "$TMP_DIR/geoip.dat" "geoip.dat"
download_and_verify "$GEOSITE_URL" "$TMP_DIR/geosite.dat" "geosite.dat"

run_and_check "install xray binary" install -m 755 -o root -g root $UNPACK_DIR/xray /usr/local/bin/xray
run_and_check "install geoip.dat" install -m 644 -o root -g root $TMP_DIR/geoip.dat /usr/local/share/xray/geoip.dat
run_and_check "install geosite.dat" install -m 644 -o root -g root $TMP_DIR/geosite.dat /usr/local/share/xray/geosite.dat

# configure xray service
XRAY_CONFIG_SRC="cfg/config.json"
XRAY_CONFIG_DEST="/usr/local/etc/xray/config.json"

conf_xray() {
    try tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray-core VLESS server
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config $XRAY_CONFIG_DEST
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}
run_and_check "create xray systemd service" conf_xray

# calculate exp and created date
readonly CREATED="$(date +%F)"

# write variable
if [[ "$XRAY_DAYS" == "0" ]]; then
    XRAY_EMAIL="${XRAY_NAME}|created=${CREATED}|days=infinity|exp=never"
    XRAY_DAYS="infinity"
    EXP="never"
else
    EXP="$(date -d "$CREATED + $XRAY_DAYS days" +%F)"
    XRAY_EMAIL="${XRAY_NAME}|created=${CREATED}|days=${XRAY_DAYS}|exp=${EXP}"
fi

readonly INBOUND_TAG="Vless"
readonly DEFAULT_FLOW="xtls-rprx-vision"

# check inbound
readonly HAS_INBOUND="$(jq --arg tag "$INBOUND_TAG" '
  any(.inbounds[]?; .tag == $tag and .protocol == "vless")
' "$XRAY_CONFIG_SRC")"

if [[ "$HAS_INBOUND" != "true" ]]; then
  echo "❌ Error: config not have vless-inbound, tag=\"$INBOUND_TAG\", exit"
  exit 1
fi

readonly XRAY_BIN="/usr/local/bin/xray"
# uuid generation
if [[ -x "$XRAY_BIN" ]]; then
    readonly UUID="$("$XRAY_BIN" uuid)"
else
    echo "❌ Error: not found $XRAY_BIN, for UUID generation, exit"
    exit 1
fi

# configure json 
conf_json_xray() {

    XRAY_PORT="443"
    DEST="${XRAY_HOST}:${XRAY_PORT}"

    # key generation
    keys="$(xray x25519)"
    privateKey="$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keys")"
    publicKey="$(awk -F': ' '/Password/ {print $2}' <<<"$keys")"

    # shortId generation
    shortId="$(openssl rand -hex 8)"


    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)"
    try chmod 660 "$TMP_XRAY_CONFIG"
    try chown root:xray "$TMP_XRAY_CONFIG"
    trap 'rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"' EXIT
    
# update json
    try jq --arg tag   "$INBOUND_TAG" \
    --arg email "$XRAY_EMAIL" \
    --arg id    "$UUID" \
    --arg dflow "$DEFAULT_FLOW" \
    --arg dest  "$DEST" \
    --arg sni   "$XRAY_HOST" \
    --arg pk    "$privateKey" \
    --arg sid   "$shortId" '
    # Берём flow из первого клиента нужного inbound по tag (если нет — дефолт)
    ([.inbounds[]? | select(.tag==$tag and .protocol=="vless") | .settings.clients[0].flow?][0] // $dflow) as $flow

    | .inbounds |= map(
        if (.tag==$tag and .protocol=="vless") then

            # 1) Обновляем realitySettings ТОЛЬКО для этого tag (и если это reality)
            (if (.streamSettings.security?=="reality" and (.streamSettings.realitySettings?!=null)) then
            .streamSettings.realitySettings |= (
                .dest=$dest
                | .serverNames=[$sni]
                | .privateKey=$pk
                | .shortIds=[$sid]
            )
            else .
            end)

            # 2) Добавляем пользователя
            | (.settings = (.settings // {}))
            | (.settings.clients = (.settings.clients // []))
            | .settings.clients += [{
                "email": $email,
                "id":    $id,
                "flow":  $flow
            }]

        else .
        end
        )
    ' "$XRAY_CONFIG_SRC" > "$TMP_XRAY_CONFIG"
}

run_and_check "generate new config" conf_json_xray
run_and_check "new xray config checking" sudo -u xray xray run -test -config "$TMP_XRAY_CONFIG"
run_and_check "install new xray config" install -m 660 -o xray -g telegram-gateway "$TMP_XRAY_CONFIG" "$XRAY_CONFIG_DEST"
run_and_check "delete temporary xray files " rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"
trap - EXIT

# start xray
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "enable autostart xray service" systemctl -q enable xray.service
run_and_check "start xray service" systemctl start xray.service


# start make link, get inbound paremetres
readonly PORT="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .port
' "$XRAY_CONFIG")"

readonly REALITY_SNI="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.serverNames[0] // ""
' "$XRAY_CONFIG")"

readonly PRIVATE_KEY="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.privateKey // ""
' "$XRAY_CONFIG")"

readonly SHORT_ID="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.shortIds[0] // ""
' "$XRAY_CONFIG")"

readonly FLOW="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // ""
' "$XRAY_CONFIG")"

check_var() {
    local name="$1"
    local value="${!name}"
    if [ -z "$value" ]; then
        echo "❌ Error: $name not found in realitySettings inbound"
        exit 1
    fi
}

check_var PORT
check_var REALITY_SNI
check_var PRIVATE_KEY
check_var SHORT_ID
check_var FLOW

# generate public key from privat key
readonly XRAY_X25519_OUT="$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY")"

readonly PUBLIC_KEY="$(printf '%s\n' "$XRAY_X25519_OUT" | awk -F': ' '/Password:/ {print $2}')"

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "❌ Error: empty publicKey/password, exit"
  exit 1
fi

# get server ip
SERVER_HOST="$(curl -4 -s https://ifconfig.io || curl -4 -s https://ipinfo.io/ip || echo "")"

if [ -z "$SERVER_HOST" ]; then
    SERVER_HOST="SERVER_IP"  # плейсхолдер, если не смогли определить
fi

# make uri link
uri_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

QUERY="encryption=none"
QUERY="${QUERY}&flow=$(uri_encode "$FLOW")"
QUERY="${QUERY}&security=reality"
QUERY="${QUERY}&type=tcp"
QUERY="${QUERY}&sni=$(uri_encode "$REALITY_SNI")"
QUERY="${QUERY}&fp=$(uri_encode "chrome")"
QUERY="${QUERY}&pbk=$(uri_encode "$PUBLIC_KEY")"
QUERY="${QUERY}&sid=$(uri_encode "$SHORT_ID")"
readonly NAME_ENC="$(uri_encode "$XRAY_NAME")"
readonly VLESS_URI="vless://${UUID}@${SERVER_HOST}:${PORT}/?${QUERY}#${NAME_ENC}"
readonly URI_PATH="/usr/local/etc/xray/URI_DB"

# print result
touch "$URI_PATH"
chmod 600 "$URI_PATH"
chown telegram-gateway:telegram-gateway "$URI_PATH"
tee -a "$URI_PATH" > /dev/null <<EOF
name: $XRAY_NAME, created: $CREATED, days: $XRAY_DAYS, expiration: $EXP
name: $XRAY_NAME, vless link: $VLESS_URI

EOF

# auto update xray and geobase
XRAY_SCRIPT_SOURCE="script/xray_update.sh"
XRAY_SCRIPT_DEST="/usr/local/bin/service/xray_update.sh"

install_scr_xr_up() {
    try install -m 755 -o root -g root "$XRAY_SCRIPT_SOURCE" "$XRAY_SCRIPT_DEST"
    try tee /etc/cron.d/xray_update > /dev/null <<EOF
SHELL=/bin/bash
1 2 1 * * root "$XRAY_SCRIPT_DEST" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/xray_update"
}
run_and_check "xray and geo*.dat update script installation" install_scr_xr_up


# user stat DB
XRAY_STAT_SCRIPT_SRC="script/xray_stat.sh"
XRAY_STAT_SCRIPT_DEST="/usr/local/bin/service/xray_stat.sh"

install_scr_xray_stat() {
    try install -m 755 -o root -g root "$XRAY_STAT_SCRIPT_SRC" "$XRAY_STAT_SCRIPT_DEST"
    try tee /etc/cron.d/xray_stat > /dev/null <<EOF
SHELL=/bin/bash
0 * * * * telegram-gateway "$XRAY_STAT_SCRIPT_DEST" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/xray_stat"
}
run_and_check "xray statistic script installation" install_scr_xray_stat


# user, server traffic + user exp date Telegram bot notify
USER_NOTIFY_SCRIPT_SOURCE="script/user_notify.sh"
USER_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/user_notify.sh"
install_scr_user() {
    try install -m 755 -o root -g root "$USER_NOTIFY_SCRIPT_SOURCE" "$USER_NOTIFY_SCRIPT_DEST"
    try tee /etc/cron.d/user_notify > /dev/null <<EOF
SHELL=/bin/bash
1 1 * * * telegram-gateway "$USER_NOTIFY_SCRIPT_DEST" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/user_notify"
}
run_and_check "user daily report script installation" install_scr_user


# autoblock exp users + Telegram bot notify
AUTOBLOCK_SCRIPT_SOURCE="script/autoblock.sh"
AUTOBLOCK_SCRIPT_DEST="/usr/local/bin/service/autoblock.sh"
install_scr_autoblock() {
    try install -m 755 -o root -g root "$AUTOBLOCK_SCRIPT_SOURCE" "$AUTOBLOCK_SCRIPT_DEST"
    try tee /etc/cron.d/autoblock > /dev/null <<EOF
SHELL=/bin/bash
1 0 * * * telegram-gateway "$AUTOBLOCK_SCRIPT_DEST" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/autoblock"
}
run_and_check "autoblock exp user script installation" install_scr_autoblock


# xray backup Telegram bot notify
XRAY_BACKUP_SCRIPT_SOURCE="script/xray_backup.sh"
XRAY_BACKUP_SCRIPT_DEST="/usr/local/bin/service/xray_backup.sh"
install_scr_xray_backup() {
    try install -m 755 -o root -g root "$XRAY_BACKUP_SCRIPT_SOURCE" "$XRAY_BACKUP_SCRIPT_DEST"
    try tee /etc/cron.d/xray_backup > /dev/null <<'EOF'
SHELL=/bin/bash
0 23 28-31 * * telegram-gateway [ "$(date -d tomorrow +\%d)" = "01" ] && "/usr/local/bin/service/xray_backup.sh" &> /dev/null
EOF
    try chmod 644 "/etc/cron.d/xray_backup"
}
run_and_check "xray backup script installation" install_scr_xray_backup


# maintance script
USERADD_SCRIPT_SRC="script/useradd.sh"
USERADD_SCRIPT_DEST="/usr/local/bin/service/useradd.sh"
USERDEL_SCRIPT_SRC="script/userdel.sh"
USERDEL_SCRIPT_DEST="/usr/local/bin/service/userdel.sh"
USEREXP_SCRIPT_SRC="script/userexp.sh"
USEREXP_SCRIPT_DEST="/usr/local/bin/service/userexp.sh"
USERBLOCK_SCRIPT_SRC="script/userblock.sh"
USERBLOCK_SCRIPT_DEST="/usr/local/bin/service/userblock.sh"
USERSHOW_SCRIPT_SRC="script/usershow.sh"
USERSHOW_SCRIPT_DEST="/usr/local/bin/service/usershow.sh"
SYS_INFO_SCRIPT_SRC="script/system_info.sh"
SYS_INFO_SCRIPT_DEST="/usr/local/bin/service/system_info.sh"

# add link for maintance
install_scr_service() {
    try install -m 755 -o root -g root "$USERADD_SCRIPT_SRC" "$USERADD_SCRIPT_DEST"
    try install -m 755 -o root -g root "$USERDEL_SCRIPT_SRC" "$USERDEL_SCRIPT_DEST"
    try install -m 755 -o root -g root "$USEREXP_SCRIPT_SRC" "$USEREXP_SCRIPT_DEST"
    try install -m 755 -o root -g root "$USERBLOCK_SCRIPT_SRC" "$USERBLOCK_SCRIPT_DEST"
    try install -m 755 -o root -g root "$USERSHOW_SCRIPT_SRC" "$USERSHOW_SCRIPT_DEST"
    try install -m 755 -o root -g root "$SYS_INFO_SCRIPT_SRC" "$SYS_INFO_SCRIPT_DEST"
    try ln -sfn "$USERADD_SCRIPT_DEST" "$USER_HOME/xray_user_add"
    try ln -sfn "$USERDEL_SCRIPT_DEST" "$USER_HOME/xray_user_del"
    try ln -sfn "$USEREXP_SCRIPT_DEST" "$USER_HOME/xray_user_exp"
    try ln -sfn "$USERBLOCK_SCRIPT_DEST" "$USER_HOME/xray_user_block"
    try ln -sfn "$USERSHOW_SCRIPT_DEST" "$USER_HOME/xray_user_show"

    try find "$USER_HOME" -type l -exec chown -h $SECOND_USER:$SECOND_USER {} +
}
run_and_check "install service script and create link in home directory" install_scr_service


# Telegram gateway script
TG_GATEWAY_SCRIPT_SRC="script/telegram-gateway.sh"
TG_GATEWAY_SCRIPT_DEST="/usr/local/bin/service/telegram-gateway.sh"

# /etc/systemd/system/telegram-gateway.service
conf_tg_gateway() {
    try install -m 755 -o root -g root "$TG_GATEWAY_SCRIPT_SRC" "$TG_GATEWAY_SCRIPT_DEST"
    try tee /etc/systemd/system/telegram-gateway.service > /dev/null <<EOF
[Unit]
Description=Telegram gateway bot
After=network-online.target
Wants=network-online.target

[Service]
User=telegram-gateway
Group=telegram-gateway

ExecStart=$TG_GATEWAY_SCRIPT_DEST
Restart=always
RestartSec=5

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF

    try tee /etc/polkit-1/rules.d/50-telegram-gateway.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  // Разрешаем пользователю telegram-gateway только restart для xray.service
    if (subject.user === "telegram-gateway" &&
        action.id === "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") === "xray.service" &&
        action.lookup("verb") === "restart") {
    return polkit.Result.YES;
    }

  // Разрешаем пользователю telegram-gateway reboot
    if (subject.user === "telegram-gateway" &&
        (action.id === "org.freedesktop.login1.reboot" ||
        action.id === "org.freedesktop.login1.reboot-multiple-sessions")) {
    return polkit.Result.YES;
    }
});
EOF
}

# start Telegram gateway
run_and_check "create Telegram gateway service" conf_tg_gateway
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "enable autostart Telegram gateway service" systemctl -q enable telegram-gateway.service
run_and_check "start Telegram gateway service" systemctl start telegram-gateway.service


# final output
echo "#################################################"
echo ""
echo "################## PRIVATE KEY ##################"
echo ""
echo "$PRIV_KEY"
echo ""
echo "########## PUBLIC KEY - $PUB_KEY_PATH ##########"
echo ""
cat "$PUB_KEY_PATH"
echo ""
echo "########## SSH server port - ${PORT} ##########"
echo ""
echo "#################################################"
echo ""
cat "$URI_PATH"
echo "#################################################"