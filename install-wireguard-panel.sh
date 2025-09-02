#!/bin/bash
set -e

echo "==============================="
echo " 🚀 WireGuard + WG-Easy (+ NPM) Installer"
echo "==============================="

# --- Menu lựa chọn ---
echo "Chọn chế độ cài đặt:"
echo "  1) Chỉ WG-Easy"
echo "  2) WG-Easy + Nginx Proxy Manager (mặc định)"
read -p "Nhập lựa chọn [1-2] (Enter = 2): " MODE_INPUT
if [[ "$MODE_INPUT" == "1" ]]; then
  MODE=1
else
  MODE=2
fi

# --- Nhập config chung ---
read -p "Nhập domain cho VPN (vd: vpn.example.com): " WG_HOST

# WG-Easy password
read -sp "Nhập mật khẩu cho WG-Easy (Enter để random): " WG_PASSWORD
echo ""
if [ -z "$WG_PASSWORD" ]; then
  WG_PASSWORD=$(openssl rand -base64 12)
  AUTO_WG_PASS=true
fi

# Nếu có NPM thì cần email + password
if [[ "$MODE" == "2" ]]; then
  read -p "Nhập email admin cho NPM (Let's Encrypt + login): " ADMIN_EMAIL
  if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${WG_HOST}"
  fi

  read -sp "Nhập mật khẩu cho NPM Admin (Enter để random): " ADMIN_PASS
  echo ""
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -base64 12)
    AUTO_NPM_PASS=true
  fi
fi

# --- Update system ---
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl jq software-properties-common

# --- Enable IPv4/IPv6 forwarding ---
cat <<EOF >/etc/sysctl.d/99-wireguard.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system

# --- Install Docker ---
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io

systemctl enable docker
systemctl start docker

# --- Install Docker Compose ---
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# --- Create stack ---
mkdir -p ~/vpn-stack
cd ~/vpn-stack

cat > docker-compose.yml <<EOF
version: "3.8"

services:
  wg-easy:
    image: weejewel/wg-easy
    container_name: wg-easy
    environment:
      - WG_HOST=${WG_HOST}
      - PASSWORD=${WG_PASSWORD}
      - WG_DEFAULT_ADDRESS=10.8.0.x,fd42:42:42::x
      - WG_DEFAULT_DNS=1.1.1.1,2606:4700:4700::1111
    volumes:
      - ./wg-config:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    restart: unless-stopped
EOF

# Nếu chọn cài cả NPM
if [[ "$MODE" == "2" ]]; then
cat >> docker-compose.yml <<EOF

  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "127.0.0.1:81:81"
      - "443:443"
    volumes:
      - ./npm-data:/data
      - ./npm-letsencrypt:/etc/letsencrypt
EOF
fi

cat >> docker-compose.yml <<EOF

networks:
  default:
    driver: bridge
EOF
