#!/bin/bash
# installation script

#
# main variables
MAX_ATTEMPTS=3

# done
# root checking
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: You not root user, exit"
    exit 1
else
    echo "✅ Success: You root user, continued"
fi

# done
# check another instanse of the script is not running
umask 022
readonly LOCK_FILE="/var/run/vpn_install.lock"
exec 9> "$LOCK_FILE" || { sleep 1; echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n 9 || { sleep 1; echo "❌ Error: another instance is running, exit"; exit 1; }


# 
# Helping functions
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

install_with_retry() {
    local action="$1"
    local attempt=1
    shift 1

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first one)
        if "$@"; then
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

run_and_check() {
    action="$1"
    shift 1
    if "$@"; then
        echo "✅ Success: $action"
        return 0
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}


# done
# check configuration file
CFG_CHECK="module/cfg_check.sh"
[[ -r "$CFG_CHECK" ]] || { sleep 1; echo "❌ Error: check '$CFG_CHECK' it's missing or you do not have read permissions, exit"; exit 1; }
source "$CFG_CHECK"


# done
# Pred install system configuration
# Write token and id in secrets file
ENV_PATH="/usr/local/etc/telegram/"
ENV_FILE="/usr/local/etc/telegram/secrets.env"
run_and_check "create directory for telegram scripts settings" mkdir -p $ENV_PATH
run_and_check "create secret file for telegram scripts" tee $ENV_FILE > /dev/null << EOF
BOT_TOKEN="$READ_BOT_TOKEN"
CHAT_ID="$READ_CHAT_ID"
EOF
run_and_check "set permissions on a secret file" chmod 600 "$ENV_FILE"

# create ssh group for login
SSH_GROUP="ssh-users"
if ! getent group "$SSH_GROUP" >/dev/null 2>&1; then
    run_and_check "adding SSH group" addgroup "$SSH_GROUP"
else 
    echo "✅ Success: group $SSH_GROUP already exists"
fi

# create user and add in ssh and sudo group
run_and_check "creating user and added to $SSH_GROUP and sudo groups" useradd -m -s /bin/bash -G sudo,"$SSH_GROUP" "$SECOND_USER"

# changing password for root and user
run_and_check "root and $SECOND_USER passwords change" printf 'root:%s\n%s:%s\n' "$PASS" "$SECOND_USER" "$PASS" | chpasswd


# done
# SSH Configuration
# variables
SSH_CONF_SOURCE="/cfg/ssh.cfg"
SSH_CONF_DEST="/etc/ssh/sshd_config.d/99-custom_security.conf"
LOW="40000"
HIGH="50000"

# port generation [40000,50000]
PORT="$(shuf -i "${LOW}-${HIGH}" -n 1)"

# deleting previous sshd configuration with high priority
if compgen -G "/etc/ssh/sshd_config.d/99*.conf" > /dev/null; then
run_and_check "deleting previous conflicting sshd configuration files" rm -f /etc/ssh/sshd_config.d/99*.conf
else
    echo "✅ Success: conflicting sshd configurations files not found"
fi

# creating a new sshd configuration
run_and_check "creating a new sshd configuration" install -m 644 -o root -g root "$SSH_CONF_SOURCE" "$SSH_CONF_DEST"

# insert port in ssh config
sed -i "s/{PORT}/$PORT/g" "$SSH_CONF_DEST" || { echo "❌ Error: set port in ssh configuration, exit"; exit 1; }

# Delete disabled key
run_and_check "remove old not secure host ssh keys" rm -f /etc/ssh/ssh_host_ecdsa_key && \
rm -f /etc/ssh/ssh_host_ecdsa_key.pub && \
rm -f /etc/ssh/ssh_host_rsa_key && \
rm -f /etc/ssh/ssh_host_rsa_key.pub

# found second user home directory
USER_HOME="$(getent passwd "$SECOND_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
KEY_NAME="authorized_keys"
PRIV_KEY_PATH="${SSH_DIR}/${KEY_NAME}"
PUB_KEY_PATH="${PRIV_KEY_PATH}.pub"

# create .ssh folder
run_and_check "creating directory for ssh keys" mkdir "$SSH_DIR"

# key generation for ssh
run_and_check "generating ssh key" ssh-keygen -t ed25519 -N "" -f "$PRIV_KEY_PATH" -q

# Права и владелец
run_and_check "set permission to ssh directory and file" chmod 700 "$SSH_DIR" && \
chmod 600 "$PRIV_KEY_PATH" "$PUB_KEY_PATH" && \
USER_GROUP="$(id -gn "$SECOND_USER")" && \
chown -R "$SECOND_USER:$USER_GROUP" "$SSH_DIR"

# reboot SSH
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "restart sshd" systemctl restart ssh.socket


# done
# Install ssh login/logout notify and disable MOTD
# install log directory
run_and_check "creating directory for all telegram script log" mkdir /var/log/telegram
# install script
SSH_ENTER_NOTIFY_SCRIPT_SOURCE=script/ssh_enter_notify.sh
SSH_ENTER_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/ssh_enter_notify.sh"
run_and_check "ssh enter notification script installation" install -m 700 -o root -g root "$SSH_ENTER_NOTIFY_SCRIPT_SOURCE" "$SSH_ENTER_NOTIFY_SCRIPT_DEST"
# enable script in PAM
run_and_check "enable enter notification script in PAM setting" tee /etc/pam.d/sshd >/dev/null <<EOF
# Notify for success ssh login and logout via telegram bot
session optional pam_exec.so seteuid $SSH_ENTER_NOTIFY_SCRIPT_DEST
EOF
# Disable message of the day
MOTD="/etc/pam.d/sshd"
run_and_check "disable MOTD in PAM setting" sed -ri 's/^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$/# \1/' "$MOTD"


# done
# Install and setup fail2ban
install_with_retry "install fail2ban package" apt-get install -y fail2ban
# Install ssh jail
F2B_CONF_SOURCE="cfg/jail.local"
F2B_CONF_DEST="/etc/fail2ban/jail.local"
run_and_check "fail2ban jail iptables + telegram configuration installation" install -m 644 -o root -g root "$F2B_CONF_SOURCE" "$F2B_CONF_DEST" && sed -i "s/{PORT}/$PORT/g" "$F2B_CONF_DEST"
# Install ssh action
TG_LOCAL_SOURCE="cfg/ssh_telegram.local"
TG_LOCAL_DEST="/etc/fail2ban/action.d/ssh_telegram.local"
run_and_check "fail2ban telegram action installation" install -m 644 -o root -g root "$TG_LOCAL_SOURCE" "$TG_LOCAL_DEST"
# Install ssh ban notify script
SSH_BAN_NOTIFY_SCRIPT_SOURCE="script/ssh_ban_notify.sh"
SSH_BAN_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/ssh_ban_notify.sh"
run_and_check "telegram notification ban/unban script installation" install -m 700 -o root -g root "$SSH_BAN_NOTIFY_SCRIPT_SOURCE" "$SSH_BAN_NOTIFY_SCRIPT_DEST"
# Start fail2ban
run_and_check "enable and start fail2ban service" systemctl enable --now fail2ban


# done
# server + user traffic telegram bot notify
TRAFFIC_NOTIFY_SCRIPT_SOURCE="script/traffic_notify.sh"
TRAFFIC_NOTIFY_SCRIPT_DEST="/usr/local/bin/telegram/traffic_notify.sh"
run_and_check "traffic notification script installation" install -m 700 -o root -g root "$TRAFFIC_NOTIFY_SCRIPT_SOURCE" "$TRAFFIC_NOTIFY_SCRIPT_DEST"

run_and_check "enabling traffic notification script execution scheduler" tee /etc/cron.d/traffic_notify >/dev/null <<EOF
SHELL=/bin/bash
0 1 * * * root "$TRAFFIC_NOTIFY_SCRIPT_DEST" &> /dev/null
EOF

chmod 644 "/etc/cron.d/traffic_notify" || { echo "❌ Error: set permissions on task scheduler file, exit"; exit 1; }


# done
# unattended upgrade and reboot script
install_with_retry "install unattended upgrades package" apt-get install -y unattended-upgrades

run_and_check "changing package settings" tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

run_and_check "disable default update timer" systemctl disable --now apt-daily.timer apt-daily-upgrade.timer

UNATTENDED_UPGRADE_SCRIPT_SOURCE="script/unattended_upgrade.sh"
UNATTENDED_UPGRADE_SCRIPT_DEST="/usr/local/bin/service/unattended_upgrade.sh"
run_and_check "security update script installation" install -m 700 -o root -g root "$UNATTENDED_UPGRADE_SCRIPT_SOURCE" "$UNATTENDED_UPGRADE_SCRIPT_DEST"

run_and_check "enabling security update script execution scheduler" tee /etc/cron.d/unattended-upgrade >/dev/null <<EOF
SHELL=/bin/bash
0 3 1 * * root "$UNATTENDED_UPGRADE_SCRIPT_DEST" &> /dev/null
EOF

chmod 644 "/etc/cron.d/unattended-upgrade" || { echo "❌ Error: set permissions on task scheduler file, exit"; exit 1; }


# done
# boot notify script via Telegram
BOOT_SCRIPT_SOURCE="script/boot_notify.sh"
BOOT_SCRIPT_DEST="/usr/local/bin/telegram/boot_notify.sh"

run_and_check "server boot notification script installation" install -m 700 -o root -g root "$BOOT_SCRIPT_SOURCE" "$BOOT_SCRIPT_DEST"

run_and_check "create systemd service for server boot notification script" tee /etc/systemd/system/boot_notify.service > /dev/null <<'EOF'
[Unit]
Description=Telegram notify after boot
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Restart=no
ExecStart=/usr/local/bin/boot_notify.sh

[Install]
WantedBy=multi-user.target
EOF

run_and_check "reload systemd" systemctl daemon-reload
run_and_check "enable server boot notification service" systemctl enable boot_notify.service


# done
# xray install
run_and_check "create user for the xray service" useradd -r -M -d /nonexistent -s /usr/sbin/nologin xray

run_and_check "create directory for the xray service" mkdir -p /usr/local/share/xray && mkdir -p /usr/local/etc/xray \
    && mkdir -p /var/log/xray && chown xray:xray /var/log/xray

TMP_DIR="$(mktemp -d)" || { echo "❌ Error: to create temporary directory, exit"; exit 1; }
readonly TMP_DIR

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
        if ! unzip -o "$outfile" -d "$UNPACK_DIR" >/dev/null 2>&1; then
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
run_and_check "install geoip.dat" -m 644 -o root -g root $TMP_DIR/geoip.dat /usr/local/share/xray/geoip.dat
run_and_check "install geosite.dat" -m 644 -o root -g root $TMP_DIR/geosite.dat /usr/local/share/xray/geosite.dat

# configure xray service
XRAY_CONFIG_SRC="cfg/config.json"
XRAY_CONFIG_DEST="/usr/local/etc/xray/config.json"

run_and_check "create xray systemd service" tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray-core VLESS server
After=network-online.target

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

# configure json 
XRAY_PORT="443"
DEST="${XRAY_HOST}:${XRAY_PORT}"

# key generation
keys="$(xray x25519)"
privateKey="$(awk -F': ' '/Private key/ {print $2}' <<<"$keys")"
publicKey="$(awk -F': ' '/Password:/ {print $2}' <<<"$keys")"

# shortId generation
shortId="$(openssl rand -hex 8)"

# update json
TMP_XRAY_CONFIG="$(mktemp)"
jq --arg dest "$DEST" \
   --arg sni  "$XRAY_HOST" \
   --arg pk   "$privateKey" \
   --arg sid  "$shortId" '
  .inbounds |= (map(
    if (.protocol=="vless" and (.streamSettings.security?=="reality") and (.streamSettings.realitySettings?!=null))
    then .streamSettings.realitySettings |= (
      .dest=$dest
      | .serverNames=[$sni]
      | .privateKey=$pk
      | .shortIds=[$sid]
    )
    else .
    end
  ))
' "$XRAY_CONFIG_SRC" > "$TMP_XRAY_CONFIG"


trap 'rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"' EXIT
run_and_check "xray config checking" xray run -test -config "$TMP_XRAY_CONFIG" >/dev/null
run_and_check "install xray config" install -m 600 -o xray -g xray "$TMP_XRAY_CONFIG" "$XRAY_CONFIG_DEST"
run_and_check "delete temporary xray files " rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"

bash script/useradd.sh "$XRAY_NAME" "$XRAY_DAYS" 0

# Запускаем сервер
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "enable xray service" systemctl enable --now xray.service


# done
# auto update xray and geobase
GEODAT_SCRIPT_SOURCE="script/geodat_update.sh"
GEODAT_SCRIPT_DEST="/usr/local/bin/service/geodat_update.sh"
run_and_check "xray and geo*.dat update script installation" install -m 700 -o root -g root "$GEODAT_SCRIPT_SOURCE" "$GEODAT_SCRIPT_DEST"
# turn on script in cron
run_and_check "enabling xray and geo*.dat update script execution scheduler" tee /etc/cron.d/geodat_update > /dev/null << EOF
SHELL=/bin/bash
0 2 1 * * root "$GEODAT_SCRIPT_DEST" &> /dev/null
EOF
chmod 644 "/etc/cron.d/geodat_update" || { echo "❌ Error: set permissions on task scheduler file, exit"; exit 1; }


# done
echo "#################################################"
echo
echo "########## PRIVATE KEY - $PRIV_KEY_PATH ##########"
echo
cat "$PRIV_KEY_PATH"
echo
echo "########## PUBLIC KEY - $PUB_KEY_PATH ##########"
echo
cat "$PUB_KEY_PATH"
echo
echo "########## SSH server port - ${PORT} ##########"
echo
echo "#################################################"
echo
cat URI