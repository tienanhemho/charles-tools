#!/bin/bash
set -e

echo "==============================="
echo " 🚀 WireGuard + WG-Easy (+ NPM) Installer"
echo "==============================="
echo ""
echo "💡 Script này có thể chạy lại an toàn:"
echo "   • Tự động bypass Docker nếu đã cài"
echo "   • Backup cấu hình cũ trước khi tạo mới"
echo "   • Dừng containers cũ trước khi khởi động"
echo ""

# --- Menu lựa chọn ---
echo "Chọn chế độ cài đặt:"
echo "  1) Chỉ WG-Easy"
echo "  2) WG-Easy + Nginx Proxy Manager (mặc định)"
read -p "Nhập lựa chọn [1-2] (Enter = 2): " MODE_INPUT
if [ "$MODE_INPUT" == "1" ]; then
  MODE=1
else
  MODE=2
fi

# --- Nhập config chung ---
read -p "Nhập domain cho VPN (vd: vpn.example.com): " WG_HOST

# --- Kiểm tra domain trỏ về IP VPS ---
SERVER_IP=$(curl -s https://api.ipify.org)
while true; do
  DOMAIN_IP=$(getent ahosts "$WG_HOST" | awk '/STREAM/ {print $1; exit}')
  if [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
    echo "✅ Domain $WG_HOST đã trỏ về đúng IP VPS: $SERVER_IP"
    break
  else
    echo "⚠️ Domain $WG_HOST hiện đang trỏ về $DOMAIN_IP (không khớp IP VPS $SERVER_IP)"
    echo "👉 Hãy cập nhật DNS record cho $WG_HOST → $SERVER_IP rồi nhấn Enter để kiểm tra lại."
    read
  fi
done

# WG-Easy password
read -sp "Nhập mật khẩu cho WG-Easy (Enter để random): " WG_PASSWORD
echo ""
if [ -z "$WG_PASSWORD" ]; then
  WG_PASSWORD=$(openssl rand -base64 12)
  AUTO_WG_PASS=true
fi

# Nếu có NPM thì cần email + password
if [ "$MODE" == "2" ]; then
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
if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
  echo "✅ Docker đã được cài đặt: $(docker --version)"
  
  # Kiểm tra Docker đang chạy
  if ! systemctl is-active --quiet docker; then
    echo "🔄 Khởi động Docker service..."
    systemctl enable docker
    systemctl start docker
  else
    echo "✅ Docker service đang chạy"
  fi
else
  echo "📦 Cài đặt Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io

  systemctl enable docker
  systemctl start docker
  echo "✅ Docker đã được cài đặt thành công"
fi

# --- Install Docker Compose ---
if command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then
  echo "✅ Docker Compose đã được cài đặt: $(docker-compose --version)"
else
  echo "📦 Cài đặt Docker Compose..."
  curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  echo "✅ Docker Compose đã được cài đặt thành công"
fi

# --- Create stack ---
if [ -d ~/vpn-stack ]; then
  echo "⚠️ Thư mục ~/vpn-stack đã tồn tại. Backup cấu hình cũ..."
  mv ~/vpn-stack ~/vpn-stack.backup.$(date +%Y%m%d-%H%M%S)
fi

mkdir -p ~/vpn-stack
cd ~/vpn-stack

cat > docker-compose.yml <<EOF
volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      - INIT_ENABLED=true
      - INIT_HOST=${WG_HOST}      # domain hoặc IP public
      - INIT_USERNAME=admin          # tên user web UI
      - INIT_PASSWORD=${WG_PASSWORD}         # mật khẩu web UI
      - INIT_PORT=51820          # port UDP WireGuard
      #- WG_DEFAULT_ADDRESS=10.8.0.x,fd42:42:42::x
      - INIT_DNS=1.1.1.1,2606:4700:4700::1111
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "51820:51820/udp"            # VPN UDP port
      # KHÔNG expose port 51821 trực tiếp ra ngoài, để NPM reverse proxy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
EOF

# Nếu chọn cài cả NPM, thêm vào phần services
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
    networks:
      - wg
EOF
fi

# Cuối cùng mới thêm phần networks
cat >> docker-compose.yml <<EOF

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF

# --- Start stack ---
echo "🚀 Khởi động stack..."

# Kiểm tra xem có containers đang chạy không
if docker ps -q --filter "name=wg-easy" | grep -q . || docker ps -q --filter "name=npm" | grep -q .; then
  echo "⚠️ Phát hiện containers đang chạy. Đang dừng và xóa..."
  docker-compose down -v 2>/dev/null || true
  
  # Xóa containers cũ nếu còn sót lại
  docker rm -f wg-easy npm 2>/dev/null || true
fi

docker-compose up -d
echo "✅ Stack đã được khởi động"

# --- Firewall config (UFW) ---
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS=$(ufw status | head -n1 | awk '{print $2}')
  if [ "$UFW_STATUS" = "inactive" ]; then
    echo "⚠️  UFW đang inactive (tất cả port đều mở). Bỏ qua bước mở firewall."
  else
    echo "🔒 Đang kiểm tra UFW firewall..."

    # Mở port 51820/udp cho WireGuard
    if ! ufw status | grep -q "51820/udp"; then
      echo "⚡ Mở port 51820/udp cho WireGuard"
      ufw allow 51820/udp
    else
      echo "✅ Port 51820/udp đã mở"
    fi

    # Mở port 80/tcp cho HTTP (Let's Encrypt)
    if ! ufw status | grep -q "80/tcp"; then
      echo "⚡ Mở port 80/tcp (HTTP)"
      ufw allow 80/tcp
    else
      echo "✅ Port 80/tcp đã mở"
    fi

    # Mở port 443/tcp cho HTTPS
    if ! ufw status | grep -q "443/tcp"; then
      echo "⚡ Mở port 443/tcp (HTTPS)"
      ufw allow 443/tcp
    else
      echo "✅ Port 443/tcp đã mở"
    fi
  fi
else
  echo "⚠️  UFW chưa được cài. Bỏ qua bước mở firewall."
fi


# --- Nếu có NPM thì cấu hình tự động ---
if [ "$MODE" -eq 2 ]; then
  echo "⏳ Đợi NPM khởi động và sẵn sàng..."
  
  # Wait for NPM to be fully ready with retry mechanism
  MAX_ATTEMPTS=20
  ATTEMPT=0
  TOKEN=""
  
  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    echo "🔄 Thử kết nối NPM API (lần $ATTEMPT/$MAX_ATTEMPTS)..."
    
    # Check if NPM API is responding
    if curl -s -f http://127.0.0.1:81/api/tokens > /dev/null 2>&1; then
      echo "✅ NPM API đã sẵn sàng!"
      
      # Try to get token
      RESPONSE=$(curl -s -X POST http://127.0.0.1:81/api/tokens \
        -H 'Content-Type: application/json' \
        -d '{"identity":"admin@example.com","secret":"changeme"}' \
        2>/dev/null)
      
      TOKEN=$(echo "$RESPONSE" | jq -r .token 2>/dev/null)
      
      if [ "$TOKEN" != "null" ] && [ ! -z "$TOKEN" ] && [ "$TOKEN" != "" ]; then
        echo "🔑 Đã lấy được token thành công!"
        break
      else
        echo "⚠️ API phản hồi nhưng không lấy được token. Response: $RESPONSE"
      fi
    else
      echo "⏳ NPM API chưa sẵn sàng, đợi 15 giây..."
    fi
    
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      sleep 15
    fi
  done

  if [ "$TOKEN" != "null" ] && [ ! -z "$TOKEN" ] && [ "$TOKEN" != "" ]; then
    # Update admin user
    echo "👤 Cập nhật thông tin admin..."
    UPDATE_RESPONSE=$(curl -s -X PUT http://127.0.0.1:81/api/users/1 \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"email":"'"$ADMIN_EMAIL"'","name":"Administrator","nickname":"Admin","roles":["admin"],"is_disabled":false,"auth":[{"type":"password","secret":"'"$ADMIN_PASS"'"}]}')

    echo "📝 Update response: $UPDATE_RESPONSE"

    # Login với pass mới
    echo "🔐 Đăng nhập với mật khẩu mới..."
    NEW_TOKEN_RESPONSE=$(curl -s -X POST http://127.0.0.1:81/api/tokens \
      -H 'Content-Type: application/json' \
      -d '{"identity":"'"$ADMIN_EMAIL"'","secret":"'"$ADMIN_PASS"'"}')
    
    NEW_TOKEN=$(echo "$NEW_TOKEN_RESPONSE" | jq -r .token 2>/dev/null)
    
    if [ "$NEW_TOKEN" != "null" ] && [ ! -z "$NEW_TOKEN" ]; then
      TOKEN="$NEW_TOKEN"
      echo "✅ Đăng nhập thành công với tài khoản mới!"
    else
      echo "⚠️ Không thể đăng nhập với tài khoản mới, sử dụng token cũ. Response: $NEW_TOKEN_RESPONSE"
    fi

    # Tạo proxy host cho WG-Easy
    echo "🔗 Tạo proxy host cho WG-Easy..."
    PROXY_RESPONSE=$(curl -s -X POST http://127.0.0.1:81/api/nginx/proxy-hosts \
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
      }')
    
    echo "🌐 Proxy host response: $PROXY_RESPONSE"
    
    PROXY_ID=$(echo "$PROXY_RESPONSE" | jq -r .id 2>/dev/null)
    if [ "$PROXY_ID" != "null" ] && [ ! -z "$PROXY_ID" ]; then
      echo "✅ Đã tạo proxy host thành công (ID: $PROXY_ID)"
    else
      echo "⚠️ Có thể có lỗi khi tạo proxy host, kiểm tra logs NPM"
    fi
  else
    echo "❌ Không thể lấy token từ NPM API sau $MAX_ATTEMPTS lần thử."
    echo "🔧 Hướng dẫn khắc phục thủ công:"
    echo "   1. Kiểm tra containers: docker ps"
    echo "   2. Xem logs NPM: docker logs npm"
    echo "   3. Truy cập http://localhost:81 để setup thủ công"
    echo "   4. Default login: admin@example.com / changeme"
    echo "   5. Tạo proxy host trỏ $WG_HOST → wg-easy:51821"
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