#!/bin/bash
set -e

# --- Check sudo privileges ---
check_sudo() {
  if [ "$EUID" -eq 0 ]; then
    echo "⚠️ Script đang chạy với quyền root. Khuyến nghị chạy với sudo thay vì root user."
    SUDO_CMD=""
  elif sudo -n true 2>/dev/null; then
    echo "✅ Sudo privileges đã có sẵn"
    SUDO_CMD="sudo"
  else
    echo "❌ Script cần quyền sudo để thực hiện các tha    rhel)
      echo "📦 Cài đặt Docker cho RHEL/CentOS..."
      # Remove old versions
      $SUDO_CMD $PKG_MANAGER remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
      
      # Install yum-utils and add Docker repository
      install_packages yum-utils
      $SUDO_CMD yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      install_packages $(get_package_names "docker")
      ;;hống."
    echo "Vui lòng chạy: sudo $0"
    exit 1
  fi
}

# --- Detect Linux Distribution ---
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
    DISTRO_ID=$ID
    DISTRO_ID_LIKE=$ID_LIKE
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
    DISTRO_ID=$(echo $OS | tr '[:upper:]' '[:lower:]')
  elif [ -f /etc/redhat-release ]; then
    OS=$(cat /etc/redhat-release | cut -d ' ' -f1)
    VER=$(cat /etc/redhat-release | sed 's/.*release //' | sed 's/ .*//')
    DISTRO_ID="rhel"
  else
    OS=$(uname -s)
    VER=$(uname -r)
    DISTRO_ID="unknown"
  fi
  
  # Normalize distro identification
  case "$DISTRO_ID" in
    ubuntu)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      ;;
    debian)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      ;;
    centos|rhel|"red hat"*)
      DISTRO_FAMILY="rhel"
      PKG_MANAGER="yum"
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      fi
      ;;
    fedora)
      DISTRO_FAMILY="fedora"
      PKG_MANAGER="dnf"
      ;;
    arch|manjaro)
      DISTRO_FAMILY="arch"
      PKG_MANAGER="pacman"
      ;;
    opensuse*|sles)
      DISTRO_FAMILY="opensuse"
      PKG_MANAGER="zypper"
      ;;
    *)
      # Check ID_LIKE for derivative distributions
      if [[ "$DISTRO_ID_LIKE" == *"debian"* ]] || [[ "$DISTRO_ID_LIKE" == *"ubuntu"* ]]; then
        DISTRO_FAMILY="debian"
        PKG_MANAGER="apt"
      elif [[ "$DISTRO_ID_LIKE" == *"rhel"* ]] || [[ "$DISTRO_ID_LIKE" == *"fedora"* ]]; then
        DISTRO_FAMILY="rhel"
        PKG_MANAGER="yum"
        if command -v dnf >/dev/null 2>&1; then
          PKG_MANAGER="dnf"
        fi
      elif [[ "$DISTRO_ID_LIKE" == *"arch"* ]]; then
        DISTRO_FAMILY="arch"
        PKG_MANAGER="pacman"
      elif [[ "$DISTRO_ID_LIKE" == *"suse"* ]]; then
        DISTRO_FAMILY="opensuse"
        PKG_MANAGER="zypper"
      else
        DISTRO_FAMILY="unknown"
        PKG_MANAGER="unknown"
      fi
      ;;
  esac
  
  echo "🔍 Phát hiện hệ điều hành: $OS $VER ($DISTRO_FAMILY)"
  echo "📦 Package manager: $PKG_MANAGER"
}

# --- Package management functions ---
update_system() {
  echo "🔄 Cập nhật hệ thống..."
  case $PKG_MANAGER in
    apt)
      $SUDO_CMD apt update && $SUDO_CMD apt upgrade -y
      ;;
    yum)
      $SUDO_CMD yum update -y
      ;;
    dnf)
      $SUDO_CMD dnf update -y
      ;;
    pacman)
      $SUDO_CMD pacman -Syu --noconfirm
      ;;
    zypper)
      $SUDO_CMD zypper refresh && $SUDO_CMD zypper update -y
      ;;
    *)
      echo "⚠️ Không nhận diện được package manager. Vui lòng cập nhật hệ thống thủ công."
      ;;
  esac
}

install_packages() {
  local packages="$@"
  echo "📦 Cài đặt packages: $packages"
  
  case $PKG_MANAGER in
    apt)
      $SUDO_CMD apt install -y $packages
      ;;
    yum)
      $SUDO_CMD yum install -y $packages
      ;;
    dnf)
      $SUDO_CMD dnf install -y $packages
      ;;
    pacman)
      $SUDO_CMD pacman -S --noconfirm $packages
      ;;
    zypper)
      $SUDO_CMD zypper install -y $packages
      ;;
    *)
      echo "❌ Không nhận diện được package manager. Vui lòng cài đặt packages sau thủ công: $packages"
      return 1
      ;;
  esac
}

# --- Get package names for different distros ---
get_package_names() {
  local tool="$1"
  case $tool in
    "base_packages")
      case $DISTRO_FAMILY in
        debian)
          echo "ca-certificates curl jq dnsutils"
          ;;
        rhel|fedora)
          echo "ca-certificates curl jq bind-utils"
          ;;
        arch)
          echo "curl jq bind-tools"
          ;;
        opensuse)
          echo "ca-certificates curl jq bind-utils"
          ;;
        *)
          echo "curl jq"
          ;;
      esac
      ;;
    "docker")
      case $DISTRO_FAMILY in
        debian)
          echo "docker-ce docker-ce-cli containerd.io"
          ;;
        rhel|fedora)
          echo "docker-ce docker-ce-cli containerd.io"
          ;;
        arch)
          echo "docker"
          ;;
        opensuse)
          echo "docker"
          ;;
        *)
          echo "docker"
          ;;
      esac
      ;;
  esac
}

# --- Check required tools ---
check_required_tools() {
  echo "🔍 Kiểm tra các tools cần thiết..."
  
  local missing_tools=""
  
  # Check curl
  if ! command -v curl >/dev/null 2>&1; then
    missing_tools="$missing_tools curl"
    echo "❌ curl - chưa có"
  else
    echo "✅ curl - đã có sẵn"
  fi
  
  # Check jq
  if ! command -v jq >/dev/null 2>&1; then
    missing_tools="$missing_tools jq"
    echo "❌ jq - chưa có"
  else
    echo "✅ jq - đã có sẵn"
  fi
  
  # Check ca-certificates (skip if already installed)
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    if ! dpkg -l | grep -q "ca-certificates"; then
      missing_tools="$missing_tools ca-certificates"
      echo "❌ ca-certificates - chưa có"
    else
      echo "✅ ca-certificates - đã có sẵn"
    fi
  elif [ "$DISTRO_FAMILY" = "rhel" ] || [ "$DISTRO_FAMILY" = "fedora" ] || [ "$DISTRO_FAMILY" = "opensuse" ]; then
    # Trên RHEL/Fedora/openSUSE, ca-certificates thường đã có sẵn
    if ! rpm -q ca-certificates >/dev/null 2>&1; then
      missing_tools="$missing_tools ca-certificates"
      echo "❌ ca-certificates - chưa có"
    else
      echo "✅ ca-certificates - đã có sẵn"
    fi
  fi
  
  # Check DNS utilities
  if command -v getent >/dev/null 2>&1; then
    echo "✅ getent (DNS resolution) - đã có sẵn"
  elif command -v nslookup >/dev/null 2>&1; then
    echo "✅ nslookup (DNS resolution) - đã có sẵn"
  elif command -v dig >/dev/null 2>&1; then
    echo "✅ dig (DNS resolution) - đã có sẵn"
  else
    # Cần cài DNS utilities
    case $DISTRO_FAMILY in
      debian)
        missing_tools="$missing_tools dnsutils"
        echo "❌ DNS utilities (dnsutils) - chưa có"
        ;;
      rhel|fedora|opensuse)
        missing_tools="$missing_tools bind-utils"
        echo "❌ DNS utilities (bind-utils) - chưa có"
        ;;
      arch)
        missing_tools="$missing_tools bind-tools"
        echo "❌ DNS utilities (bind-tools) - chưa có"
        ;;
    esac
  fi
  
  # Check openssl (for password generation)
  if ! command -v openssl >/dev/null 2>&1; then
    missing_tools="$missing_tools openssl"
    echo "❌ openssl - chưa có"
  else
    echo "✅ openssl - đã có sẵn"
  fi
  
  if [ ! -z "$missing_tools" ]; then
    echo "📦 Cài đặt các tools còn thiếu:$missing_tools"
    install_packages $missing_tools
  else
    echo "🎉 Tất cả tools cần thiết đã có sẵn!"
  fi
}

echo "==============================="
echo " 🚀 WireGuard + WG-Easy (+ NPM) Installer"
echo "==============================="
echo ""
echo "🖥️ Hỗ trợ các bản phân phối Linux:"
echo "   • Ubuntu/Debian (apt)"
echo "   • CentOS/RHEL/Fedora (yum/dnf)"  
echo "   • Arch Linux (pacman)"
echo "   • openSUSE (zypper)"
echo ""

# --- Check sudo privileges first ---
check_sudo

# --- Detect distribution first ---
detect_distro

if [ "$DISTRO_FAMILY" = "unknown" ]; then
  echo "❌ Không nhận diện được bản phân phối Linux này."
  echo "Script chỉ hỗ trợ: Ubuntu/Debian, CentOS/RHEL/Fedora, Arch Linux, openSUSE"
  exit 1
fi

echo ""
echo "💡 Script này có thể chạy lại an toàn:"
echo "   • Tự động bypass Docker nếu đã cài"
echo "   • Backup cấu hình cũ trước khi tạo mới"
echo "   • Dừng containers cũ trước khi khởi động"
echo ""
echo "⚠️ Script cần quyền sudo để:"
echo "   • Cài đặt packages và cập nhật hệ thống"
echo "   • Cấu hình network forwarding"
echo "   • Quản lý Docker service"
echo "   • Cấu hình firewall"
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
  # Use different DNS resolution methods based on available tools
  if command -v getent >/dev/null 2>&1; then
    DOMAIN_IP=$(getent ahosts "$WG_HOST" | awk '/STREAM/ {print $1; exit}')
  elif command -v nslookup >/dev/null 2>&1; then
    DOMAIN_IP=$(nslookup "$WG_HOST" | awk '/^Address: / { print $2; exit }')
  elif command -v dig >/dev/null 2>&1; then
    DOMAIN_IP=$(dig +short "$WG_HOST" | tail -n1)
  else
    echo "⚠️ Không tìm thấy công cụ DNS resolution. Bỏ qua kiểm tra domain."
    break
  fi
  
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
update_system

# --- Install base packages smartly ---
echo "🔍 Kiểm tra và cài đặt base packages..."

# Check individual packages and install only if needed
case $DISTRO_FAMILY in
  debian)
    # Check ca-certificates
    if ! dpkg -l | grep -q "ca-certificates"; then
      echo "📦 Cài đặt ca-certificates..."
      $SUDO_CMD apt install -y ca-certificates
    else
      echo "✅ ca-certificates đã có sẵn"
    fi
    ;;
  rhel|fedora|opensuse)
    # Check ca-certificates on RPM systems
    if ! rpm -q ca-certificates >/dev/null 2>&1; then
      echo "📦 Cài đặt ca-certificates..."
      install_packages ca-certificates
    else
      echo "✅ ca-certificates đã có sẵn"
    fi
    ;;
esac

check_required_tools

# --- Enable IPv4/IPv6 forwarding ---
$SUDO_CMD tee /etc/sysctl.d/99-wireguard.conf > /dev/null <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
$SUDO_CMD sysctl --system

# --- Install Docker ---
install_docker() {
  case $DISTRO_FAMILY in
    debian)
      echo "📦 Cài đặt Docker cho $DISTRO_FAMILY..."
      # Remove old versions
      $SUDO_CMD apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
      
      # Add Docker GPG key and repository
      curl -fsSL https://download.docker.com/linux/$DISTRO_ID/gpg | $SUDO_CMD gpg --dearmor -o /usr/share/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/$DISTRO_ID $(lsb_release -cs) stable" \
| $SUDO_CMD tee /etc/apt/sources.list.d/docker.list
      $SUDO_CMD apt update
      install_packages $(get_package_names "docker")
      ;;
      
    rhel)
      echo "� Cài đặt Docker cho RHEL/CentOS..."
      # Remove old versions
      $PKG_MANAGER remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
      
      # Install yum-utils and add Docker repository
      install_packages yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      install_packages $(get_package_names "docker")
      ;;
      
    fedora)
      echo "📦 Cài đặt Docker cho Fedora..."
      # Remove old versions
      $SUDO_CMD dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine 2>/dev/null || true
      
      # Install dnf-plugins-core and add Docker repository
      install_packages dnf-plugins-core
      $SUDO_CMD dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      install_packages $(get_package_names "docker")
      ;;
      
    arch)
      echo "📦 Cài đặt Docker cho Arch Linux..."
      install_packages docker docker-compose
      ;;
      
    opensuse)
      echo "📦 Cài đặt Docker cho openSUSE..."
      $SUDO_CMD zypper addrepo https://download.docker.com/linux/sles/docker-ce.repo
      $SUDO_CMD zypper refresh
      install_packages docker-ce docker-ce-cli containerd.io
      ;;
      
    *)
      echo "❌ Không hỗ trợ cài đặt Docker tự động cho distro này"
      echo "Vui lòng cài đặt Docker thủ công từ: https://docs.docker.com/engine/install/"
      exit 1
      ;;
  esac
}

if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; then
  echo "✅ Docker đã được cài đặt: $(docker --version)"
  
  # Kiểm tra Docker đang chạy
  if ! $SUDO_CMD systemctl is-active --quiet docker; then
    echo "🔄 Khởi động Docker service..."
    $SUDO_CMD systemctl enable docker
    $SUDO_CMD systemctl start docker
  else
    echo "✅ Docker service đang chạy"
  fi
else
  install_docker
  $SUDO_CMD systemctl enable docker
  $SUDO_CMD systemctl start docker
  echo "✅ Docker đã được cài đặt thành công"
fi

# --- Install Docker Compose ---
install_docker_compose() {
  case $DISTRO_FAMILY in
    arch)
      # Arch Linux đã có docker-compose trong package docker
      echo "✅ Docker Compose đã được cài cùng Docker trên Arch Linux"
      ;;
    *)
      # Cài đặt Docker Compose từ GitHub releases cho các distro khác
      echo "📦 Cài đặt Docker Compose..."
      $SUDO_CMD curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
      $SUDO_CMD chmod +x /usr/local/bin/docker-compose
      
      # Tạo symlink cho một số distro
      if [ ! -f /usr/bin/docker-compose ]; then
        $SUDO_CMD ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
      fi
      ;;
  esac
}

if command -v docker-compose >/dev/null 2>&1 && docker-compose --version >/dev/null 2>&1; then
  echo "✅ Docker Compose đã được cài đặt: $(docker-compose --version)"
else
  install_docker_compose
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

# --- Firewall config (UFW/firewalld/iptables) ---
configure_firewall() {
  echo "🔒 Đang cấu hình firewall..."
  
  # Detect firewall type
  if command -v ufw >/dev/null 2>&1; then
    FIREWALL_TYPE="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    FIREWALL_TYPE="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    FIREWALL_TYPE="iptables"
  else
    FIREWALL_TYPE="none"
  fi
  
  echo "🔍 Phát hiện firewall: $FIREWALL_TYPE"
  
  case $FIREWALL_TYPE in
    ufw)
      UFW_STATUS=$($SUDO_CMD ufw status | head -n1 | awk '{print $2}')
      if [ "$UFW_STATUS" = "inactive" ]; then
        echo "⚠️ UFW đang inactive (tất cả port đều mở). Bỏ qua bước mở firewall."
      else
        echo "🔒 Đang kiểm tra UFW firewall..."
        
        # Mở port 51820/udp cho WireGuard
        if ! $SUDO_CMD ufw status | grep -q "51820/udp"; then
          echo "⚡ Mở port 51820/udp cho WireGuard"
          $SUDO_CMD ufw allow 51820/udp
        else
          echo "✅ Port 51820/udp đã mở"
        fi
        
        # Mở port 80/tcp cho HTTP (Let's Encrypt)
        if ! $SUDO_CMD ufw status | grep -q "80/tcp"; then
          echo "⚡ Mở port 80/tcp (HTTP)"
          $SUDO_CMD ufw allow 80/tcp
        else
          echo "✅ Port 80/tcp đã mở"
        fi
        
        # Mở port 443/tcp cho HTTPS
        if ! $SUDO_CMD ufw status | grep -q "443/tcp"; then
          echo "⚡ Mở port 443/tcp (HTTPS)"
          $SUDO_CMD ufw allow 443/tcp
        else
          echo "✅ Port 443/tcp đã mở"
        fi
      fi
      ;;
      
    firewalld)
      if $SUDO_CMD systemctl is-active --quiet firewalld; then
        echo "🔒 Cấu hình firewalld..."
        
        # Mở port 51820/udp cho WireGuard
        if ! $SUDO_CMD firewall-cmd --list-ports | grep -q "51820/udp"; then
          echo "⚡ Mở port 51820/udp cho WireGuard"
          $SUDO_CMD firewall-cmd --permanent --add-port=51820/udp
        else
          echo "✅ Port 51820/udp đã mở"
        fi
        
        # Mở port 80/tcp cho HTTP
        if ! $SUDO_CMD firewall-cmd --list-services | grep -q "http"; then
          echo "⚡ Mở HTTP service"
          $SUDO_CMD firewall-cmd --permanent --add-service=http
        else
          echo "✅ HTTP service đã mở"
        fi
        
        # Mở port 443/tcp cho HTTPS
        if ! $SUDO_CMD firewall-cmd --list-services | grep -q "https"; then
          echo "⚡ Mở HTTPS service"
          $SUDO_CMD firewall-cmd --permanent --add-service=https
        else
          echo "✅ HTTPS service đã mở"
        fi
        
        # Reload firewall rules
        $SUDO_CMD firewall-cmd --reload
        echo "✅ Firewalld rules đã được reload"
      else
        echo "⚠️ firewalld không đang chạy. Bỏ qua cấu hình firewall."
      fi
      ;;
      
    iptables)
      echo "🔒 Cấu hình iptables..."
      
      # Check if iptables rules already exist
      if ! $SUDO_CMD iptables -C INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null; then
        echo "⚡ Mở port 51820/udp cho WireGuard"
        $SUDO_CMD iptables -I INPUT -p udp --dport 51820 -j ACCEPT
      else
        echo "✅ Port 51820/udp đã mở"
      fi
      
      if ! $SUDO_CMD iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        echo "⚡ Mở port 80/tcp (HTTP)"
        $SUDO_CMD iptables -I INPUT -p tcp --dport 80 -j ACCEPT
      else
        echo "✅ Port 80/tcp đã mở"
      fi
      
      if ! $SUDO_CMD iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
        echo "⚡ Mở port 443/tcp (HTTPS)"
        $SUDO_CMD iptables -I INPUT -p tcp --dport 443 -j ACCEPT
      else
        echo "✅ Port 443/tcp đã mở"
      fi
      
      # Save iptables rules (different methods for different distros)
      case $DISTRO_FAMILY in
        debian)
          if command -v iptables-save >/dev/null 2>&1; then
            $SUDO_CMD iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            $SUDO_CMD iptables-save > /etc/iptables.rules 2>/dev/null || \
            echo "⚠️ Không thể lưu iptables rules tự động"
          fi
          ;;
        rhel|fedora)
          if command -v iptables-save >/dev/null 2>&1; then
            $SUDO_CMD iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
            echo "⚠️ Không thể lưu iptables rules tự động"
          fi
          ;;
        *)
          echo "⚠️ Lưu iptables rules thủ công: iptables-save > /path/to/rules"
          ;;
      esac
      ;;
      
    none)
      echo "⚠️ Không phát hiện firewall. Đảm bảo ports 51820/udp, 80/tcp, 443/tcp đã mở."
      ;;
  esac
}

configure_firewall

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
    
    # Check if NPM API is responding (400 = server ready but bad request, which is expected)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 http://127.0.0.1:81/api/tokens 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "200" ]; then
      echo "✅ NPM API đã sẵn sàng! (HTTP: $HTTP_CODE)"
      
      # Try to get token
      RESPONSE=$(curl -s -X POST http://127.0.0.1:81/api/tokens \
        -H 'Content-Type: application/json' \
        -d '{"identity":"admin@example.com","secret":"changeme"}' \
        --connect-timeout 10 --max-time 15 2>/dev/null || echo '{"error":"curl_failed"}')
      
      TOKEN=$(echo "$RESPONSE" | jq -r .token 2>/dev/null || echo "null")
      
      if [ "$TOKEN" != "null" ] && [ ! -z "$TOKEN" ] && [ "$TOKEN" != "" ]; then
        echo "🔑 Đã lấy được token thành công!"
        break
      else
        echo "⚠️ API phản hồi nhưng không lấy được token. Response: $RESPONSE"
      fi
    else
      echo "⏳ NPM API chưa sẵn sàng (HTTP: $HTTP_CODE), đợi 15 giây..."
    fi
    
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      sleep 15
    fi
  done

  if [ "$TOKEN" != "null" ] && [ ! -z "$TOKEN" ] && [ "$TOKEN" != "" ]; then
    echo "🔑 Token hợp lệ: ${TOKEN:0:20}..."
    
    # Update admin user info (không bao gồm password)
    echo "👤 Cập nhật thông tin admin..."
    UPDATE_RESPONSE=$(curl -s -X PUT http://127.0.0.1:81/api/users/1 \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"email":"'"$ADMIN_EMAIL"'","name":"Administrator","nickname":"Admin","roles":["admin"],"is_disabled":false}' \
      --connect-timeout 10 --max-time 15 2>/dev/null || echo '{"error":"curl_failed"}')

    echo "📝 Update user info response: $UPDATE_RESPONSE"
    
    # Đổi password riêng biệt
    echo "🔐 Đổi mật khẩu admin..."
    PASSWORD_RESPONSE=$(curl -s -X PUT http://127.0.0.1:81/api/users/1/auth \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"type":"password","current":"changeme","secret":"'"$ADMIN_PASS"'"}' \
      --connect-timeout 10 --max-time 15 2>/dev/null || echo 'false')
    
    echo "🔍 Password change response: $PASSWORD_RESPONSE"
    
    if [ "$PASSWORD_RESPONSE" = "true" ]; then
      echo "✅ Đổi mật khẩu thành công!"
    else
      echo "⚠️ Không thể đổi mật khẩu. Response: $PASSWORD_RESPONSE"
      echo "🔧 Có thể mật khẩu hiện tại không phải 'changeme' hoặc API có thay đổi"
      echo "📋 NPM Admin sẽ sử dụng credentials mặc định: admin@example.com / changeme"
    fi

    # Tạo proxy host cho WG-Easy với SSL certificate tự động và force SSL
    echo "🔗 Tạo proxy host cho WG-Easy (bao gồm SSL certificate + force HTTPS)..."
    PROXY_RESPONSE=$(curl -s -X POST http://127.0.0.1:81/api/nginx/proxy-hosts \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{
        "domain_names":["'"$WG_HOST"'"],
        "forward_scheme":"http",
        "forward_host":"wg-easy",
        "forward_port":51821,
        "access_list_id":"0",
        "certificate_id":"new",
        "ssl_forced":true,
        "caching_enabled":true,
        "allow_websocket_upgrade":true,
        "block_exploits":false,
        "http2_support":true,
        "hsts_enabled":true,
        "hsts_subdomains":false,
        "meta":{
          "letsencrypt_email":"'"$ADMIN_EMAIL"'",
          "letsencrypt_agree":true,
          "dns_challenge":false
        },
        "advanced_config":"",
        "locations":[]
      }' \
      --connect-timeout 15 --max-time 60 2>/dev/null || echo '{"error":"curl_failed"}')
    
    echo "🌐 Proxy host response: $PROXY_RESPONSE"
    
    PROXY_ID=$(echo "$PROXY_RESPONSE" | jq -r .id 2>/dev/null || echo "null")
    if [ "$PROXY_ID" != "null" ] && [ ! -z "$PROXY_ID" ]; then
      echo "✅ Đã tạo proxy host, SSL certificate và force HTTPS thành công (ID: $PROXY_ID)"
      echo "🎉 WG-Easy đã sẵn sàng truy cập qua HTTPS!"
    else
      echo "⚠️ Có thể có lỗi khi tạo proxy host, kiểm tra logs NPM"
      echo "📝 Response: $PROXY_RESPONSE"
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
echo ""
echo "📋 THÔNG TIN TRUY CẬP:"
echo "WG-Easy VPN Panel: https://${WG_HOST}"
echo "WG-Easy Username: admin"
if [ "$AUTO_WG_PASS" = true ]; then
  echo "WG-Easy Password: $WG_PASSWORD"
else
  echo "WG-Easy Password: (bạn đã nhập)"
fi
echo "VPN UDP Port: 51820"
echo ""
if [ "$MODE" -eq 2 ]; then
  echo "NPM Dashboard: http://$(curl -s https://api.ipify.org):81"
  if [ "$PASSWORD_RESPONSE" = "true" ]; then
    echo "NPM Email: $ADMIN_EMAIL"
    if [ "$AUTO_NPM_PASS" = true ]; then
      echo "NPM Password: $ADMIN_PASS"
    else
      echo "NPM Password: (bạn đã nhập)"
    fi
  else
    echo "NPM Email: admin@example.com"
    echo "NPM Password: changeme (mặc định - cần đổi thủ công)"
  fi
  echo ""
fi
echo "🔧 HƯỚNG DẪN:"
echo "1. Truy cập WG-Easy panel để tạo VPN clients"
echo "2. Tải file config hoặc quét QR code để kết nối VPN"
if [ "$MODE" -eq 2 ]; then
  echo "3. Sử dụng NPM dashboard để quản lý reverse proxy"
  echo "4. SSL certificate sẽ tự động gia hạn"
fi
echo "========================================"
