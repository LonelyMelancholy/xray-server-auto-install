#!/bin/bash
# installation script


# root checking
[[ $EUID -ne 0 ]] && { echo "❌ Error: you are not the root user, exit"; exit 1; }

# cd intro script folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# check another instanse of the script is not running
readonly LOCK_FILE="/run/lock/vpn_install.lock"
exec {fd}> "$LOCK_FILE" || { echo "❌ Error: cannot open lock file '$LOCK_FILE', exit"; exit 1; }
flock -n ${fd} || { echo "❌ Error: another instance is running, exit"; exit 1; }


# main variables
MAX_ATTEMPTS=3
export NEEDRESTART_SUSPEND=1

# install helping function
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

# run helping function
run_and_check() {
    local action="$1"
    shift 1
    if "$@" > /dev/null; then
        echo "✅ Success: $action"
    else
        echo "❌ Error: $action, exit"
        exit 1
    fi
}


# check configuration file
CFG_CHECK="module/cfg_check.lib.sh"
[[ -r "$CFG_CHECK" ]] || { echo "❌ Error: check '$CFG_CHECK' it's missing or you do not have read permissions, exit"; exit 1; }
# shellcheck source=module/cfg_check.lib.sh
source "$CFG_CHECK" || { echo "❌ Error: failed to source '$CFG_CHECK', exit"; exit 1; }


# settings for Telegram notify script
# write token and ID in secrets file
ENV_PATH="/usr/local/etc/telegram/"
ENV_FILE="/usr/local/etc/telegram/secrets.env"

# create user for telegram_gateway script
if ! getent shadow telegram_gateway &> /dev/null; then
    run_and_check "create user for the Telegram gateway" useradd -r -M -d /nonexistent -s /usr/sbin/nologin telegram_gateway
else
    echo "✅ Success: user 'telegram_gateway' already exists"
fi

install_tg_secret() {
    mkdir -p "$ENV_PATH" || return 1
    tee "$ENV_FILE" > /dev/null <<EOF || return 1
BOT_TOKEN="$READ_BOT_TOKEN"
CHAT_ID="$READ_CHAT_ID"
GROUP_ID="$READ_GROUP_ID"
EOF
    chown root:telegram_gateway "$ENV_FILE" || return 1
    chmod 640 "$ENV_FILE" || return 1
}
run_and_check "install secret file with token and ID for Telegram scripts" install_tg_secret


# user settings
# create ssh group for login
SSH_GROUP="ssh-users"
if ! getent group "$SSH_GROUP" &> /dev/null; then
    run_and_check "creating '$SSH_GROUP' group" addgroup "$SSH_GROUP"
else 
    echo "✅ Success: group $SSH_GROUP already exists"
fi

# create group for access config files
XRAY_READ_WRITE_GROUP="xray_read_write_group"
if ! getent group "$XRAY_READ_WRITE_GROUP" &> /dev/null; then
    run_and_check "creating '$XRAY_READ_WRITE_GROUP' group" addgroup "$XRAY_READ_WRITE_GROUP"
else 
    echo "✅ Success: group $XRAY_READ_WRITE_GROUP already exists"
fi

# create user and add in ssh and sudo group
gen_service_user() {
    local prefix="service_user_"
    local len=8
    local suffix user

    while true; do
        suffix="$(tr -dc 'a-z0-9' </dev/urandom | head -c "$len")"
        user="${prefix}${suffix}"
        if ! getent passwd "$user" >/dev/null; then
            printf '%s\n' "$user"
            return 0
        fi
    done
}

SECOND_USER="$(gen_service_user)"
if ! getent shadow "$SECOND_USER" &> /dev/null; then
    run_and_check "creating user and added to $SSH_GROUP and sudo groups" useradd -m -s /bin/bash -G sudo,"$SSH_GROUP" "$SECOND_USER"
else 
    echo "✅ Success: user $SECOND_USER already exists"
    run_and_check "added $SECOND_USER to $SSH_GROUP and sudo groups" usermod -aG sudo,"$SSH_GROUP" "$SECOND_USER"
fi


# sudo without password
ensure_nopasswd_sudo_for_group() {
    local sudoers_file="/etc/sudoers.d/90-${SECOND_USER}-nopasswd"
    local line="${SECOND_USER} ALL=(ALL:ALL) NOPASSWD: ALL"
    local tmp

    tmp="$(mktemp)" || return 1
    printf '%s\n' "$line" >"$tmp" || return 1

    install -m 0440 -o root -g root "$tmp" "$sudoers_file" || return 1
    rm -f "$tmp" || return 1
}
run_and_check "enabled passwordless sudo for user: $SECOND_USER" ensure_nopasswd_sudo_for_group


# changing password for root and user
conf_pswd() {
    printf 'root:%s\n%s:%s\n' "$PASS" "$SECOND_USER" "$PASS" | chpasswd || return 1
}
run_and_check "changing root and $SECOND_USER passwords" conf_pswd


# SSH Configuration
# variables and port generation
SSH_CONF_DEST="/etc/ssh/sshd_config.d/00-custom_security.conf"
SSH_PORT="$(shuf -i "40000-50000" -n 1)"

# deleting previous sshd configuration with high priority
if compgen -G "/etc/ssh/sshd_config.d/*.conf" &> /dev/null; then
    run_and_check "deleting previous sshd configuration files" rm -f /etc/ssh/sshd_config.d/*.conf
else
    echo "✅ Success: previous sshd configurations files not found"
fi

# creating a new sshd configuration
install_sshd() {
    install -m 644 -o root -g root "cfg/ssh.cfg" "$SSH_CONF_DEST" || return 1
    tee /etc/ssh/sshd_config > /dev/null <<'EOF' || return 1
Include /etc/ssh/sshd_config.d/*.conf
EOF
    sed -i "s/{PORT}/$SSH_PORT/g" "$SSH_CONF_DEST" || return 1
    rm -f /etc/ssh/ssh_host_ecdsa_key || return 1
    rm -f /etc/ssh/ssh_host_ecdsa_key.pub || return 1
    rm -f /etc/ssh/ssh_host_rsa_key || return 1
    rm -f /etc/ssh/ssh_host_rsa_key.pub || return 1
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
    mkdir -p "$SSH_DIR" || return 1
    rm -f "$PRIV_KEY_PATH" || return 1
    ssh-keygen -t ed25519 -N "" -f "$PRIV_KEY_PATH" -q || return 1
    PRIV_KEY="$(cat "$PRIV_KEY_PATH")" || return 1
    rm -f "$PRIV_KEY_PATH" || return 1
    chmod 700 "$SSH_DIR" || return 1
    chmod 600 "$PUB_KEY_PATH" || return 1
    chown -R "$SECOND_USER:$USER_GROUP" "$SSH_DIR" || return 1
}
run_and_check "install new sshd keys" install_sshd_key


# reboot SSH
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "restart sshd" systemctl restart ssh.socket


# Disable message of the day
MOTD="/etc/pam.d/sshd"
run_and_check "disable MOTD in PAM setting" sed -ri 's/^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$/# \1/' "$MOTD"


# enable firewall
conf_nftables() {
    install -m 755 -o root -g root "cfg/nftables.conf" "/etc/nftables.conf" || return 1
    sed -i "s/{PORT}/$SSH_PORT/g" "/etc/nftables.conf" || return 1
}
run_and_check "install nftables firewall configuration" conf_nftables
run_and_check "enable nftables firewall" systemctl enable -q --now nftables.service


# Install and setup fail2ban
install_with_retry "install fail2ban package" apt-get install -y fail2ban

conf_f2b() {
    install -m 644 -o root -g root "cfg/jail.local" "/etc/fail2ban/jail.local" || return 1
    sed -i "s/{PORT}/$SSH_PORT/g" "/etc/fail2ban/jail.local" || return 1
    install -m 644 -o root -g root "cfg/ssh_telegram.local" "/etc/fail2ban/action.d/ssh_telegram.local" || return 1
    # enable ip6
    tee /etc/fail2ban/fail2ban.local > /dev/null <<'EOF' || return 1
[Definition]
allowipv6 = auto
EOF
}
run_and_check "install fail2ban configuration" conf_f2b

# Start fail2ban
start_f2b() {
    systemctl enable -q --now fail2ban.service || return 1
    systemctl restart fail2ban.service || return 1
}
run_and_check "enable and start fail2ban service" start_f2b


# make BBR appear in "available" list (if it's a module)
modprobe tcp_bbr &>/dev/null

bbr_on() {
    tee /etc/sysctl.d/99-bbr.conf > /dev/null <<'EOF' || return 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    tee /etc/modules-load.d/bbr.conf > /dev/null <<'EOF' || return 1
tcp_bbr
EOF
    sysctl --system &> /dev/null || return 1
}

# check availability
BBR_AVAILABLE="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
if ! grep -qw bbr <<<"$BBR_AVAILABLE"; then
    echo "📢 Info: BBR not available (net.ipv4.tcp_available_congestion_control = '${BBR_AVAILABLE}')"
else
    run_and_check "enable BBR" bbr_on
fi


# unattended upgrade and reboot script
install_with_retry "install unattended upgrades package" apt-get install -y unattended-upgrades

conf_un_up() {
    tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF' || return 1
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer &> /dev/null || return 1
}
run_and_check "changing unattended upgrades settings" conf_un_up


# nginx+sert install
install_with_retry "install nginx and certbot package" apt-get install -y nginx certbot python3-certbot-nginx 

conf_nginx() {
    # delete default site
    rm -rf /var/www/* || return 1
    rm -rf /etc/nginx/sites-available/* || return 1
    rm -rf /etc/nginx/sites-enabled/* || return 1

    mkdir -p "/var/www/${XRAY_HOSTNAME}/html" || return 1

    # install nginx .conf file
    install -m 644 -o root -g root "cfg/nginx_80.conf" "/etc/nginx/sites-available/${XRAY_HOSTNAME}.conf" || return 1

    # change marker {HOST} to variable value
    sed -i "s/{HOST}/${XRAY_HOSTNAME}/g" "/etc/nginx/sites-available/${XRAY_HOSTNAME}.conf" || return 1

    # turn on site
    ln -s "/etc/nginx/sites-available/${XRAY_HOSTNAME}.conf" /etc/nginx/sites-enabled/ || return 1

    # check .conf and turn on nginx
    nginx -t &> /dev/null || return 1
    systemctl enable -q --now nginx || return 1
    sleep 1
    systemctl restart nginx > /dev/null || return 1
}
run_and_check "configure nginx" conf_nginx

conf_cert() {
    certbot certonly --webroot -w "/var/www/${XRAY_HOSTNAME}/html" -d "${XRAY_HOSTNAME}" --agree-tos -m "$OWNER_EMAIL" --non-interactive > /dev/null || return 1
}
run_and_check "configure sertificates" conf_cert

conf_nginx_sert() {
    # install nginx .conf file
    install -m 644 -o root -g root "cfg/nginx_80_443.conf" "/etc/nginx/sites-available/${XRAY_HOSTNAME}.conf" || return 1

    # change marker {HOST} to variable value
    sed -i "s/{HOST}/${XRAY_HOSTNAME}/g" "/etc/nginx/sites-available/${XRAY_HOSTNAME}.conf" || return 1
    
    # check .conf and restart
    nginx -t &> /dev/null || return 1
    systemctl restart nginx > /dev/null || return 1
}
run_and_check "configure nginx work with sertificates" conf_nginx_sert

# hooks after update sert
conf_hooks() {
    tee /etc/letsencrypt/renewal-hooks/deploy/10-restart-nginx.sh >/dev/null <<'EOF' || return 1
#!/bin/bash
systemctl restart nginx.service
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/10-restart-nginx.sh || return 1

    tee /etc/letsencrypt/renewal-hooks/deploy/20-restart-xray.sh >/dev/null <<'EOF' || return 1
#!/bin/bash
sleep 1
systemctl restart xray.service
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/20-restart-xray.sh || return 1
}
run_and_check "configure hooks for sertificates" conf_hooks


# xray install
# create user for xray
if ! getent shadow xray &> /dev/null; then
    run_and_check "create user for the xray service" useradd -r -M -d /nonexistent -s /usr/sbin/nologin xray
else 
    echo "✅ Success: user 'xray' already exists"
fi

run_and_check "added xray user to '$XRAY_READ_WRITE_GROUP' group" usermod -aG "$XRAY_READ_WRITE_GROUP" "xray"
run_and_check "added telegram_gateway user to '$XRAY_READ_WRITE_GROUP' group" usermod -aG "$XRAY_READ_WRITE_GROUP" "telegram_gateway"

readonly URI_DB="/usr/local/etc/xray/URI_DB"

install_xray_dir() {
    # create log dir, xray group can read, step in, write exist file but not create new and not get upper permission
    # reset log file if exist
    mkdir -p /var/log/xray || return 1
    chmod 750 /var/log/xray || return 1
    chown root:${XRAY_READ_WRITE_GROUP} /var/log/xray || return 1
    echo > /var/log/xray/error.log || return 1
    chmod 660 /var/log/xray/error.log || return 1
    chown root:${XRAY_READ_WRITE_GROUP} /var/log/xray/error.log || return 1
    echo > /var/log/xray/access.log || return 1
    chmod 660 /var/log/xray/access.log || return 1
    chown root:${XRAY_READ_WRITE_GROUP} /var/log/xray/access.log || return 1
    
    # create data dir, xray group and others only can read and step in
    mkdir -p /usr/local/share/xray || return 1
    chmod 755 /usr/local/share/xray || return 1

    # create /etc, $XRAY_READ_WRITE_GROUP can write, read, step in and create new file
    mkdir -p /usr/local/etc/xray || return 1
    chmod 770 /usr/local/etc/xray || return 1
    chown root:${XRAY_READ_WRITE_GROUP} "/usr/local/etc/xray" || return 1

    # create TR_DB file and reset if exist, telegram_gateway can read, write, but not get upper permission to file
    echo > /usr/local/etc/xray/TR_DB_M || return 1
    chmod 660 "/usr/local/etc/xray/TR_DB_M" || return 1
    chown root:telegram_gateway "/usr/local/etc/xray/TR_DB_M" || return 1
    echo > /usr/local/etc/xray/TR_DB_Y || return 1
    chmod 660 "/usr/local/etc/xray/TR_DB_Y" || return 1
    chown root:telegram_gateway "/usr/local/etc/xray/TR_DB_Y" || return 1

    # create URI_DB file and reset if exist, telegram_gateway can read, write, but not get upper permission to file
    echo > "$URI_DB"
    chmod 660 "$URI_DB"
    chown root:telegram_gateway "$URI_DB"
    
    TMP_DIR=$(mktemp -d) || return 1
    readonly TMP_DIR
}
run_and_check "create directory for the xray service" install_xray_dir

# download function
_dl() { curl -fsSL -m 60 "$1" -o "$2"; }

# download with retry
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
            ((attempt++))
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

run_and_check "install xray binary" install -m 755 -o root -g root "$UNPACK_DIR/xray" "/usr/local/bin/xray"
run_and_check "install geoip.dat" install -m 644 -o root -g root "$TMP_DIR/geoip.dat" "/usr/local/share/xray/geoip.dat"
run_and_check "install geosite.dat" install -m 644 -o root -g root "$TMP_DIR/geosite.dat" "/usr/local/share/xray/geosite.dat"

# configure xray service
XRAY_CONFIG_SRC="cfg/config.json"
XRAY_CONFIG_DEST="/usr/local/etc/xray/config.json"

conf_xray() {
    install -m 644 -o root -g root "cfg/xray.service" "/etc/systemd/system/xray.service" || return 1
}
run_and_check "create xray systemd service" conf_xray

# calculate exp and created date
CREATED="$(date +%F)"

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
HAS_INBOUND="$(jq --arg tag "$INBOUND_TAG" '
    any(.inbounds[]?; .tag == $tag and .protocol == "vless")
' "$XRAY_CONFIG_SRC")"

if [[ "$HAS_INBOUND" != "true" ]]; then
    echo "❌ Error: config not have vless-inbound, tag='$INBOUND_TAG', exit"
    exit 1
fi

# uuid generation
UUID="$(xray uuid)"

# configure json 
conf_json_xray() {

    XRAY_PORT="443"

    # key generation
    keys="$(xray x25519)"
    privateKey="$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keys")"

    # shortId generation
    shortId="$(openssl rand -hex 8)"

    # make tmp file
    TMP_XRAY_CONFIG="$(mktemp --suffix=.json)" || return 1
    trap 'rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"' EXIT

    # update json
    jq --arg tag   "$INBOUND_TAG" \
    --arg email "$XRAY_EMAIL" \
    --arg id    "$UUID" \
    --arg dflow "$DEFAULT_FLOW" \
    --arg sni   "$XRAY_HOSTNAME" \
    --arg pk    "$privateKey" \
    --arg sid   "$shortId" '
    # Берём flow из первого клиента нужного inbound по tag (если нет — дефолт)
    ([.inbounds[]? | select(.tag==$tag and .protocol=="vless") | .settings.clients[0].flow?][0] // $dflow) as $flow

    | .inbounds |= map(
        if (.tag==$tag and .protocol=="vless") then

            # 1) Обновляем realitySettings ТОЛЬКО для этого tag (и если это reality)
            (if (.streamSettings.security?=="reality" and (.streamSettings.realitySettings?!=null)) then
            .streamSettings.realitySettings |= (
                .serverNames=[$sni]
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
run_and_check "new xray config checking" xray run -test -config "$TMP_XRAY_CONFIG"
run_and_check "install new xray config" install -m 660 -o root -g "${XRAY_READ_WRITE_GROUP}" "$TMP_XRAY_CONFIG" "$XRAY_CONFIG_DEST"
run_and_check "delete temporary xray files " rm -rf "$TMP_XRAY_CONFIG" "$TMP_DIR"
trap - EXIT

# start xray
run_and_check "reload systemd" systemctl daemon-reload
run_and_check "enable xray service" systemctl enable -q --now xray.service


# start make link, get inbound paremetres
XRAY_PORT="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .port
' "$XRAY_CONFIG_DEST")"

REALITY_SNI="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.serverNames[0] // ""
' "$XRAY_CONFIG_DEST")"

PRIVATE_KEY="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.privateKey // ""
' "$XRAY_CONFIG_DEST")"

SHORT_ID="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .streamSettings.realitySettings.shortIds[0] // ""
' "$XRAY_CONFIG_DEST")"

FLOW="$(jq -r --arg tag "$INBOUND_TAG" '
  .inbounds[] | select(.tag==$tag) | .settings.clients[0].flow // ""
' "$XRAY_CONFIG_DEST")"

# function for checking variables in json config
check_var() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]; then
        echo "❌ Error: $name not found in realitySettings inbound, exit"
        exit 1
    fi
}

# checking empty variable or not
check_var "PORT" "$XRAY_PORT"
check_var "REALITY_SNI" "$REALITY_SNI"
check_var "PRIVATE_KEY" "$PRIVATE_KEY"
check_var "SHORT_ID" "$SHORT_ID"
check_var "FLOW" "$FLOW"

# generate public key from privat key
XRAY_X25519_OUT="$(xray x25519 -i "$PRIVATE_KEY")"

PUBLIC_KEY="$(printf '%s\n' "$XRAY_X25519_OUT" | awk -F': ' '/Password:/ {print $2}')"

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "❌ Error: empty publicKey/password, exit"
  exit 1
fi

# get server ip
IP_4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
IP_6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

# if not get ip set host as hostname
[ -z "$IP_4" ] && { IP_4="$(hostname)"; }

# make uri link
uri_encode() { printf '%s' "$1" | jq -sRr @uri; }

# get link
VLESS_URI_IP4="vless://${UUID}@${IP_4}:${XRAY_PORT}/?encryption=none&flow=$(uri_encode "$FLOW")&\
security=reality&type=tcp&sni=$(uri_encode "$REALITY_SNI")&fp=$(uri_encode "chrome")&pbk=\
$(uri_encode "$PUBLIC_KEY")&sid=$(uri_encode "$SHORT_ID")#$(uri_encode "$XRAY_NAME")-$(uri_encode "$REALITY_SNI")-IP4"

# if not get ip6, skip make vless ip6 link
if [ -n "$IP_6" ]; then
    VLESS_URI_IP6="vless://${UUID}@[${IP_6}]:${XRAY_PORT}/?encryption=none&flow=$(uri_encode "$FLOW")&\
security=reality&type=tcp&sni=$(uri_encode "$REALITY_SNI")&fp=$(uri_encode "chrome")&pbk=\
$(uri_encode "$PUBLIC_KEY")&sid=$(uri_encode "$SHORT_ID")#$(uri_encode "$XRAY_NAME")-$(uri_encode "$REALITY_SNI")-IP6"
fi

# get link for domain
VLESS_URI_DOMAIN="vless://${UUID}@$(uri_encode "$REALITY_SNI"):${XRAY_PORT}/?encryption=none&flow=$(uri_encode "$FLOW")&\
security=reality&type=tcp&sni=$(uri_encode "$REALITY_SNI")&fp=$(uri_encode "chrome")&pbk=\
$(uri_encode "$PUBLIC_KEY")&sid=$(uri_encode "$SHORT_ID")#$(uri_encode "$XRAY_NAME")-$(uri_encode "$REALITY_SNI")"

# print result to URI_DB
if [ -n "$IP_6" ]; then
    tee "$URI_DB" > /dev/null <<EOF
name: $XRAY_NAME, vless ip_4 link: $VLESS_URI_IP4
name: $XRAY_NAME, vless ip_6 link: $VLESS_URI_IP6
name: $XRAY_NAME, vless DOMAIN link: $VLESS_URI_DOMAIN

EOF
else
    tee "$URI_DB" > /dev/null <<EOF
name: $XRAY_NAME, vless ip_4 link: $VLESS_URI_IP4
name: $XRAY_NAME, vless DOMAIN link: $VLESS_URI_DOMAIN

EOF
fi


# maintance script install and add link to home dir service_user_********
# shellcheck disable=SC2329
install_scr_service() {
    mkdir -p /usr/local/bin/telegram || return 1
    mkdir -p /usr/local/bin/service || return 1
    mkdir -p /usr/local/lib/service || return 1
    install -m 644 -o root -g root "script/share/telegram.lib.sh" "/usr/local/lib/service/telegram.lib.sh" || return 1
    install -m 644 -o root -g root "script/share/run_lock.lib.sh" "/usr/local/lib/service/run_lock.lib.sh" || return 1
    install -m 644 -o root -g root "script/share/variables.lib.sh" "/usr/local/lib/service/variables.lib.sh" || return 1
    install -m 755 -o root -g root "script/useradd.sh" "/usr/local/bin/service/useradd.sh" || return 1
    install -m 755 -o root -g root "script/userdel.sh" "/usr/local/bin/service/userdel.sh" || return 1
    install -m 755 -o root -g root "script/usershow.sh" "/usr/local/bin/service/usershow.sh" || return 1
    install -m 755 -o root -g root "script/userinfo.sh" "/usr/local/bin/service/userinfo.sh" || return 1
    install -m 755 -o root -g root "script/system_info.sh" "/usr/local/bin/service/system_info.sh" || return 1
    install -m 755 -o root -g root "script/restore_backup.sh" "/usr/local/bin/service/restore_backup.sh" || return 1
    install -m 755 -o root -g root "script/userblock.sh" "/usr/local/bin/service/userblock.sh" || return 1
    install -m 755 -o root -g root "script/time_unblock.sh" "/usr/local/bin/service/time_unblock.sh" || return 1
    install -m 755 -o root -g root "script/traffic_unblock.sh" "/usr/local/bin/service/traffic_unblock.sh" || return 1
    install -m 755 -o root -g root "script/ssh_f2b_notify.sh" "/usr/local/bin/telegram/ssh_f2b_notify.sh" || return 1

    ln -sfn "/usr/local/bin/service/useradd.sh" "$USER_HOME/user_add" || return 1
    ln -sfn "/usr/local/bin/service/userdel.sh" "$USER_HOME/user_del" || return 1
    ln -sfn "/usr/local/bin/service/time_unblock.sh" "$USER_HOME/time_unblock" || return 1
    ln -sfn "/usr/local/bin/service/userblock.sh" "$USER_HOME/user_block" || return 1
    ln -sfn "/usr/local/bin/service/usershow.sh" "$USER_HOME/user_show" || return 1
    ln -sfn "/usr/local/bin/service/system_info.sh" "$USER_HOME/system_info" || return 1
    ln -sfn "/usr/local/bin/service/restore_backup.sh" "$USER_HOME/restore_backup" || return 1
    ln -sfn "/usr/local/bin/service/userinfo.sh" "$USER_HOME/user_info" || return 1
    ln -sfn "/usr/local/bin/service/traffic_unblock.sh" "$USER_HOME/traffic_unblock" || return 1

    find "$USER_HOME" -type l -exec chown -h "$SECOND_USER":"$SECOND_USER" {} +  || return 1
}
run_and_check "all service script installation and create link in home directory" install_scr_service


# precreate lockfiles script
# shellcheck disable=SC2329
install_scr_precreate_lockfiles() {
    install -m 644 -o root -g root "cfg/precreate_lockfiles.service" "/etc/systemd/system/precreate_lockfiles.service" || return 1
    install -m 755 -o root -g root "script/precreate_lockfiles.sh" "/usr/local/bin/service/precreate_lockfiles.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now precreate_lockfiles.service || return 1
}
run_and_check "precreate lockfiles service installation" install_scr_precreate_lockfiles


# install ssh pam script and enable script in PAM
# shellcheck disable=SC2329
install_scr_ssh_pam() {
    install -m 755 -o root -g root "script/ssh_pam_notify.sh" "/usr/local/bin/telegram/ssh_pam_notify.sh" || return 1
    if ! grep -q "ssh-pam-telegram-notify" "/etc/pam.d/sshd"; then
        tee -a /etc/pam.d/sshd > /dev/null <<EOF || return 1

# ssh-pam-telegram-notify
# Notify for success ssh login and logout via telegram bot
session optional pam_exec.so /usr/local/bin/telegram/ssh_pam_notify.sh
EOF
    fi
}
run_and_check "ssh PAM notification script installation" install_scr_ssh_pam


# user statistics DB collecting
# shellcheck disable=SC2329
install_scr_xray_statistics() {
    install -m 644 -o root -g root "cfg/xray_statistics.timer" "/etc/systemd/system/xray_statistics.timer" || return 1
    install -m 644 -o root -g root "cfg/xray_statistics.service" "/etc/systemd/system/xray_statistics.service" || return 1
    install -m 755 -o root -g root "script/xray_statistics.sh" "/usr/local/bin/service/xray_statistics.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now xray_statistics.timer || return 1
}
run_and_check "xray statistic service installation" install_scr_xray_statistics


# user server traffic + remaining days - Telegram bot notify
# shellcheck disable=SC2329
install_scr_user_notify() {
    install -m 644 -o root -g root "cfg/user_notify.timer" "/etc/systemd/system/user_notify.timer" || return 1
    install -m 644 -o root -g root "cfg/user_notify.service" "/etc/systemd/system/user_notify.service" || return 1
    install -m 755 -o root -g root "script/user_notify.sh" "/usr/local/bin/telegram/user_notify.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now user_notify.timer || return 1
}
run_and_check "user daily report service installation" install_scr_user_notify


# time block expired users + Telegram bot notify
# shellcheck disable=SC2329
install_scr_time_block() {
    install -m 644 -o root -g root "cfg/time_block.timer" "/etc/systemd/system/time_block.timer" || return 1
    install -m 644 -o root -g root "cfg/time_block.service" "/etc/systemd/system/time_block.service" || return 1
    install -m 755 -o root -g root "script/time_block.sh" "/usr/local/bin/service/time_block.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now time_block.timer || return 1
}
run_and_check "time block expired user service installation" install_scr_time_block


# user traffic block + Telegram bot notify
# shellcheck disable=SC2329
install_scr_traffic_block() {
    install -m 644 -o root -g root "cfg/traffic_block.timer" "/etc/systemd/system/traffic_block.timer" || return 1
    install -m 644 -o root -g root "cfg/traffic_block.service" "/etc/systemd/system/traffic_block.service" || return 1
    install -m 755 -o root -g root "script/traffic_block.sh" "/usr/local/bin/service/traffic_block.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now traffic_block.timer || return 1
}
run_and_check "traffic block service installation" install_scr_traffic_block


# xray backup Telegram bot notify
# shellcheck disable=SC2329
install_scr_xray_backup() {
    install -m 644 -o root -g root "cfg/xray_backup.timer" "/etc/systemd/system/xray_backup.timer" || return 1
    install -m 644 -o root -g root "cfg/xray_backup.service" "/etc/systemd/system/xray_backup.service" || return 1
    install -m 755 -o root -g root "script/xray_backup.sh" "/usr/local/bin/service/xray_backup.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now xray_backup.timer || return 1
}
run_and_check "xray backup service installation" install_scr_xray_backup


# auto update xray and geo*.dat + notify via Telegram
# shellcheck disable=SC2329
install_scr_xray_update() {
    install -m 644 -o root -g root "cfg/xray_update.timer" "/etc/systemd/system/xray_update.timer" || return 1
    install -m 644 -o root -g root "cfg/xray_update.service" "/etc/systemd/system/xray_update.service" || return 1
    install -m 755 -o root -g root "script/xray_update.sh" "/usr/local/bin/service/xray_update.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now xray_update.timer || return 1
}
run_and_check "xray and geo*.dat update service installation" install_scr_xray_update


# unattended upgrade + notify via Telegram
# shellcheck disable=SC2329
install_scr_un_up() {
    install -m 644 -o root -g root "cfg/unattended_upgrade.timer" "/etc/systemd/system/unattended_upgrade.timer" || return 1
    install -m 644 -o root -g root "cfg/unattended_upgrade.service" "/etc/systemd/system/unattended_upgrade.service" || return 1
    install -m 755 -o root -g root "script/unattended_upgrade.sh" "/usr/local/bin/service/unattended_upgrade.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now unattended_upgrade.timer || return 1
}
run_and_check "unattended update service installation" install_scr_un_up


# boot notify script via Telegram
# shellcheck disable=SC2329
install_scr_boot() {
    install -m 644 -o root -g root "cfg/boot_notify.service" "/etc/systemd/system/boot_notify.service" || return 1
    install -m 755 -o root -g root "script/boot_notify.sh" "/usr/local/bin/telegram/boot_notify.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q boot_notify.service || return 1
}
run_and_check "server boot notification service installation" install_scr_boot


# journald alert script via Telegram
# shellcheck disable=SC2329
install_scr_journald_alert() {
    install -m 644 -o root -g root "cfg/journald_alert.service" "/etc/systemd/system/journald_alert.service" || return 1
    install -m 755 -o root -g root "script/journald_alert.sh" "/usr/local/bin/telegram/journald_alert.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now journald_alert.service || return 1
}
run_and_check "journald error alert service installation" install_scr_journald_alert


# cpu alert script via Telegram
# shellcheck disable=SC2329
install_scr_cpu_alert() {
    install -m 644 -o root -g root "cfg/cpu_alert.service" "/etc/systemd/system/cpu_alert.service" || return 1
    install -m 755 -o root -g root "script/cpu_alert.sh" "/usr/local/bin/telegram/cpu_alert.sh" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now cpu_alert.service || return 1
}
run_and_check "cpu high usage alert service installation" install_scr_cpu_alert


# Telegram gateway script install and start
# shellcheck disable=SC2329
conf_tg_gateway() {
    install -m 755 -o root -g root "script/telegram_gateway.sh" "/usr/local/bin/service/telegram_gateway.sh" || return 1
    install -m 644 -o root -g root "cfg/telegram_gateway.service" "/etc/systemd/system/telegram_gateway.service" || return 1
    install -m 644 -o root -g root "cfg/50-telegram_gateway.rules" "/etc/polkit-1/rules.d/50-telegram_gateway.rules" || return 1
    systemctl daemon-reload || return 1
    systemctl enable -q --now telegram_gateway.service || return 1
}
run_and_check " Telegram gateway service installation" conf_tg_gateway


# final output
echo "#################[ SSH USERNAME - PORT ]#################"
echo ""
echo "$SECOND_USER - $SSH_PORT"
echo ""
echo "#####################[ PRIVATE KEY ]#####################"
echo ""
echo "$PRIV_KEY"
echo ""
echo "#############[ PUBLIC KEY - $PUB_KEY_PATH ]##############"
echo ""
cat "$PUB_KEY_PATH"
echo ""
echo "#####################[ VLESS LINK ]######################"
echo ""
cat "$URI_DB"
echo "#########################################################"
