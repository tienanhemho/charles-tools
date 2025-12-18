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

# File lưu trữ cấu hình để tự động chạy lại khi boot
CONFIG_FILE="/usr/local/3proxy/conf/installer.conf"
AUTO_RUN_MODE=false

# Kiểm tra nếu đang chạy từ systemd service (auto mode)
if [[ "${1:-}" == "--auto" ]]; then
  AUTO_RUN_MODE=true
  echo "🔄 Chạy tự động sau khi reboot..."
  
  # Load config từ file
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "✅ Đã load config từ ${CONFIG_FILE}"
  else
    echo "❌ Không tìm thấy file config ${CONFIG_FILE}" >&2
    exit 1
  fi
fi

# Kiểm tra và đọc thông tin từ config cũ
OLD_CFG="/usr/local/3proxy/conf/3proxy.cfg"
USE_OLD_CREDS="n"
declare -A OLD_PORT_USER  # Map: port -> username
declare -A OLD_PORT_PASS  # Map: port -> password

if [[ -f "$OLD_CFG" ]]; then
  echo "🔍 Phát hiện cấu hình 3proxy cũ!"
  
  # Parse user:pass và port từ config mới (nhiều dòng users riêng biệt)
  declare -A USER_PASS_MAP
  current_user=""
  current_pass=""
  
  while IFS= read -r line; do
    # Tìm dòng users (format: users username:CL:password)
    if [[ "$line" =~ ^users[[:space:]]+([^:]+):CL:(.+) ]]; then
      current_user="${BASH_REMATCH[1]}"
      current_pass="${BASH_REMATCH[2]}"
      USER_PASS_MAP["$current_user"]="$current_pass"
    fi
    
    # Tìm dòng socks với port
    if [[ "$line" =~ -p([0-9]+) ]]; then
      port="${BASH_REMATCH[1]}"
      # Liên kết port với user gần nhất (theo thứ tự trong file)
      if [[ -n "$current_user" && -n "$current_pass" ]]; then
        OLD_PORT_USER["$port"]="$current_user"
        OLD_PORT_PASS["$port"]="$current_pass"
      fi
    fi
    
    # Reset current_user khi gặp flush (kết thúc group)
    if [[ "$line" =~ ^flush ]]; then
      current_user=""
      current_pass=""
    fi
  done < "$OLD_CFG"
  
  if [[ ${#OLD_PORT_USER[@]} -gt 0 ]]; then
    echo "   Tìm thấy ${#OLD_PORT_USER[@]} cấu hình user:pass theo port"
    # Lấy port đầu tiên một cách an toàn
    first_port=""
    for port in "${!OLD_PORT_USER[@]}"; do
      if [[ -z "$first_port" ]] || [[ "$port" -lt "$first_port" ]]; then
        first_port="$port"
      fi
    done
    if [[ -n "$first_port" ]]; then
      echo "   Ví dụ: Port ${first_port} -> User ${OLD_PORT_USER[$first_port]}"
    fi
    
    # Chỉ hỏi khi không ở auto mode
    if [[ "$AUTO_RUN_MODE" == false ]]; then
      echo ""
      read -rp "Sử dụng lại user:pass cũ cho các port trùng khớp? (y/n, mặc định n): " USE_OLD_CREDS
      USE_OLD_CREDS=${USE_OLD_CREDS:-n}
    fi
  else
    echo "   ⚠️  Không tìm thấy cấu hình user:pass nào trong file cũ"
  fi
fi

# Nhập thông tin proxy mặc định (dùng cho port mới)
if [[ "$AUTO_RUN_MODE" == false ]]; then
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

  read -rp "Số lượng proxy (mặc định: 1000): " COUNT
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
  
  # Tự động chạy lại sau reboot
  echo ""
  read -rp "Tự động chạy lại script khi reboot? (y/n, mặc định y): " AUTO_RERUN
  AUTO_RERUN=${AUTO_RERUN:-y}
else
  echo "ℹ️  Sử dụng cấu hình đã lưu"
fi

# ======= CÀI ĐẶT PHỤ THUỘC =======
echo ""
echo "📦 Đang cài đặt các gói phụ thuộc..."
apt update -qq
apt install -y build-essential wget curl unzip python3 iproute2 >/dev/null 2>&1

# ======= XÁC ĐỊNH GIAO DIỆN MẠNG & IP =======
DEV_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}')
if [[ -z "${DEV_IF}" ]]; then
  echo "❌ Không lấy được giao diện mạng." >&2
  exit 1
fi

# Lấy IP LAN từ interface (để bind 3proxy)
IPV4_LAN=$(ip -4 addr show dev "$DEV_IF" | grep -oP 'inet \K[\d.]+' | head -n1)
if [[ -z "${IPV4_LAN}" ]]; then
  echo "❌ Không lấy được IPv4 LAN từ interface ${DEV_IF}." >&2
  exit 1
fi

# Lấy IP Public (để hiển thị trong proxy list)
IPV4_PUBLIC=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ipinfo.io/ip || echo "")

echo "✅ Interface: ${DEV_IF}"
echo "✅ IPv4 LAN (bind): ${IPV4_LAN}"
if [[ -n "${IPV4_PUBLIC}" ]]; then
  echo "✅ IPv4 Public (detected): ${IPV4_PUBLIC}"
else
  echo "⚠️  Không detect được IPv4 Public"
fi

# Cho phép user override IP Public
if [[ "$AUTO_RUN_MODE" == false ]]; then
  echo ""
  read -rp "IPv4 Public cho proxy list (Enter để dùng: ${IPV4_PUBLIC:-$IPV4_LAN}): " IPV4_PUBLIC_INPUT
  if [[ -n "${IPV4_PUBLIC_INPUT}" ]]; then
    IPV4_PUBLIC="${IPV4_PUBLIC_INPUT}"
  else
    IPV4_PUBLIC="${IPV4_PUBLIC:-$IPV4_LAN}"
  fi
else
  # Auto mode: dùng IP Public detected hoặc fallback sang LAN
  IPV4_PUBLIC="${IPV4_PUBLIC:-$IPV4_LAN}"
fi

echo "📋 Sử dụng IPv4 Public: ${IPV4_PUBLIC}"

# ======= TỰ ĐỘNG LẤY IPv6 PREFIX =======
echo "🔍 Đang tìm IPv6 trên interface ${DEV_IF}..."
IPV6_BASE=$(ip -6 addr show dev "$DEV_IF" scope global | \
            grep -oP 'inet6 \K[0-9a-f:]+' | head -n1 || true)

if [[ -z "$IPV6_BASE" ]]; then
  if [[ "$AUTO_RUN_MODE" == false ]]; then
    echo "⚠️  Không tìm thấy IPv6 trên interface ${DEV_IF}."
    echo ""
    read -rp "Nhập IPv6 base (ví dụ 2001:db8::1): " IPV6_BASE
    if [[ -z "$IPV6_BASE" ]]; then
      echo "❌ Cần có IPv6 để tiếp tục." >&2
      exit 1
    fi
    echo "✅ Sử dụng IPv6: ${IPV6_BASE}"
  else
    echo "❌ Không tìm thấy IPv6 trên interface ${DEV_IF} (auto mode)." >&2
    exit 1
  fi
else
  echo "✅ Tìm thấy IPv6: ${IPV6_BASE}"
fi

# Lấy prefix (phần đầu của IPv6, loại bỏ 4 nhóm cuối)
echo "🔄 Đang tính toán IPv6 prefix..."
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
if [[ "$IPV6_MODE" == "1" ]]; then
  # Sequential: tạo tất cả cùng lúc
  IPS=($(python3 - <<EOF
import ipaddress
base = ipaddress.IPv6Address("${IPV6_BASE}")
for i in range(${COUNT}):
    print(base + i)
EOF
))
else
  # Random: tạo tất cả cùng lúc
  IPS=($(python3 - <<EOF
import random
prefix = "${IPV6_PREFIX}"
for i in range(${COUNT}):
    r1 = random.randint(0, 0xFFFF)
    r2 = random.randint(0, 0xFFFF)
    r3 = random.randint(0, 0xFFFF)
    r4 = random.randint(0, 0xFFFF)
    print(f"{prefix}{r1:x}:{r2:x}:{r3:x}:{r4:x}")
EOF
))
fi
echo "✅ Đã tạo ${#IPS[@]} IPv6"

# ======= TẠO DANH SÁCH PASSWORDS =======
PASSWORDS=()
USERNAMES=()

if [[ "$USE_OLD_CREDS" == "y" || "$USE_OLD_CREDS" == "Y" ]]; then
  echo "🔐 Đang map user:pass từ config cũ..."
  
  reused=0
  created=0
  
  # Tạo passwords mới nếu cần (cho random mode)
  if [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
    NEW_PASSWORDS=($(python3 - <<EOF
import random, string
chars = string.ascii_letters + string.digits
for i in range($((COUNT+1))):
    print(''.join(random.choice(chars) for _ in range(12)))
EOF
))
  fi
  
  # Port đầu tiên (IPv4 proxy)
  port="$PORT_START"
  if [[ -n "${OLD_PORT_USER[$port]:-}" ]]; then
    USERNAMES+=("${OLD_PORT_USER[$port]}")
    PASSWORDS+=("${OLD_PORT_PASS[$port]}")
    reused=$((reused + 1))
  else
    USERNAMES+=("$PROXY_USER")
    PASSWORDS+=("$PROXY_PASS")
    created=$((created + 1))
  fi
  
  # Các port IPv6 tiếp theo
  for ((i=0; i<COUNT; i++)); do
    port=$((PORT_START + i + 1))
    if [[ -n "${OLD_PORT_USER[$port]:-}" ]]; then
      USERNAMES+=("${OLD_PORT_USER[$port]}")
      PASSWORDS+=("${OLD_PORT_PASS[$port]}")
      reused=$((reused + 1))
    else
      if [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
        USERNAMES+=("${PROXY_USER}${i}")
        PASSWORDS+=("${NEW_PASSWORDS[$i]}")
      else
        USERNAMES+=("$PROXY_USER")
        PASSWORDS+=("$PROXY_PASS")
      fi
      created=$((created + 1))
    fi
  done
  echo "✅ Giữ lại ${reused} user cũ, tạo mới ${created} user"
  
elif [[ "$RANDOM_PASS" == "y" || "$RANDOM_PASS" == "Y" ]]; then
  # Random password mode (không dùng config cũ)
  echo "🔐 Đang tạo random passwords cho $((COUNT+1)) proxy..."
  
  # Tạo tất cả passwords cùng lúc
  ALL_PASSWORDS=($(python3 - <<EOF
import random, string
chars = string.ascii_letters + string.digits
for i in range($((COUNT+1))):
    print(''.join(random.choice(chars) for _ in range(12)))
EOF
))
  
  # Map vào arrays
  for ((i=0; i<=COUNT; i++)); do
    USERNAMES+=("${PROXY_USER}${i}")
    PASSWORDS+=("${ALL_PASSWORDS[$i]}")
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

# ======= CLEAN IPv6 CŨ (tùy chọn) =======
if [[ "$AUTO_RUN_MODE" == false ]]; then
  echo ""
  read -rp "Xóa tất cả IPv6 cũ trên interface ${DEV_IF}? (y/n, mặc định n): " CLEAN_IPV6
  CLEAN_IPV6=${CLEAN_IPV6:-n}
else
  # Auto mode: tự động clean IPv6 cũ
  CLEAN_IPV6="y"
  echo ""
  echo "🧹 Auto mode: sẽ xóa IPv6 cũ (giữ lại IPv6 base)"
fi

if [[ "$CLEAN_IPV6" == "y" || "$CLEAN_IPV6" == "Y" ]]; then
  echo "🧹 Đang xóa IPv6 cũ trên interface ${DEV_IF} (giữ lại IPv6 base)..."
  
  # Tạm tắt strict mode để xử lý lỗi
  set +euo pipefail
  
  # Lấy danh sách IPv6 scope global
  OLD_IPV6_LIST=$(ip -6 addr show dev "$DEV_IF" scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+/\d+')
  
  count=0
  skipped=0
  
  if [[ -n "$OLD_IPV6_LIST" ]]; then
    while IFS= read -r ipv6_cidr; do
      if [[ -n "$ipv6_cidr" ]]; then
        # Tách địa chỉ IPv6 (bỏ /64)
        ipv6_addr="${ipv6_cidr%%/*}"
        # Giữ lại IPv6_BASE, xóa các IPv6 khác
        if [[ "$ipv6_addr" != "$IPV6_BASE" ]]; then
          ip -6 addr del "$ipv6_cidr" dev "$DEV_IF" 2>/dev/null
          if [[ $? -eq 0 ]]; then
            count=$((count + 1))
          fi
        else
          skipped=$((skipped + 1))
        fi
      fi
    done <<< "$OLD_IPV6_LIST"
    echo "✅ Đã xóa ${count} IPv6 cũ, giữ lại ${skipped} IPv6 base"
  else
    echo "ℹ️  Không có IPv6 nào để xóa"
  fi
  
  # Bật lại strict mode
  set -euo pipefail
fi

# ======= THÊM IPv6 VÀO INTERFACE =======
echo "🌐 Đang thêm ${COUNT} IPv6 mới vào interface ${DEV_IF}..."
added=0
skipped=0
total=${#IPS[@]}
for ip6 in "${IPS[@]}"; do
  if ! ip -6 addr show dev "$DEV_IF" | grep -q -F " ${ip6}/64 "; then
    ip -6 addr add "${ip6}/64" dev "$DEV_IF" || true
    added=$((added + 1))
  else
    skipped=$((skipped + 1))
  fi
  # Hiển thị progress mỗi 100 địa chỉ
  current=$((added + skipped))
  if (( current % 100 == 0 )) || (( current == total )); then
    echo "   Progress: ${current}/${total} (added: ${added}, skipped: ${skipped})"
  fi
done
echo "✅ Hoàn tất thêm IPv6: ${added} added, ${skipped} skipped"

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

# Tạo header chung
cat > "$CFG" <<EOF
# 3proxy configuration - Separated groups
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
maxconn 500
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy.log D
timeouts 1 5 30 60 180 1800 15 60

EOF

# Tạo config cho từng port theo format group riêng biệt
port="$PORT_START"

# Port đầu tiên -> IPv4 proxy
username="${USERNAMES[0]}"
password="${PASSWORDS[0]}"
cat >> "$CFG" <<EOF
# --- Group for ${username} (IPv4) ---
auth strong
users ${username}:CL:${password}
allow ${username}
deny *
socks -4 -p${port} -i${IPV4_LAN} -e${IPV4_LAN}
flush

EOF
port=$((port+1))

# Các port tiếp theo -> IPv6 proxies
for ((i=0; i<COUNT; i++)); do
  username="${USERNAMES[$((i+1))]}"
  password="${PASSWORDS[$((i+1))]}"
  cat >> "$CFG" <<EOF
# --- Group for ${username} ---
auth strong
users ${username}:CL:${password}
allow ${username}
deny *
socks -6 -p${port} -i${IPV4_LAN} -e${IPS[$i]}
flush

EOF
  port=$((port+1))
done

echo "✅ Đã tạo config với $((COUNT+1)) groups riêng biệt"

# ======= LƯU CẤU HÌNH ĐỂ TỰ ĐỘNG CHẠY LẠI =======
if [[ "$AUTO_RUN_MODE" == false && ("$AUTO_RERUN" == "y" || "$AUTO_RERUN" == "Y") ]]; then
  echo "💾 Đang lưu cấu hình..."
  cat > "$CONFIG_FILE" <<EOFCONFIG
# Configuration for auto-rerun after reboot
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
PROXY_USER="$PROXY_USER"
PROXY_PASS="$PROXY_PASS"
RANDOM_PASS="$RANDOM_PASS"
PORT_START=$PORT_START
COUNT=$COUNT
IPV6_MODE=$IPV6_MODE
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
USE_OLD_CREDS="y"
EOFCONFIG
  chmod 600 "$CONFIG_FILE"
  echo "✅ Đã lưu cấu hình vào ${CONFIG_FILE}"
fi

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

# Tạo service tự động chạy lại script khi boot (nếu được bật)
if [[ "$AUTO_RUN_MODE" == false && ("$AUTO_RERUN" == "y" || "$AUTO_RERUN" == "Y") ]]; then
  echo "🔧 Đang tạo service tự động chạy lại khi boot..."
  
  # Lưu script vào vị trí cố định
  SCRIPT_PATH="/usr/local/bin/install-socks5-general-ipv6.sh"
  cp "$0" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  
  cat >/etc/systemd/system/3proxy-autorun.service <<EOF
[Unit]
Description=Auto-rerun 3proxy installer after reboot
After=network-online.target
Wants=network-online.target
Before=3proxy.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --auto
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable 3proxy-autorun >/dev/null 2>&1
  echo "✅ Đã tạo service tự động chạy lại khi boot"
else
  # Nếu đang ở auto mode hoặc user không muốn auto rerun, chỉ enable 3proxy
  systemctl daemon-reload
  systemctl enable 3proxy >/dev/null 2>&1
fi

systemctl restart 3proxy

# ======= GỬI TELEGRAM (nếu cấu hình) =======
if [[ -n "${TG_TOKEN}" && -n "${TG_CHAT_ID}" ]]; then
    echo "📤 Đang gửi thông tin lên Telegram..."
    # Tạo file chứa danh sách proxy theo format user:pass@ip:port
    PROXY_FILE="/tmp/proxy_list_$(date +%s).txt"
    
    # Thêm IPv4 proxy đầu tiên (index 0)
    echo "${USERNAMES[0]}:${PASSWORDS[0]}@${IPV4_PUBLIC}:${PORT_START}" > "$PROXY_FILE"
    
    # Thêm các IPv6 proxies
    for ((i=0; i<COUNT; i++)); do
        port=$((PORT_START + i + 1))
        echo "${USERNAMES[$((i+1))]}:${PASSWORDS[$((i+1))]}@${IPV4_PUBLIC}:${port}" >> "$PROXY_FILE"
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
        -F caption="SOCKS5 Proxy List - ${IPV4_PUBLIC} (${MODE_TEXT} IPv6, ${PASS_TEXT})" >/dev/null || true
    
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
echo "   Server (Public): ${IPV4_PUBLIC}"
echo "   Server (LAN): ${IPV4_LAN}"
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
echo "   curl -x socks5://${USERNAMES[0]}:${PASSWORDS[0]}@${IPV4_PUBLIC}:${PORT_START} https://api.ipify.org"
echo "   curl -x socks5://${USERNAMES[1]}:${PASSWORDS[1]}@${IPV4_PUBLIC}:$((PORT_START+1)) https://api64.ipify.org"
echo ""
echo "🔍 Kiểm tra trạng thái: systemctl status 3proxy"
echo "📝 Xem log: tail -f /var/log/3proxy.log"
echo ""
