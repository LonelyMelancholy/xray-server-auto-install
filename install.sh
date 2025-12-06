#!/bin/bash

# |---------------|
# | Root checking |
# |---------------|
if [[ $EUID -ne 0 ]]; then
  echo "❌ You not root user, exit"
  exit 1
else
  echo "✅ You root user, continued"
fi
# |----------------|
# | Utilites check |
# |----------------|
shuf, Зделать проверку утилит для работы нужны которые

# |-------------------|
# | Helping functions |
# |-------------------|
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# |--------------------------|
# | Check configuration file |
# |--------------------------|
CFG_CHECK="module/conf_check.sh"
if [ ! -r "$CFG_CHECK" ]; then
    echo "❌ Error: check $CFG_CHECK it's missing or you not have right to read"
    exit 1
fi
source module/conf_check.sh

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
if install -m 644 "$SSH_CONF_SOURCE" "$SSH_CONF_DEST"; then
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
    echo "✅ Old keys have been removed"
else
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


# |--------------------------------------------------|
# | Install ssh login/logout notify and disable MOTD |
# |--------------------------------------------------|

# Install script notify login 
SSH_ENTER_NOTIFY_SCRIPT="/usr/local/bin/ssh_enter_notify.sh"
install -m 700 module/ssh_enter_notify.sh "$SSH_ENTER_NOTIFY_SCRIPT"
echo -e "\n# Notify for success ssh login and logout via telegram bot" >> /etc/pam.d/sshd
echo "session optional pam_exec.so seteuid /usr/local/bin/ssh_enter_notify.sh" >> /etc/pam.d/sshd
# Disable message of the day, backup and commented 2 lines
MOTD="/etc/pam.d/sshd"
sed -i.bak \
  -e '/^[[:space:]]*session[[:space:]]\{1,\}optional[[:space:]]\{1,\}pam_motd\.so[[:space:]]\{1,\}motd=\/run\/motd\.dynamic[[:space:]]*$/{
        /^[[:space:]]*#/! s/^[[:space:]]*/&# /
      }' \
  -e '/^[[:space:]]*session[[:space:]]\{1,\}optional[[:space:]]\{1,\}pam_motd\.so[[:space:]]\{1,\}noupdate[[:space:]]*$/{
        /^[[:space:]]*#/! s/^[[:space:]]*/&# /
      }' \
  "$MOTD"
echo "✅ Script ssh login/logout notify installed and MOTD disabled"

sudo sed -ri 's/^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$/#\1/' "$FILE"


# |---------------------------|
# |Install and setup fail2ban |
# |---------------------------|

# Install (tryig 3 times)
i=1
while [ "$i" -lt 4 ]; do
    echo "⚠️ Install fail2ban, attempt $i, please wait"
    if apt-get install fail2ban -y >/dev/null 2>&1; then
        echo "✅ Install fail2ban completed"
        break
    else
        echo "❌ Install fail2ban failed, try again"
        i=$((i+1))
        sleep 10
    fi
done

# Check installation and choice between setup or skip
if has_cmd fail2ban-client; then
    # Install ssh jail
    F2B_CONF_SOURCE="cfg/jail.local"
    F2B_CONF_DEST="/etc/fail2ban/jail.local"
    install -m 644 "$F2B_CONF_SOURCE" "$F2B_CONF_DEST"
    sed -i "s/{PORT}/$PORT/g" "$F2B_CONF_DEST"
    # Install ssh action
    TG_LOCAL_SOURCE="cfg/ssh_telegram.local"
    TG_LOCAL_DEST="/etc/fail2ban/action.d/ssh_telegram.local"
    install -m 644 "$TG_LOCAL_SOURCE" "$TG_LOCAL_DEST"
    # Install ssh ban notify script
    SSH_BAN_NOTIFY_SCRIPT_SOURCE="module/ssh_ban_notify.sh"
    SSH_BAN_NOTIFY_SCRIPT_DEST="/usr/local/bin/ssh_ban_notify.sh"
    install -m 755 "$SSH_BAN_NOTIFY_SCRIPT_SOURCE" "$SSH_BAN_NOTIFY_SCRIPT_DEST"
    echo "✅ Setup fail2ban completed"
    # Start fail2ban
    if systemctl enable --now fail2ban; then
        echo "✅ Fail2ban start successful"
    else
        echo "❌ Startup error, check logs"
    fi
else
    echo "❌ Warning! Skipping fail2ban setup!"
fi

# |------------------------------------------|
# |Server + User traffic telegram bot notify |
# |------------------------------------------|

# Install script
TRAFFIC_NOTIFY_SCRIPT_SOURCE="module/traffic_notify.sh"
TRAFFIC_NOTIFY_SCRIPT_DEST="/usr/local/bin/traffic_notify.sh"
install -m 755 "$TRAFFIC_NOTIFY_SCRIPT_SOURCE" "$TRAFFIC_NOTIFY_SCRIPT_DEST"
# Turn on script in cron
cat > "/etc/cron.d/traffic_notify" <<EOF
0 1 * * * root "$TRAFFIC_NOTIFY_SCRIPT_DEST" >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/traffic_notify"
echo "✅ Traffic notify script installed successful"




# Включаем security обновления и перезагрузку по необходимости
apt-get install unattended-upgrades -y
# так и не доделал



# Установка Xray

useradd -r -s /usr/sbin/nologin xray

mkdir -p /usr/local/share/xray
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray
chown xray:xray /var/log/xray

wget https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip Xray-linux-64.zip

mv xray /usr/local/bin/xray
chmod 755 /usr/local/bin/xray

mv geosite.dat geoip.dat /usr/local/share/xray
chmod 644 /usr/local/share/xray/*

cat > "/etc/systemd/system/xray.service" <<'EOF'
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

# Закидываем конфиг
install -m 644 cfg/config.json "/usr/local/etc/xray/config.json"

# тут надо в конфиг добавить пароли


# Запускаем сервер
sudo systemctl daemon-reload
sudo systemctl enable --now xray.service





автообновления геолистов

  local download_link_geoip="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  local download_link_geosite="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
  local file_ip='geoip.dat'
  local file_dlc='geosite.dat'
  local file_site='geosite.dat'












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



# Очистка переменной и завершение
unset -v PASS
trap - EXIT
