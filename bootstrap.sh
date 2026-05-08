#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

if [[ ! -f /etc/os-release ]] || ! grep -q "Ubuntu" /etc/os-release; then
    echo "Script is for Ubuntu only!" >&2
    exit 1
fi

. /etc/os-release
if [[ "$VERSION_ID" != "24.04" ]]; then
    echo "Warning: Script tested on Ubuntu 24.04, you have $VERSION_ID"
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root or via sudo" >&2
    exit 1
fi

read -p "Enter username: " USERNAME
USERNAME=$(echo "$USERNAME" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

while true; do
    read -p "Enter port number for SSH [22]: " SSH_PORT
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
        break
    fi
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        echo "Invalid port: $SSH_PORT"
        echo "Try again..."
        continue
    fi
    if (( $SSH_PORT < 1024 )) && (( $SSH_PORT != 22 )); then
        echo "Warning: port $SSH_PORT is privileged"
    fi
    if ss -tln | grep ":$SSH_PORT"; then
        echo "Warning: port $SSH_PORT seems to be in use"
        read -p "Continue anyway? [y/N]:" PORT_ANSWER
        [[ "$PORT_ANSWER" =~ ^[Yy]$ ]] && break
    else
        break
    fi
done

while true; do
    read -p "Enter public SSH key or github/user.keys (or just user.keys): " SSH_KEY

    # Get key and check if using github.com/user.keys
    if echo "$SSH_KEY" | grep -q ".keys"; then
        if echo "$SSH_KEY" | grep -q "github.com"; then
            if ! echo "$SSH_KEY" | grep -q "https://"; then
                SSH_KEY="https://$SSH_KEY"
            fi
        else
            SSH_KEY="https://github.com/$SSH_KEY"
        fi
        SSH_KEY="$(curl -fsSL "$SSH_KEY")"
        echo " "
        echo "$SSH_KEY"
        echo " "
        read -p "Key is correct? [Y/n]: " KEY_ANSWER
        if [[ "$KEY_ANSWER" =~ ^[Yy]$ ]] || [[ -z "$KEY_ANSWER" ]]; then
            break
        fi

    fi
done

echo "[1/5] Updating system"
apt-get update -y
apt-get upgrade -y

echo "[2/5] Installing packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
ufw unattended-upgrades fail2ban nano \
btop tmux ncdu tree tldr wget \
git ca-certificates

echo "[3/5] Creating new user or configuring existing..."

if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$USERNAME"
    GENERATED_PASSWORD="$(openssl rand -base64 12)"
    echo "$USERNAME:$GENERATED_PASSWORD" | chpasswd
else
    GENERATED_PASSWORD=""
fi

mkdir -p "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"

# Настройка SSH
echo "[4/5] Configuring SSH for $USERNAME..."


echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port $SSH_PORT
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
AllowUsers $USERNAME
EOF

if ! sshd -t; then
    echo "ERROR: sshd config invalid, see above" >&2
    exit 1
fi

echo "[5/5] Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment "SSH"
ufw --force enable

systemctl restart ssh

systemctl enable --now fail2ban

systemctl enable --now unattended-upgrades

echo "============================================="
echo "| Bootstrap completed."
echo "| User: $USERNAME"
echo "| Password: $GENERATED_PASSWORD"
echo "| SSH: $(systemctl is-active ssh), hardened, key-only, port $SSH_PORT"
echo "| UFW: $(systemctl is-active ufw)"
echo "| Fail2ban: $(systemctl is-active fail2ban)"
echo "============================================="
echo "Test new SSH session BEFORE closing this one!"
echo "Command for connectnig: ssh -p $SSH_PORT $USERNAME@<server_IP>"
