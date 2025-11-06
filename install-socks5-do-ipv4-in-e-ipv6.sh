#!/bin/bash
# ==========================================
# DigitalOcean SOCKS5 (listen IPv4, egress IPv4/IPv6 per port)
# - Port 60000  -> egress IPv4
# - Port 60001-60015 -> egress 16 IPv6 bắt đầu từ IPv6_START (16 địa chỉ liên tiếp)
# Tested: Debian 11/12 on DO
# ==========================================

set -euo pipefail

# Thông số proxy
PROXY_USER="do_user"
PROXY_PASS="do_pass123"
PORT_START=60000
COUNT=16                   # tạo đúng 16 proxy
IPV6_PREFIXLEN=124         # DigitalOcean IPv6 range /124 (16 địa chỉ)

# Telegram (nếu không dùng, để trống TG_TOKEN/TG_CHAT_ID)
TG_TOKEN=""
TG_CHAT_ID=""

# ======= CÀI ĐẶT PHỤ THUỘC =======
apt update
apt install -y build-essential wget curl unzip python3 iproute2

# ======= XÁC ĐỊNH GIAO DIỆN MẠNG & IP PUBLIC =======
DEV_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}')
IPV4=$(curl -s https://api.ipify.org || curl -s ifconfig.me || curl -s ipinfo.io/ip)
if [[ -z "${DEV_IF}" || -z "${IPV4}" ]]; then
  echo "Không lấy được giao diện mạng hoặc IPv4 công khai." >&2
  exit 1
fi

# ======= TỰ ĐỘNG LẤY IPv6 NHỎ NHẤT TỪ INTERFACE =======
echo "🔍 Đang tìm IPv6 nhỏ nhất trên interface ${DEV_IF}..."
IPV6_START=$(ip -6 addr show dev "$DEV_IF" scope global | \
             grep -oP 'inet6 \K[0-9a-f:]+' | \
             python3 -c "
import sys, ipaddress
ips = [ipaddress.IPv6Address(line.strip()) for line in sys.stdin]
if ips:
    print(min(ips))
else:
    sys.exit(1)
" 2>/dev/null || echo "")

if [[ -z "$IPV6_START" ]]; then
  echo "⚠️  Không tìm thấy IPv6 trên interface ${DEV_IF}."
  read -rp "Nhập IPv6 start thủ công (ví dụ 2604:aaa:1:1::ff:5000): " IPV6_START
  if [[ -z "$IPV6_START" ]]; then
    echo "❌ Cần có IPv6 để tiếp tục." >&2
    exit 1
  fi
else
  echo "✅ Tìm thấy IPv6: ${IPV6_START}"
  read -rp "Sử dụng IPv6 này làm start? (y/n, mặc định y): " CONFIRM
  CONFIRM=${CONFIRM:-y}
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    read -rp "Nhập IPv6 start thủ công: " IPV6_START
  fi
fi

# ======= HÀM TĂNG IPv6 =======
inc_ipv6() {
  local ip="$1"
  python3 - <<EOF
import ipaddress
print(ipaddress.IPv6Address(u"$ip") + 1)
EOF
}

# ======= TẠO DANH SÁCH 16 IPv6 TỪ IPV6_START =======
IPS=()
CURR="$IPV6_START"
for ((i=0; i<COUNT; i++)); do
  IPS+=("$CURR")
  CURR=$(inc_ipv6 "$CURR")
done

# ======= THÊM 16 IPv6 VÀO INTERFACE (nếu chưa có) =======
for ip6 in "${IPS[@]}"; do
  if ! ip -6 addr show dev "$DEV_IF" | grep -q -F " ${ip6}/${IPV6_PREFIXLEN} "; then
    ip -6 addr add "${ip6}/${IPV6_PREFIXLEN}" dev "$DEV_IF" || true
  fi
done

# ======= CÀI 3PROXY (build từ source) =======
if ! command -v /usr/local/3proxy/bin/3proxy >/dev/null 2>&1; then
  # ======= TẢI VÀ BUILD 3PROXY =======
  cd /tmp
  wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.5.tar.gz -O 3proxy.tar.gz
  tar xzf 3proxy.tar.gz
  cd 3proxy-0.9.5

  # Build
  make -f Makefile.Linux

  # Tìm file nhị phân '3proxy'
  BIN_PATH=$(find . -type f -name 3proxy | head -n1)
  if [[ -z "$BIN_PATH" ]]; then
    echo "❌ Không tìm thấy file thực thi 3proxy sau khi build." >&2
    exit 1
  fi

  # Tạo thư mục đích và copy
  mkdir -p /usr/local/3proxy/{bin,conf,log}
  cp "$BIN_PATH" /usr/local/3proxy/bin/

fi

# ======= TẠO CẤU HÌNH 3PROXY =======
CFG="/usr/local/3proxy/conf/3proxy.cfg"
cat > "$CFG" <<EOF
maxconn 500
nserver 8.8.8.8
nscache 65536
log /var/log/3proxy.log D
timeouts 1 5 30 60 180 1800 15 60
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
allow ${PROXY_USER}
# Lưu ý: KHÔNG dùng -a để tránh anonymous; dùng auth strong.
EOF

# Lắng nghe IPv4, egress theo yêu cầu:
# - Port 60000 egress IPv4
# - Port 60001..60015 egress từng IPv6 trong mảng IPS
port="$PORT_START"

# Port 60000 -> egress IPv4
echo "socks -4 -p${port} -i${IPV4} -e${IPV4}" >> "$CFG"
port=$((port+1))

# Các port tiếp theo -> egress IPv6
for ((i=0; i<COUNT; i++)); do
  echo "socks -6 -p${port} -i${IPV4} -e${IPS[$i]}" >> "$CFG"
  port=$((port+1))
done

# ======= SYSTEMD SERVICE =======
cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Multi-SOCKS5 (IPv4 listen, IPv4/IPv6 egress)
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
systemctl enable 3proxy
systemctl restart 3proxy

# ======= GỬI TELEGRAM (nếu cấu hình) =======
if [[ -n "${TG_TOKEN}" && -n "${TG_CHAT_ID}" ]]; then
    # Tạo file chứa danh sách proxy theo format user:pass@ip:port
    PROXY_FILE="/tmp/proxy_list_$(date +%s).txt"
    
    echo "${PROXY_USER}:${PROXY_PASS}@${IPV4}:${PORT_START}" > "$PROXY_FILE"
    for ((i=1; i<=COUNT; i++)); do
        port=$((PORT_START + i))
        echo "${PROXY_USER}:${PROXY_PASS}@${IPV4}:${port}" >> "$PROXY_FILE"
    done

    # Gửi file lên Telegram
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"$PROXY_FILE" \
        -F caption="SOCKS5 Proxy List - ${IPV4}" >/dev/null || true
    
    # Xóa file tạm
    rm -f "$PROXY_FILE"
fi

echo "✅ Hoàn tất. Kết nối tới ${IPV4}:${PORT_START}..$((PORT_START+COUNT-1)) (SOCKS5), user/pass như đã cấu hình."
echo "ℹ️ 60000 egress IPv4; 60001..$((PORT_START+COUNT-1)) egress IPv6 theo list đã thêm vào ${DEV_IF}."
echo ""
echo "📋 Test proxy với curl:"
echo "   curl -x socks5://${PROXY_USER}:${PROXY_PASS}@${IPV4}:${PORT_START} https://api.ipify.org"
echo "   curl -x socks5://${PROXY_USER}:${PROXY_PASS}@${IPV4}:$((PORT_START+1)) https://api64.ipify.org"
