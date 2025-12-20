#!/bin/bash

вывести все директории куда то в справку
для скриптов телеги
/usr/local/bin/telegram
var/log/telegram
для автообновления и добавления юзеров 
/usr/local/bin/maintance
/var/log/

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
    shift 1
    local attempt=1

    while true; do
        echo "📢 Info: ${action}, attempt $attempt, please wait"
        # $@ passes all remaining arguments (after the first one)
        if "$@"; then
            echo "✅ Success: $action"
            return 0
            
        fi
        if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
            sleep 60
            echo "⚠️  Non-critical error: $action failed, trying again"
            ((attempt++))
            continue
        else
            echo "❌ Error: $action, attempts ended, exit"
            exit 1
        fi
    done
}

run_and_check() {
    action="$1"
    shift 1
    if $@; then
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

# |----------------------------------|
# | Pre install system configuration |
# |----------------------------------|

# Write token and id in secrets file
ENV_PATH="/usr/local/etc/telegram/"
ENV_FILE="/usr/local/etc/telegram/secrets.env"
if ! mkdir -p $ENV_PATH; then
    echo "❌ Failed to create directory $ENV_PATH"
fi
cat > "$ENV_FILE" <<EOF
BOT_TOKEN="$READ_BOT_TOKEN"
CHAT_ID="$READ_CHAT_ID"
EOF
chmod 600 "$ENV_FILE"

echo "✅ Token and Chat id writed in secret file"

# Настройка sshd группы
SSH_GROUP="ssh-users"
if ! getent group "$SSH_GROUP" >/dev/null 2>&1; then
    if addgroup "$SSH_GROUP" >/dev/null 2>&1; then
        echo "✅ Group $SSH_GROUP has been successfully added"
    else
        echo "❌ Ошибка: не удалось создать группу $SSH_GROUP"
    exit 1
    fi
else 
    echo "✅ Group $SSH_GROUP already exists"
fi

# Создание пользователя и добавление его в sshd группу
if useradd -m -s /bin/bash -G sudo,"$SSH_GROUP" "$SECOND_USER"; then
echo "✅ User has been created and added to $SSH_GROUP and sudo groups"
else
echo "❌ Error: user not created"
exit 1
fi

# Смена пароля root и нового пользователя
if printf 'root:%s\n%s:%s\n' "$PASS" "$SECOND_USER" "$PASS" | chpasswd; then
echo "✅ Root and $SECOND_USER passwords have been changed successfully"
else
echo "❌ Error: root and $SECOND_USER passwords not changed"
fi






# |-------------------|
# | SSH Configuration |
# |-------------------|

# Variables
SSH_CONF_SOURCE="/cfg/ssh.cfg"
SSH_CONF_DEST="/etc/ssh/sshd_config.d/99-custom_security.conf"
LOW="40000"
HIGH="50000"

# Port generation [40000,50000]
PORT="$(shuf -i "${LOW}-${HIGH}" -n 1)"

# Очистка файлов конфигураций с высоким приоритетом во избежание конфликтов
if compgen -G "/etc/ssh/sshd_config.d/99*.conf" > /dev/null; then
    rm -f /etc/ssh/sshd_config.d/99*.conf
    echo "✅ Deletion of previous conflicting sshd configuration files completed"
else
    echo "✅ No conflicting sshd configurations files found"
fi

# меняем порт в конфиге
sed -i "s/{PORT}/$PORT/g" "$SSH_CONF_DEST"
# Создаём файл конфигурации
if install -m 644 -o root -g root "$SSH_CONF_SOURCE" "$SSH_CONF_DEST"; then
    echo "✅ Creating a new sshd configuration completed"
else
    echo "❌ Error: sshd configuration not installed"
    exit 1
fi

# Delete disabled key
if rm /etc/ssh/ssh_host_ecdsa_key && \
rm /etc/ssh/ssh_host_ecdsa_key.pub && \
rm /etc/ssh/ssh_host_rsa_key && \
rm /etc/ssh/ssh_host_rsa_key.pub
then
    sleep 1
    echo "✅ Old host keys have been removed"
else
    sleep 1
    echo "❌ Error: old keys are not deleted"
    exit 1
fi

# Находим домашний каталог пользователя
USER_HOME="$(getent passwd "$SECOND_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
KEY_NAME="authorized_keys"
PRIV_KEY_PATH="${SSH_DIR}/${KEY_NAME}"
PUB_KEY_PATH="${PRIV_KEY_PATH}.pub"

# Создаём .ssh folder
if ! mkdir "$SSH_DIR"; then
    echo "❌ Error: unable to create folder for ssh keys"
    exit 1
fi

# Key generation for ssh
if ssh-keygen -t ed25519 -N "" -f "$PRIV_KEY_PATH" -q; then
    echo "✅ The ssh key was successfully generated"
else
    echo "❌ Error: the ssh key cannot be generated"
    exit 1
fi

# Права и владелец
chmod 700 "$SSH_DIR"
chmod 600 "$PRIV_KEY_PATH" "$PUB_KEY_PATH"
USER_GROUP="$(id -gn "$SECOND_USER")"
chown -R "$SECOND_USER:$USER_GROUP" "$SSH_DIR"

# Reboot SSH
systemctl daemon-reload
systemctl restart ssh.socket
systemctl restart ssh.service


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
run_and_check "fail2ban telegram action installation" install -m 644 "$TG_LOCAL_SOURCE" "$TG_LOCAL_DEST"
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
UNATTENDED_UPGRADE_SCRIPT_DEST="/usr/local/bin/telegram/unattended_upgrade.sh"
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

#
# xray install

run_and_check "create user for the xray service" useradd -r -M -d /nonexistent -s /usr/sbin/nologin xray

run_and_check "create directory for the xray service" mkdir -p /usr/local/share/xray && mkdir -p /usr/local/etc/xray \
    && mkdir -p /var/log/xray && chown xray:xray /var/log/xray



отсюда делать

dl_with_retry https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip Xray-linux-64.zip

unzip Xray-linux-64.zip

install -m 755 xray /usr/local/bin/xray

install -m 644 geosite.dat /usr/local/share/xray/geosite.dat
install -m 644 geoip.dat /usr/local/share/xray/geoip.dat


tee /etc/systemd/system/xray.service > /dev/null <<'EOF'
[Unit]
Description=Xray-core VLESS server
After=network-online.target

[Service]
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
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

# зделать права 600 и пользователя и группу храй
# Закидываем конфиг
install -m 644 cfg/config.json "/usr/local/etc/xray/config.json"

# тут надо в конфиг добавить пароли


# Запускаем сервер
systemctl daemon-reload
systemctl enable --now xray.service






# Auto update xray and geobase
GEODAT_SCRIPT_SOURCE="module/geodat_update.sh"
GEODAT_SCRIPT_DEST="/usr/local/bin/geodat_update.sh"
install -m 700 "$GEODAT_SCRIPT_SOURCE" "$GEODAT_SCRIPT_DEST"
# Turn on script in cron
cat > "/etc/cron.d/geodat_update" <<EOF
SHELL=/bin/bash
0 2 1 * * root "$GEODAT_SCRIPT_DEST" >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/geodat_update"
echo "✅ Xray and geo*.dat update script installed successful"











# Выводим оба ключа для копирования
echo
echo "=== PRIVATE KEY ($PRIV_KEY_PATH) ==="
cat "$PRIV_KEY_PATH"
echo
echo "=== PUBLIC KEY ($PUB_KEY_PATH) ==="
cat "$PUB_KEY_PATH"

# --- Показать пароль для копирования (НЕБЕЗОПАСНО) ---
echo
echo "======================================================================"
echo "Ssh port: ${PORT}"
echo "======================================================================"
echo "Подсказка: после копирования очистите историю/скролл терминала (напр., 'clear')."
echo