#!/bin/bash
# ==========================================
# General SOCKS5 Proxy (IPv4 listen, IPv6 egress)
# Dành cho các VPS thông thường (không phải DigitalOcean)
# Hỗ trợ:
# - IPv6 tăng dần (sequential)
# - IPv6 random 4 nhóm cuối (random last 4 groups)
# ==========================================

set -euo pipefail

# ======= CẤU HÌNH =======
echo "======================================"
echo "  SOCKS5 Proxy Installer (General)"
echo "======================================"
echo ""

# Kiểm tra và đọc thông tin từ config cũ
OLD_CFG="/usr/local/3proxy/conf/3proxy.cfg"
USE_OLD_CREDS="n"
declare -A OLD_PORT_USER  # Map: port -> username
declare -A OLD_PORT_PASS  # Map: port -> password

if [[ -f "$OLD_CFG" ]]; then
  echo "🔍 Phát hiện cấu hình 3proxy cũ!"
  
  # Parse toàn bộ user:pass từ dòng users
  ALL_USERS=$(grep -E '^users ' "$OLD_CFG" | head -n1)
  if [[ -n "$ALL_USERS" ]]; then
    # Tạo associative array: username -> password
    declare -A USER_PASS_MAP
    for entry in $ALL_USERS; do
      if [[ "$entry" != "users" ]]; then
        # Format: username:CL:password
        username=$(echo "$entry" | cut -d':' -f1)
        password=$(echo "$entry" | cut -d':' -f3)
        if [[ -n "$username" && -n "$password" ]]; then
          USER_PASS_MAP["$username"]="$password"
        fi
      fi
    done
    
    # Parse port và user tương ứng từ các dòng allow/socks
    current_user=""
    while IFS= read -r line; do
      # Tìm dòng allow
      if [[ "$line" =~ ^allow[[:space:]]+([^[:space:]]+) ]]; then
        current_user="${BASH_REMATCH[1]}"
      fi
      # Tìm dòng socks với port
      if [[ "$line" =~ -p([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
        if [[ -n "$current_user" && -n "${USER_PASS_MAP[$current_user]}" ]]; then
          OLD_PORT_USER["$port"]="$current_user"
          OLD_PORT_PASS["$port"]="${USER_PASS_MAP[$current_user]}"
        fi
      fi
    done < "$OLD_CFG"
    
    if [[ ${#OLD_PORT_USER[@]} -gt 0 ]]; then
      echo "   Tìm thấy ${#OLD_PORT_USER[@]} cấu hình user:pass theo port"
      echo "   Ví dụ: Port ${!OLD_PORT_USER[@]:0:1} -> User ${OLD_PORT_USER[${!OLD_PORT_USER[@]:0:1}]}"
      read -rp "Sử dụng lại user:pass cũ cho các port trùng khớp? (y/n, mặc định n): " USE_OLD_CREDS
      USE_OLD_CREDS=${USE_OLD_CREDS:-n}
    fi
  fi
fi

# Nhập thông tin proxy mặc định (dùng cho port mới)
read -rp "Proxy Username mặc định (mặc định: proxy_user): " PROXY_USER
PROXY_USER=${PROXY_USER:-proxy_user}

read -rp "Proxy Password mặc định (mặc định: proxy_pass123): " PROXY_PASS
PROXY_PASS=${PROXY_PASS:-proxy_pass123}

# Random password cho mỗi proxy
echo ""
read -rp "Random password cho mỗi proxy mới? (y/n, mặc định n): " RANDOM_PASS
RANDOM_PASS=${RANDOM_PASS:-n}

read -rp "Port bắt đầu (mặc định: 60000): " PORT_START
PORT_START=${PORT_START:-60000}

read -rp "Số lượng proxy (mặc định: 16): " COUNT
COUNT=${COUNT:-1000}

# Chọn chế độ IPv6
echo ""
echo "Chọn chế độ tạo IPv6:"
echo "1) Tăng dần (Sequential): ::1, ::2, ::3, ..."
echo "2) Random 4 nhóm cuối (Random): ::a1b2:c3d4:e5f6:1234, ..."
read -rp "Lựa chọn (1/2, mặc định 1): " IPV6_MODE
IPV6_MODE=${IPV6_MODE:-1}

# Telegram (tùy chọn)
echo ""
read -rp "Telegram Bot Token (để trống nếu không dùng): " TG_TOKEN
read -rp "Telegram Chat ID (để trống nếu không dùng): " TG_CHAT_ID

# ======= CÀI ĐẶT PHỤ THUỘC =======
echo ""
echo "📦 Đang cài đặt các gói phụ thuộc..."
apt update -qq
apt install -y build-essential wget curl unzip python3 iproute2 >/dev/null 2>&1

# ======= XÁC ĐỊNH GIAO DIỆN MẠNG & IP PUBLIC =======
DEV_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}')
IPV4=$(curl -s https://api.ipify.org || curl -s ifconfig.me || curl -s ipinfo.io/ip)
if [[ -z "${DEV_IF}" || -z "${IPV4}" ]]; then
  echo "❌ Không lấy được giao diện mạng hoặc IPv4 công khai." >&2
  exit 1
fi

echo "✅ Interface: ${DEV_IF}, IPv4: ${IPV4}"

# ======= TỰ ĐỘNG LẤY IPv6 PREFIX =======
echo "🔍 Đang tìm IPv6 trên interface ${DEV_IF}..."
IPV6_BASE=$(ip -6 addr show dev "$DEV_IF" scope global | \
            grep -oP 'inet6 \K[0-9a-f:]+' | head -n1)

if [[ -z "$IPV6_BASE" ]]; then
  echo "⚠️  Không tìm thấy IPv6 trên interface ${DEV_IF}."
  read -rp "Nhập IPv6 base (ví dụ 2001:db8::1): " IPV6_BASE
  if [[ -z "$IPV6_BASE" ]]; then
    echo "❌ Cần có IPv6 để tiếp tục." >&2
    exit 1
  fi
else
  echo "✅ Tìm thấy IPv6: ${IPV6_BASE}"
fi

# Lấy prefix (phần đầu của IPv6, loại bỏ 4 nhóm cuối)
IPV6_PREFIX=$(python3 - <<EOF
import ipaddress
ip = ipaddress.IPv6Address("$IPV6_BASE")
# Lấy 64 bit đầu (4 nhóm đầu) làm prefix
prefix_int = int(ip) & (0xFFFFFFFFFFFFFFFF << 64)
prefix = ipaddress.IPv6Address(prefix_int)
print(str(prefix).rstrip(':') + ':')
EOF
)

echo "📋 IPv6 Prefix: ${IPV6_PREFIX}"

# ======= HÀM TẠO IPv6 =======
generate_ipv6() {
  local index=$1
  if [[ "$IPV6_MODE" == "1" ]]; then
    # Sequential: tăng dần
    python3 - <<EOF
import ipaddress
base = ipaddress.IPv6Address("${IPV6_BASE}")
print(base + $index)
EOF
  else
    # Random 4 nhóm cuối
    python3 - <<EOF
import random
prefix = "${IPV6_PREFIX}"
# Random 4 nhóm cuối (64 bit)
r1 = random.randint(0, 0xFFFF)
r2 = random.randint(0, 0xFFFF)
r3 = random.randint(0, 0xFFFF)
r4 = random.randint(0, 0xFFFF)
print(f"{prefix}{r1:x}:{r2:x}:{r3:x}:{r4:x}")
EOF
  fi
}

# ======= HÀM TẠO RANDOM PASSWORD =======
generate_password() {
  python3 - <<EOF
import random, string
chars = string.ascii_letters + string.digits
print(''.join(random.choice(chars) for _ in range(12)))
EOF
}

# ======= TẠO DANH SÁCH IPv6 =======
echo "🔄 Đang tạo danh sách ${COUNT} IPv6..."
IPS=()
for ((i=0; i<COUNT; i++)); do
  ipv6=$(generate_ipv6 $i)
  IPS+=("$ipv6")
  echo "   [$((i+1))/${COUNT}] ${ipv6}"
done

# ======= TẠO DANH SÁCH PASSWORDS =======
PASSWORDS=()
USERNAMES=()

if [[ "$USE_OLD_CREDS" == "y" || "$USE_OLD_CREDS" == "Y" ]]; then
  echo "🔐 Đang map user:pass từ config cũ..."
  
  # Port đầu tiên (IPv4 proxy)
  port="$PORT_START"
  if [[ -n "${OLD_PORT_USER[$port]}" ]]; then
    # Có config cũ cho port này
    USERNAMES+=("${OLD_PORT_USER[$port]}")
    PASSWORDS+=("${OLD_PORT_PASS[$port]}")
    echo "   Port $port: Giữ user cũ ${OLD_PORT_USER[$port]}"
  else
    # Không có config cũ, dùng mặc định
    USERNAMES+=("$PROXY_USER")
    PASSWORDS+=("$PROXY_PASS")
    echo "   Port $port: Tạo mới user $PROXY_USER"
  fi
  
  # Các port IPv6 tiếp theo
  for ((i=0; i<COUNT; i++)); do
    port=$((PORT_START + i + 1))
    if [[ -n "${OLD_PORT_USER[$port]}" ]]; then
      # Có config cũ cho port này
      USERNAMES+=("${OLD_PORT_USER[$port]}")
      PASSWORDS+=("${OLD_PORT_PASS[$port]}")
      echo "   Port $port: Giữ user cũ ${OLD_PORT_USER[$port]}"
    else
      # Không có config cũ
      if [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
        # Random password mode
        username="${PROXY_USER}${i}"
        password=$(generate_password)
        USERNAMES+=("$username")
        PASSWORDS+=("$password")
        echo "   Port $port: Tạo mới user $username (random pass)"
      else
        # Same password mode
        USERNAMES+=("$PROXY_USER")
        PASSWORDS+=("$PROXY_PASS")
        echo "   Port $port: Tạo mới user $PROXY_USER"
      fi
    fi
  done
  echo "✅ Đã map ${COUNT} user:pass (giữ cũ + tạo mới)"
  
elif [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
  # Random password mode (không dùng config cũ)
  echo "🔐 Đang tạo random passwords cho ${COUNT} proxy..."
  
  # Port đầu tiên
  USERNAMES+=("$PROXY_USER")
  PASSWORDS+=("$PROXY_PASS")
  
  # Các port tiếp theo
  for ((i=0; i<COUNT; i++)); do
    username="${PROXY_USER}${i}"
    pass=$(generate_password)
    USERNAMES+=("$username")
    PASSWORDS+=("$pass")
  done
  echo "✅ Đã tạo $((COUNT+1)) random passwords"
else
  # Same password mode (không dùng config cũ)
  echo "🔐 Sử dụng cùng password cho tất cả proxy"
  
  # Port đầu tiên + các port tiếp theo
  for ((i=0; i<=COUNT; i++)); do
    USERNAMES+=("$PROXY_USER")
    PASSWORDS+=("$PROXY_PASS")
  done
fi

# ======= THÊM IPv6 VÀO INTERFACE =======
echo "🌐 Đang thêm IPv6 vào interface ${DEV_IF}..."
for ip6 in "${IPS[@]}"; do
  if ! ip -6 addr show dev "$DEV_IF" | grep -q -F " ${ip6}/64 "; then
    ip -6 addr add "${ip6}/64" dev "$DEV_IF" || true
  fi
done

# ======= CÀI 3PROXY (build từ source) =======
if ! command -v /usr/local/3proxy/bin/3proxy >/dev/null 2>&1; then
  echo "📥 Đang tải và build 3proxy..."
  cd /tmp
  wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.5.tar.gz -O 3proxy.tar.gz
  tar xzf 3proxy.tar.gz
  cd 3proxy-0.9.5

  # Build
  make -f Makefile.Linux >/dev/null 2>&1

  # Tìm file nhị phân '3proxy'
  BIN_PATH=$(find . -type f -name 3proxy | head -n1)
  if [[ -z "$BIN_PATH" ]]; then
    echo "❌ Không tìm thấy file thực thi 3proxy sau khi build." >&2
    exit 1
  fi

  # Tạo thư mục đích và copy
  mkdir -p /usr/local/3proxy/{bin,conf,log}
  cp "$BIN_PATH" /usr/local/3proxy/bin/
  chmod +x /usr/local/3proxy/bin/3proxy
  echo "✅ 3proxy đã được cài đặt"
else
  echo "✅ 3proxy đã tồn tại"
fi

# ======= TẠO CẤU HÌNH 3PROXY =======
echo "⚙️  Đang tạo cấu hình 3proxy..."
CFG="/usr/local/3proxy/conf/3proxy.cfg"
cat > "$CFG" <<EOF
maxconn 500
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy.log D
timeouts 1 5 30 60 180 1800 15 60
auth strong
EOF

# ======= TẠO CẤU HÌNH 3PROXY =======
echo "⚙️  Đang tạo cấu hình 3proxy..."
CFG="/usr/local/3proxy/conf/3proxy.cfg"
cat > "$CFG" <<EOF
maxconn 500
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy.log D
timeouts 1 5 30 60 180 1800 15 60
auth strong
EOF

# Thu thập tất cả unique users
declare -A UNIQUE_USERS
for ((i=0; i<${#USERNAMES[@]}; i++)); do
  UNIQUE_USERS["${USERNAMES[$i]}"]="${PASSWORDS[$i]}"
done

# Tạo dòng users với tất cả user:pass
USER_LIST=""
for user in "${!UNIQUE_USERS[@]}"; do
  USER_LIST="${USER_LIST} ${user}:CL:${UNIQUE_USERS[$user]}"
done
echo "users${USER_LIST}" >> "$CFG"
echo "" >> "$CFG"

# Tạo config cho từng port
port="$PORT_START"

# Port đầu tiên -> IPv4 proxy
username="${USERNAMES[0]}"
cat >> "$CFG" <<EOF
# Proxy IPv4 cho ${username} trên port ${port}
allow ${username}
socks -4 -p${port} -i${IPV4} -e${IPV4}
flush

EOF
port=$((port+1))

# Các port tiếp theo -> IPv6 proxies
for ((i=0; i<COUNT; i++)); do
  username="${USERNAMES[$((i+1))]}"
  cat >> "$CFG" <<EOF
# Proxy IPv6 cho ${username} trên port ${port}
allow ${username}
socks -6 -p${port} -i${IPV4} -e${IPS[$i]}
flush

EOF
  port=$((port+1))
done

# ======= SYSTEMD SERVICE =======
echo "🔧 Đang tạo systemd service..."
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Multi-SOCKS5 (IPv6 egress)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/3proxy/bin/3proxy ${CFG}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null 2>&1
systemctl restart 3proxy

# ======= GỬI TELEGRAM (nếu cấu hình) =======
if [[ -n "${TG_TOKEN}" && -n "${TG_CHAT_ID}" ]]; then
    echo "📤 Đang gửi thông tin lên Telegram..."
    # Tạo file chứa danh sách proxy theo format user:pass@ip:port
    PROXY_FILE="/tmp/proxy_list_$(date +%s).txt"
    
    # Thêm IPv4 proxy đầu tiên (index 0)
    echo "${USERNAMES[0]}:${PASSWORDS[0]}@${IPV4}:${PORT_START}" > "$PROXY_FILE"
    
    # Thêm các IPv6 proxies
    for ((i=0; i<COUNT; i++)); do
        port=$((PORT_START + i + 1))
        echo "${USERNAMES[$((i+1))]}:${PASSWORDS[$((i+1))]}@${IPV4}:${port}" >> "$PROXY_FILE"
    done

    # Gửi file lên Telegram
    MODE_TEXT="Sequential"
    [[ "$IPV6_MODE" == "2" ]] && MODE_TEXT="Random"
    PASS_TEXT="Same Password"
    [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]] && PASS_TEXT="Random Passwords"
    [[ "$USE_OLD_CREDS" == "y" || "$USE_OLD_CREDS" == "Y" ]] && PASS_TEXT="${PASS_TEXT} + Reused Old"
    
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"$PROXY_FILE" \
        -F caption="SOCKS5 Proxy List - ${IPV4} (${MODE_TEXT} IPv6, ${PASS_TEXT})" >/dev/null || true
    
    # Xóa file tạm
    rm -f "$PROXY_FILE"
    echo "✅ Đã gửi file lên Telegram"
fi

# ======= HOÀN TẤT =======
echo ""
echo "======================================"
echo "✅ CÀI ĐẶT HOÀN TẤT!"
echo "======================================"
echo ""
echo "📋 Thông tin proxy:"
echo "   Server: ${IPV4}"
echo "   Ports: ${PORT_START} - $((PORT_START+COUNT))"
if [[ "$USE_OLD_CREDS" == "y" || "$USE_OLD_CREDS" == "Y" ]]; then
  echo "   Users: Mixed (reused old + new)"
  echo "   Passwords: Xem file Telegram hoặc /usr/local/3proxy/conf/3proxy.cfg"
elif [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
  echo "   Users: ${USERNAMES[1]} - ${USERNAMES[$COUNT]}"
  echo "   Passwords: Random (xem file Telegram hoặc /usr/local/3proxy/conf/3proxy.cfg)"
else
  echo "   User: ${PROXY_USER}"
  echo "   Pass: ${PROXY_PASS}"
fi
echo "   IPv6 Mode: $([ "$IPV6_MODE" == "1" ] && echo "Sequential" || echo "Random")"
echo ""
echo "📋 Test proxy với curl:"
echo "   curl -x socks5://${USERNAMES[0]}:${PASSWORDS[0]}@${IPV4}:${PORT_START} https://api.ipify.org"
echo "   curl -x socks5://${USERNAMES[1]}:${PASSWORDS[1]}@${IPV4}:$((PORT_START+1)) https://api64.ipify.org"
echo ""
echo "🔍 Kiểm tra trạng thái: systemctl status 3proxy"
echo "📝 Xem log: tail -f /var/log/3proxy.log"
echo ""
