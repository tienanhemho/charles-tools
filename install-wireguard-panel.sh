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
printf "Nhập domain cho VPN (vd: vpn.example.com): "
read WG_HOST

# WG-Easy password
printf "Nhập mật khẩu cho WG-Easy (Enter để random): "
stty -echo; read WG_PASSWORD; stty echo; echo ""
if [ -z "$WG_PASSWORD" ]; then
  WG_PASSWORD=$(openssl rand -base64 12)
  AUTO_WG_PASS=true
fi

# Nếu có NPM thì cần email + password
if [ "$MODE" -eq 2 ]; then
  printf "Nhập email admin cho NPM (Let's Encrypt + login): "
  read ADMIN_EMAIL
  if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${WG_HOST}"
  fi

  printf "Nhập mật khẩu cho NPM Admin (Enter để random): "
  stty -echo; read ADMIN_PASS; stty echo; echo ""
  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -base64 12)
    AUTO_NPM_PASS=true
  fi
fi

# --- Update system ---
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl jq software-properties-common

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
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
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
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

# Nếu chọn cài cả NPM
if [ "$MODE" -eq 2 ]; then
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

# --- Start stack ---
docker-compose up -d

# --- Nếu có NPM thì cấu hình tự động ---
if [ "$MODE" -eq 2 ]; then
  echo "⏳ Đợi NPM khởi động..."
  sleep 40

  TOKEN=$(curl -s -X POST http://127.0.0.1:81/api/tokens \
    -H 'Content-Type: application/json' \
    -d '{"identity":"admin@example.com","secret":"changeme"}' \
    | jq -r .token)

  if [ "$TOKEN" != "null" ]; then
    # Update admin user
    curl -s -X PUT http://127.0.0.1:81/api/users/1 \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"email":"'"$ADMIN_EMAIL"'","name":"Administrator","nickname":"Admin","roles":["admin"],"is_disabled":false,"auth":[{"type":"password","secret":"'"$ADMIN_PASS"'"}]}'

    # Login với pass mới
    TOKEN=$(curl -s -X POST http://127.0.0.1:81/api/tokens \
      -H 'Content-Type: application/json' \
      -d '{"identity":"'"$ADMIN_EMAIL"'","secret":"'"$ADMIN_PASS"'"}' \
      | jq -r .token)

    # Tạo proxy host cho WG-Easy
    curl -s -X POST http://127.0.0.1:81/api/nginx/proxy-hosts \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{
        "domain_names":["'"$WG_HOST"'"],
        "forward_scheme":"http",
        "forward_host":"wg-easy",
        "forward_port":51821,
        "access_list_id":0,
        "certificate_id":0,
        "ssl_forced":true,
        "caching_enabled":false,
        "block_exploits":true,
        "http2_support":true,
        "hsts_enabled":false,
        "hsts_subdomains":false,
        "meta": {
          "letsencrypt_email":"'"$ADMIN_EMAIL"'",
          "letsencrypt_agree":true
        }
      }'
  else
    echo "⚠️ Không thể login vào NPM API bằng tài khoản mặc định."
  fi
fi

# --- Summary ---
echo "========================================"
echo "🎉 Cài đặt hoàn tất!"
echo "WG-Easy panel: https://${WG_HOST}"
echo "VPN UDP port: 51820"
if [ "$AUTO_WG_PASS" = true ]; then
  echo "WG-Easy Password (auto): $WG_PASSWORD"
else
  echo "WG-Easy Password (bạn nhập)"
fi
if [ "$MODE" -eq 2 ]; then
  echo "NPM Admin: $ADMIN_EMAIL"
  if [ "$AUTO_NPM_PASS" = true ]; then
    echo "NPM Password (auto): $ADMIN_PASS"
  else
    echo "NPM Password (bạn nhập)"
  fi
fi
echo "========================================"
