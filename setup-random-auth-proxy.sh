#!/bin/bash
# Tự động tạo nhiều proxy IPv4 (client kết nối) -> IPv6 (outbound traffic) với random password
# Author: ChatGPT

### === Cấu hình người dùng ===
PROXY_COUNT=1000                   # Số lượng proxy muốn tạo
PREFIX="auto"                     # Prefix IPv6 không bao gồm đằng sau dấu :: (để "auto" để tự detect)
START_HEX=92                      # Hex bắt đầu (ví dụ từ ::5c = 92) - chỉ dùng khi USE_RANDOM_IPV6=false
USE_RANDOM_IPV6=true             # Set true để tạo IPv6 random (4 nhóm sau ::), false để tăng dần từ START_HEX
GATEWAY="auto"                    # Gateway IPv6 của server (để "auto" để tự detect)
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
PORT_START=60000                   # Port đầu tiên
PROXY_USER="user"            # Username chung
WORKDIR="$HOME/3proxy-docker"
RESULT_FILE="$WORKDIR/proxy_result.txt"
IPV6_LIST_FILE="$WORKDIR/ipv6_list.txt"
USE_EXISTING_CREDENTIALS=true     # Set true để sử dụng username/password cũ từ proxy_result.txt

# Telegram configuration (optional)
TELEGRAM_BOT_TOKEN=""             # Bot token từ @BotFather (để trống để tắt)
TELEGRAM_CHAT_ID=""               # Chat ID để gửi file (để trống để tắt)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

### === Validation và Cleanup Functions ===
load_existing_credentials() {
    echo "🔑 Tải thông tin xác thực cũ từ file..."
    
    declare -A -g OLD_CREDENTIALS
    
    if [[ ! -f "$RESULT_FILE" ]]; then
        echo "⚠️ File $RESULT_FILE không tồn tại, sẽ tạo mới credentials"
        return 1
    fi
    
    local line_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Format: user:pass@ip:port
        if [[ $line =~ ^([^:]+):([^@]+)@([^:]+):([0-9]+)$ ]]; then
            local user="${BASH_REMATCH[1]}"
            local pass="${BASH_REMATCH[2]}"
            local port="${BASH_REMATCH[4]}"
            
            OLD_CREDENTIALS["$port"]="$user:$pass"
            ((line_count++))
        fi
    done < "$RESULT_FILE"
    
    if [[ $line_count -eq 0 ]]; then
        echo "⚠️ Không tìm thấy credentials hợp lệ trong file cũ"
        return 1
    fi
    
    echo "✅ Đã tải $line_count credentials từ file cũ"
    return 0
}

cleanup_docker() {
    echo "🧹 Dọn dẹp Docker containers và images cũ..."
    
    # Stop và remove container cũ
    if docker ps -q -f name=ipv4-to-ipv6-proxy | grep -q .; then
        echo "  📦 Stopping existing container..."
        docker stop ipv4-to-ipv6-proxy || true
    fi
    
    if docker ps -aq -f name=ipv4-to-ipv6-proxy | grep -q .; then
        echo "  🗑️ Removing existing container..."
        docker rm ipv4-to-ipv6-proxy || true
    fi
    
    # Remove image cũ nếu có
    if docker images -q 3proxy-docker-proxy 2>/dev/null | grep -q .; then
        echo "  🖼️ Removing old image..."
        docker rmi 3proxy-docker-proxy || true
    fi
}

check_dependencies() {
    echo "🔍 Kiểm tra dependencies..."
    
    local missing_deps=()
    
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi
    
    if ! command -v openssl &> /dev/null; then
        missing_deps+=("openssl")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "❌ Thiếu dependencies: ${missing_deps[*]}"
        
        # Auto-install missing dependencies
        echo "� Đang tự động cài đặt dependencies..."
        
        # Update package list
        echo "📥 Updating package list..."
        sudo apt update
        
        # Install each missing dependency
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                "docker")
                    echo "🐳 Cài đặt Docker..."
                    # Install Docker using the official method
                    sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
                    
                    # Detect distribution for correct repository
                    if [[ -f /etc/os-release ]]; then
                        . /etc/os-release
                        DISTRO_ID=${ID}
                    else
                        echo "⚠️ Không thể detect distro, sử dụng ubuntu làm fallback"
                        DISTRO_ID="ubuntu"
                    fi
                    
                    # Set correct repository URL based on distro
                    case "$DISTRO_ID" in
                        ubuntu)
                            DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
                            ;;
                        debian)
                            DOCKER_REPO_URL="https://download.docker.com/linux/debian"
                            ;;
                        *)
                            echo "⚠️ Distro $DISTRO_ID có thể không được hỗ trợ chính thức, sử dụng ubuntu repo"
                            DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
                            ;;
                    esac
                    
                    echo "📍 Sử dụng Docker repository cho: $DISTRO_ID"
                    
                    # Add Docker's official GPG key (if not exists)
                    if [[ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]]; then
                        curl -fsSL "${DOCKER_REPO_URL}/gpg" | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
                    fi
                    
                    # Add Docker repository (if not exists)
                    if ! grep -q "download.docker.com" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
                        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${DOCKER_REPO_URL} $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                    fi
                    
                    # Update and install Docker
                    sudo apt update
                    if sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
                        echo "  ✅ Docker đã được cài đặt"
                        
                        # Start and enable Docker
                        sudo systemctl start docker
                        sudo systemctl enable docker
                        
                        # Add current user to docker group
                        sudo usermod -aG docker $USER
                        echo "  ✅ Đã thêm user vào group docker"
                        echo "  ⚠️ Bạn có thể cần logout/login lại để quyền docker có hiệu lực"
                    else
                        echo "  ❌ Cài đặt Docker thất bại, thử fallback method..."
                        # Fallback to docker.io
                        if sudo apt install -y docker.io docker-compose; then
                            echo "  ✅ Docker (docker.io) đã được cài đặt"
                            sudo systemctl start docker
                            sudo systemctl enable docker
                            sudo usermod -aG docker $USER
                        else
                            echo "  ❌ Không thể cài đặt Docker"
                            exit 1
                        fi
                    fi
                    ;;
                "openssl")
                    echo "🔐 Cài đặt OpenSSL..."
                    sudo apt install -y openssl
                    ;;
                "curl")
                    echo "🌐 Cài đặt cURL..."
                    sudo apt install -y curl
                    ;;
            esac
        done
        
        echo "✅ Đã cài đặt tất cả dependencies"
    fi
    
    # Kiểm tra Docker daemon
    if ! docker info &>/dev/null; then
        echo "🔄 Khởi động Docker daemon..."
        sudo systemctl start docker
        
        # Wait a bit for Docker to start
        sleep 3
        
        if ! docker info &>/dev/null; then
            echo "❌ Docker daemon không chạy hoặc user không có quyền"
            echo "📋 Thử chạy lại script sau khi logout/login để quyền docker có hiệu lực"
            echo "📋 Hoặc chạy: newgrp docker"
            exit 1
        fi
    fi
    
    echo "✅ Dependencies OK"
}

validate_config() {
    echo "🔧 Kiểm tra cấu hình..."
    
    # Cài đặt và migrate to Netplan nếu cần
    echo "🔍 Kiểm tra Netplan..."
    if ! command -v netplan &>/dev/null || [[ ! -d "/etc/netplan" ]]; then
        echo "  📦 Netplan chưa được cài đặt"
        if ! install_netplan; then
            echo "❌ Không thể cài đặt Netplan"
            exit 1
        fi
    fi
    
    # Kiểm tra và migrate từ ifupdown nếu cần
    if [[ -f "/etc/network/interfaces" ]] && grep -q -E "^(auto|iface)" "/etc/network/interfaces" 2>/dev/null; then
        # Kiểm tra xem có config netplan chưa
        local has_netplan_config=false
        if [[ -d "/etc/netplan" ]]; then
            local netplan_files=($(find /etc/netplan -name "*.yaml" -o -name "*.yml" 2>/dev/null))
            for file in "${netplan_files[@]}"; do
                if [[ -f "$file" ]] && grep -q "ethernets:" "$file" 2>/dev/null; then
                    has_netplan_config=true
                    NETPLAN_FILE="$file"
                    break
                fi
            done
        fi
        
        if [[ "$has_netplan_config" == "false" ]]; then
            echo "  🔄 Phát hiện cấu hình ifupdown, đang migrate sang Netplan..."
            if ! migrate_ifupdown_to_netplan; then
                echo "❌ Migration thất bại"
                exit 1
            fi
        else
            echo "  ✅ Netplan config đã tồn tại: $NETPLAN_FILE"
        fi
    else
        echo "  ✅ Sẵn sàng sử dụng Netplan"
    fi
    
    # Chạy auto detection nếu cần
    if [[ "$PREFIX" == "auto" || "$GATEWAY" == "auto" ]]; then
        if ! auto_detect_ipv6_config; then
            exit 1
        fi
    fi
    
    if [[ -z "$PREFIX" || "$PREFIX" == "auto" ]]; then
        echo "❌ PREFIX không được để trống hoặc auto-detect thất bại"
        echo "💡 Đặt PREFIX thủ công, ví dụ: PREFIX=\"2001:db8\""
        exit 1
    fi
    
    if [[ -z "$GATEWAY" || "$GATEWAY" == "auto" ]]; then
        echo "❌ GATEWAY không được để trống hoặc auto-detect thất bại"
        echo "💡 Đặt GATEWAY thủ công, ví dụ: GATEWAY=\"fe80::1\""
        exit 1
    fi
    
    if [[ $PROXY_COUNT -lt 1 || $PROXY_COUNT -gt 1000 ]]; then
        echo "❌ PROXY_COUNT phải từ 1-1000"
        exit 1
    fi
    
    echo "✅ Config OK"
    echo "  📝 PREFIX: $PREFIX"
    echo "  🚪 GATEWAY: $GATEWAY"
}

upload_to_telegram() {
    echo "📱 Kiểm tra cấu hình Telegram..."
    
    # Kiểm tra xem có cấu hình Telegram không
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        echo "ℹ️ Telegram không được cấu hình, bỏ qua upload"
        return 0
    fi
    
    if [[ ! -f "$RESULT_FILE" ]]; then
        echo "❌ File proxy result không tồn tại: $RESULT_FILE"
        return 1
    fi
    
    if [[ ! -f "$IPV6_LIST_FILE" ]]; then
        echo "❌ File IPv6 list không tồn tại: $IPV6_LIST_FILE"
        return 1
    fi
    
    echo "📤 Đang upload files tới Telegram..."
    
    # Tạo caption với thông tin
    local caption="🎯 Proxy Setup Complete!
📊 Proxies: $PROXY_COUNT
🌐 Port range: ${PORT_START}-$((PORT_START + PROXY_COUNT - 1))
🕐 Time: $(date '+%Y-%m-%d %H:%M:%S')
🖥️ Server: $(hostname)
📋 IPv6 Mode: $(if [[ "$USE_RANDOM_IPV6" == "true" ]]; then echo "Random"; else echo "Sequential"; fi)"
    
    # Upload file proxy result
    echo "  📄 Uploading proxy result file..."
    local response1=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${RESULT_FILE}" \
        -F "caption=${caption}")
    
    local success_count=0
    if echo "$response1" | grep -q '"ok":true'; then
        echo "  ✅ Proxy result file uploaded successfully"
        ((success_count++))
    else
        echo "  ❌ Proxy result file upload failed:"
        echo "$response1" | grep -o '"description":"[^"]*"' || echo "Unknown error"
    fi
    
    # Upload file IPv6 list
    echo "  📄 Uploading IPv6 list file..."
    local ipv6_caption="🌍 IPv6 Addresses List
📊 Count: ${#IP_LIST[@]} addresses
🎯 Prefix: $PREFIX
🕐 Generated: $(date '+%Y-%m-%d %H:%M:%S')
🖥️ Server: $(hostname)"
    
    local response2=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${IPV6_LIST_FILE}" \
        -F "caption=${ipv6_caption}")
    
    if echo "$response2" | grep -q '"ok":true'; then
        echo "  ✅ IPv6 list file uploaded successfully"
        ((success_count++))
    else
        echo "  ❌ IPv6 list file upload failed:"
        echo "$response2" | grep -o '"description":"[^"]*"' || echo "Unknown error"
    fi
    
    # Tổng kết
    if [[ $success_count -eq 2 ]]; then
        echo "✅ Tất cả files đã được upload thành công tới Telegram (2/2)"
        return 0
    elif [[ $success_count -eq 1 ]]; then
        echo "⚠️ Chỉ upload được 1/2 files tới Telegram"
        return 1
    else
        echo "❌ Không thể upload files nào tới Telegram"
        return 1
    fi
}

generate_random_ipv6_suffix() {
    # Tạo 4 nhóm hex random (mỗi nhóm 4 ký tự hex đầy đủ)
    # Format: xxxx:xxxx:xxxx:xxxx (không dùng :: vì PREFIX đã có ::)
    local group1=$(printf "%04x" $((RANDOM % 65536)))  # 0000-ffff
    local group2=$(printf "%04x" $((RANDOM % 65536)))  # 0000-ffff  
    local group3=$(printf "%04x" $((RANDOM % 65536)))  # 0000-ffff
    local group4=$(printf "%04x" $((RANDOM % 65536)))  # 0000-ffff
    
    echo "${group1}:${group2}:${group3}:${group4}"
}

auto_detect_ipv6_config() {
    echo "🔍 Auto-detecting IPv6 configuration..."
    
    # Detect IPv6 prefix từ interface đầu tiên có IPv6
    local detected_prefix=""
    local detected_gateway=""
    
    # Lấy IPv6 addresses từ interface (loại bỏ loopback và link-local)
    local ipv6_addrs=$(ip -6 addr show | grep 'inet6' | grep -v 'scope link' | grep -v '::1' | head -10)
    
    if [[ -n "$ipv6_addrs" ]]; then
        # Tìm địa chỉ IPv6 global đầu tiên
        local global_ipv6=$(echo "$ipv6_addrs" | grep 'scope global' | head -1 | awk '{print $2}' | cut -d'/' -f1)
        
        if [[ -n "$global_ipv6" ]]; then
            # Lấy prefix từ địa chỉ IPv6 (lấy phần trước :: cuối cùng)
            if [[ "$global_ipv6" =~ ^([0-9a-f:]+)::[0-9a-f:]*$ ]]; then
                detected_prefix="${BASH_REMATCH[1]}"
                echo "  📡 Detected IPv6 global address: $global_ipv6"
                echo "  🎯 Extracted prefix: $detected_prefix"
            else
                # Fallback: lấy 4 nhóm đầu của IPv6
                detected_prefix=$(echo "$global_ipv6" | cut -d':' -f1-4)
                echo "  📡 Detected IPv6 address: $global_ipv6"
                echo "  🎯 Extracted prefix (first 4 groups): $detected_prefix"
            fi
        fi
    fi
    
    # Detect gateway IPv6
    local gateway_output=$(ip -6 route show default 2>/dev/null | head -1)
    if [[ -n "$gateway_output" ]]; then
        detected_gateway=$(echo "$gateway_output" | awk '{print $3}')
        echo "  🚪 Detected IPv6 gateway: $detected_gateway"
    fi
    
    # Fallback methods nếu không detect được
    if [[ -z "$detected_prefix" ]]; then
        echo "  ⚠️ Không thể auto-detect IPv6 prefix từ interface"
        echo "  🔍 Thử phương pháp khác..."
        
        # Thử đọc từ interfaces file trước
        if [[ -f "/etc/network/interfaces" ]]; then
            local interfaces_ipv6=$(grep -E "up[[:space:]]+ip[[:space:]]+addr[[:space:]]+add[[:space:]]+.*::" "/etc/network/interfaces" | head -1 | awk '{print $5}')
            if [[ -n "$interfaces_ipv6" ]]; then
                # Lấy prefix từ địa chỉ IPv6 trong interfaces file
                if [[ "$interfaces_ipv6" =~ ^([0-9a-f:]+)::[0-9a-f:]*/.*$ ]]; then
                    detected_prefix="${BASH_REMATCH[1]}"
                    echo "  📄 Found prefix in interfaces: $detected_prefix"
                else
                    # Fallback: lấy 4 nhóm đầu
                    detected_prefix=$(echo "$interfaces_ipv6" | cut -d':' -f1-4)
                    echo "  📄 Extracted prefix from interfaces: $detected_prefix"
                fi
            fi
        fi
        
        # Thử từ /proc/net/if_inet6 nếu vẫn chưa có
        if [[ -z "$detected_prefix" ]]; then
            local proc_ipv6=$(cat /proc/net/if_inet6 2>/dev/null | grep -v '^00000000000000000000000000000001' | head -1)
            if [[ -n "$proc_ipv6" ]]; then
                # Parse IPv6 từ /proc format
                local hex_addr=$(echo "$proc_ipv6" | awk '{print $1}')
                # Chuyển đổi hex thành IPv6 format và lấy prefix
                local formatted_ipv6=$(echo "$hex_addr" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2:\3\4:\5\6:\7\8:\9a:\11\12:\13\14:\15\16/')
                detected_prefix=$(echo "$formatted_ipv6" | cut -d':' -f1-4)
                echo "  📝 Fallback prefix from /proc: $detected_prefix"
            fi
        fi
    fi
    
    if [[ -z "$detected_gateway" ]]; then
        echo "  ⚠️ Không thể auto-detect IPv6 gateway"
        echo "  💡 Thử tìm từ Netplan hoặc interfaces file..."
        
        # Thử tìm gateway từ netplan
        if [[ -f "$NETPLAN_FILE" ]]; then
            local netplan_gw=$(grep -A 10 "gateway6\|routes:" "$NETPLAN_FILE" 2>/dev/null | grep -E "gateway6|via:" | awk '{print $2}' | head -1)
            if [[ -n "$netplan_gw" ]]; then
                detected_gateway="$netplan_gw"
                echo "  📄 Found gateway in Netplan: $detected_gateway"
            fi
        fi
        
        # Thử tìm từ interfaces file nếu vẫn chưa có
        if [[ -z "$detected_gateway" && -f "/etc/network/interfaces" ]]; then
            local interfaces_gw=$(grep -E "^[[:space:]]*gateway[[:space:]]+" "/etc/network/interfaces" | awk '{print $2}' | head -1)
            if [[ -n "$interfaces_gw" ]]; then
                detected_gateway="$interfaces_gw"
                echo "  📄 Found gateway in interfaces: $detected_gateway"
            fi
        fi
    fi
    
    # Cập nhật biến global nếu detect thành công
    if [[ "$PREFIX" == "auto" ]]; then
        if [[ -n "$detected_prefix" ]]; then
            PREFIX="$detected_prefix"
            echo "  ✅ Auto-set PREFIX = $PREFIX"
        else
            echo "  ❌ Không thể auto-detect PREFIX, vui lòng đặt thủ công"
            return 1
        fi
    fi
    
    if [[ "$GATEWAY" == "auto" ]]; then
        if [[ -n "$detected_gateway" ]]; then
            GATEWAY="$detected_gateway"
            echo "  ✅ Auto-set GATEWAY = $GATEWAY"
        else
            echo "  ❌ Không thể auto-detect GATEWAY, vui lòng đặt thủ công"
            return 1
        fi
    fi
    
    return 0
}

install_netplan() {
    echo "📦 Cài đặt Netplan..."
    
    # Kiểm tra xem netplan đã có chưa
    if command -v netplan &>/dev/null && [[ -d "/etc/netplan" ]]; then
        echo "  ✅ Netplan đã được cài đặt"
        return 0
    fi
    
    # Cài đặt netplan
    echo "  📥 Đang cài đặt netplan.io..."
    if sudo apt update && sudo apt install -y netplan.io; then
        echo "  ✅ Netplan đã được cài đặt thành công"
        
        # Tạo thư mục netplan nếu chưa có
        sudo mkdir -p /etc/netplan
        
        return 0
    else
        echo "  ❌ Không thể cài đặt Netplan"
        return 1
    fi
}

migrate_ifupdown_to_netplan() {
    echo "🔄 Migrate cấu hình từ ifupdown sang Netplan..."
    
    local interfaces_file="/etc/network/interfaces"
    local netplan_file="/etc/netplan/01-netcfg.yaml"
    
    if [[ ! -f "$interfaces_file" ]]; then
        echo "  ℹ️ Không tìm thấy file interfaces, bỏ qua migration"
        return 0
    fi
    
    # Đọc cấu hình từ interfaces file
    echo "  📖 Đọc cấu hình từ $interfaces_file..."
    
    local main_interface=""
    local ipv4_config=""
    local ipv6_configs=()
    local gateway_ipv4=""
    local gateway_ipv6=""
    local dns_servers=()
    
    # Parse interfaces file
    while IFS= read -r line; do
        # Interface chính
        if [[ $line =~ ^iface[[:space:]]+([^[:space:]]+)[[:space:]]+inet[[:space:]]+static ]]; then
            main_interface="${BASH_REMATCH[1]}"
            if [[ "$main_interface" != "lo" ]]; then
                echo "    🔌 Tìm thấy interface: $main_interface"
            fi
        fi
        
        # IPv4 address
        if [[ $line =~ ^[[:space:]]*address[[:space:]]+([0-9.]+) ]]; then
            ipv4_config="${BASH_REMATCH[1]}"
            echo "    🌐 IPv4: $ipv4_config"
        fi
        
        # IPv4 netmask
        if [[ $line =~ ^[[:space:]]*netmask[[:space:]]+([0-9.]+) ]]; then
            local netmask="${BASH_REMATCH[1]}"
            # Convert netmask to CIDR
            local cidr=$(echo "$netmask" | awk -F. '{
                split($0, a, ".")
                cidr = 0
                for (i in a) {
                    mask = a[i]
                    while (mask > 0) {
                        if (mask % 2 == 1) cidr++
                        mask = int(mask/2)
                    }
                }
                print cidr
            }')
            if [[ -n "$ipv4_config" ]]; then
                ipv4_config="${ipv4_config}/${cidr}"
                echo "    📏 CIDR: /$cidr"
            fi
        fi
        
        # Gateway
        if [[ $line =~ ^[[:space:]]*gateway[[:space:]]+([0-9.]+) ]]; then
            gateway_ipv4="${BASH_REMATCH[1]}"
            echo "    🚪 IPv4 Gateway: $gateway_ipv4"
        fi
        
        # IPv6 addresses
        if [[ $line =~ up[[:space:]]+ip[[:space:]]+addr[[:space:]]+add[[:space:]]+([^[:space:]]+) ]]; then
            local ipv6_addr="${BASH_REMATCH[1]}"
            if [[ "$ipv6_addr" =~ :: ]]; then
                ipv6_configs+=("$ipv6_addr")
                echo "    🌍 IPv6: $ipv6_addr"
            fi
        fi
        
        # DNS servers
        if [[ $line =~ ^[[:space:]]*dns-nameservers[[:space:]]+(.+) ]]; then
            IFS=' ' read -ra servers <<< "${BASH_REMATCH[1]}"
            dns_servers=("${servers[@]}")
            echo "    🔍 DNS: ${servers[*]}"
        fi
        
    done < "$interfaces_file"
    
    # Fallback để tìm interface chính nếu không có trong file
    if [[ -z "$main_interface" ]]; then
        main_interface=$(ip route | grep default | awk '{print $5}' | head -1)
        echo "    🔍 Auto-detected interface: $main_interface"
    fi
    
    if [[ -z "$main_interface" ]]; then
        echo "  ❌ Không thể xác định interface chính"
        return 1
    fi
    
    # Tạo Netplan config
    echo "  📝 Tạo Netplan configuration..."
    
    # Backup file netplan hiện có nếu có
    if [[ -f "$netplan_file" ]]; then
        local backup="${netplan_file}.bak.$(date +%s)"
        sudo cp "$netplan_file" "$backup"
        echo "    📦 Backup: $backup"
    fi
    
    # Tạo netplan config
    sudo tee "$netplan_file" >/dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $main_interface:
EOF

    # Thêm IPv4 config nếu có
    if [[ -n "$ipv4_config" ]]; then
        sudo tee -a "$netplan_file" >/dev/null <<EOF
      addresses:
        - $ipv4_config
EOF
    fi
    
    # Thêm IPv6 configs nếu có
    if [[ ${#ipv6_configs[@]} -gt 0 ]]; then
        if [[ -z "$ipv4_config" ]]; then
            sudo tee -a "$netplan_file" >/dev/null <<EOF
      addresses:
EOF
        fi
        for ipv6_addr in "${ipv6_configs[@]}"; do
            sudo tee -a "$netplan_file" >/dev/null <<EOF
        - $ipv6_addr
EOF
        done
    fi
    
    # Thêm gateway nếu có
    if [[ -n "$gateway_ipv4" ]]; then
        sudo tee -a "$netplan_file" >/dev/null <<EOF
      gateway4: $gateway_ipv4
EOF
    fi
    
    # Thêm DNS nếu có, ngược lại dùng default
    if [[ ${#dns_servers[@]} -gt 0 ]]; then
        sudo tee -a "$netplan_file" >/dev/null <<EOF
      nameservers:
        addresses:
EOF
        for dns in "${dns_servers[@]}"; do
            sudo tee -a "$netplan_file" >/dev/null <<EOF
          - $dns
EOF
        done
    else
        sudo tee -a "$netplan_file" >/dev/null <<EOF
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
          - 2606:4700:4700::1111
EOF
    fi
    
    echo "  ✅ Đã tạo Netplan config: $netplan_file"
    
    # Update NETPLAN_FILE variable để script sử dụng file mới
    NETPLAN_FILE="$netplan_file"
    
    # Backup interfaces file
    local interfaces_backup="${interfaces_file}.bak.$(date +%s)"
    sudo cp "$interfaces_file" "$interfaces_backup"
    echo "  📦 Backup interfaces: $interfaces_backup"
    
    return 0
}

### === Main Execution ===
echo "🚀 Bắt đầu setup proxy IPv4->IPv6..."

# Chạy validation và cleanup
check_dependencies
validate_config
cleanup_docker

# Tải credentials cũ nếu được yêu cầu
if [[ "$USE_EXISTING_CREDENTIALS" == "true" ]]; then
    load_existing_credentials || echo "⚠️ Không thể tải credentials cũ, sẽ tạo mới"
fi


mkdir -p "$WORKDIR"

### === 1. Backup và cập nhật Netplan ===
BACKUP="$NETPLAN_FILE.bak.$(date +%s)"
sudo cp "$NETPLAN_FILE" "$BACKUP"
echo "📦 Backup Netplan -> $BACKUP"

# Tạo danh sách địa chỉ
IP_LIST=()
declare -A USED_IPS  # Mảng để track IP đã sử dụng (tránh duplicate khi random)

if [[ "$USE_RANDOM_IPV6" == "true" ]]; then
    echo "🎲 Tạo ${PROXY_COUNT} IPv6 addresses ngẫu nhiên..."
    for ((i=0; i<PROXY_COUNT; i++)); do
        attempts=0
        max_attempts=1000
        
        # Thử tạo IPv6 unique
        while [[ $attempts -lt $max_attempts ]]; do
            suffix=$(generate_random_ipv6_suffix)
            ipv6_addr="$PREFIX:${suffix}/64"
            
            # Kiểm tra đã tồn tại chưa
            if [[ -z "${USED_IPS[$ipv6_addr]:-}" ]]; then
                USED_IPS["$ipv6_addr"]=1
                IP_LIST+=("$ipv6_addr")
                break
            fi
            
            ((attempts++))
        done
        
        if [[ $attempts -eq $max_attempts ]]; then
            echo "⚠️ Không thể tạo IPv6 unique sau $max_attempts lần thử, sử dụng sequential"
            HEX=$(printf "%x" $((START_HEX + i)))
            IP_LIST+=("$PREFIX::${HEX}/64")
        fi
        
        # Progress indicator cho random mode
        if ((i % 50 == 0 && i > 0)); then
            echo "  📊 Đã tạo $i/${PROXY_COUNT} IPv6 addresses..."
        fi
    done
else
    echo "📝 Tạo ${PROXY_COUNT} IPv6 addresses tuần tự từ hex ${START_HEX}..."
    for ((i=0; i<PROXY_COUNT; i++)); do
        HEX=$(printf "%x" $((START_HEX + i)))
        IP_LIST+=("$PREFIX::${HEX}/64")
    done
fi

# Tạo file IPv6 list để backup và upload
echo "📄 Tạo file IPv6 list: $IPV6_LIST_FILE"
> "$IPV6_LIST_FILE"  # Xóa file cũ và tạo mới
{
    echo "# IPv6 Addresses List"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Server: $(hostname)"
    echo "# Prefix: $PREFIX"
    echo "# Count: ${#IP_LIST[@]}"
    echo "# Mode: $(if [[ "$USE_RANDOM_IPV6" == "true" ]]; then echo "Random"; else echo "Sequential from hex $START_HEX"; fi)"
    echo ""
    for ipv6_addr in "${IP_LIST[@]}"; do
        echo "$ipv6_addr"
    done
} > "$IPV6_LIST_FILE"
echo "✅ Đã tạo file IPv6 list với ${#IP_LIST[@]} addresses"

# === Netplan Config Object Management ===
# Parse netplan config file thành object config
parse_netplan_config() {
    local netplan_file="$1"
    
    echo "📖 Parsing netplan config từ: $netplan_file"
    
    if [[ ! -f "$netplan_file" ]]; then
        echo "❌ File netplan không tồn tại: $netplan_file"
        return 1
    fi
    
    # Initialize global associative arrays
    declare -g -A NETPLAN_CONFIG_VERSION
    declare -g -A NETPLAN_CONFIG_RENDERER  
    declare -g -A NETPLAN_CONFIG_ETHERNETS
    declare -g -A NETPLAN_CONFIG_ADDRESSES
    declare -g -A NETPLAN_CONFIG_GATEWAYS
    declare -g -A NETPLAN_CONFIG_NAMESERVERS
    declare -g -A NETPLAN_CONFIG_OTHER_SETTINGS
    declare -g -A NETPLAN_CONFIG_ROUTES
    
    # Clear existing config
    NETPLAN_CONFIG_VERSION=()
    NETPLAN_CONFIG_RENDERER=()
    NETPLAN_CONFIG_ETHERNETS=()
    NETPLAN_CONFIG_ADDRESSES=()
    NETPLAN_CONFIG_GATEWAYS=()
    NETPLAN_CONFIG_NAMESERVERS=()
    NETPLAN_CONFIG_OTHER_SETTINGS=()
    NETPLAN_CONFIG_ROUTES=()
    
    local current_interface=""
    local in_ethernets=false
    local in_addresses=false
    local in_nameservers=false
    local in_nameserver_addresses=false
    local in_routes=false
    local current_route_index=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace cho comparison
        local trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Debug: show each line being processed
        echo "    🔍 Processing line: '$line' (trimmed: '$trimmed_line')" >&2
        echo "    🔍 Current flags: ethernets=$in_ethernets, addresses=$in_addresses, nameservers=$in_nameservers, nameserver_addresses=$in_nameserver_addresses, routes=$in_routes, interface=$current_interface" >&2
        
        # Parse version
        if [[ $line =~ ^[[:space:]]*version:[[:space:]]*([0-9]+) ]]; then
            NETPLAN_CONFIG_VERSION["version"]="${BASH_REMATCH[1]}"
            
        # Parse renderer
        elif [[ $line =~ ^[[:space:]]*renderer:[[:space:]]*(.+) ]]; then
            NETPLAN_CONFIG_RENDERER["renderer"]="${BASH_REMATCH[1]}"
            
        # Parse ethernets section
        elif [[ $trimmed_line == "ethernets:" ]]; then
            in_ethernets=true
            in_addresses=false
            in_nameservers=false
            in_nameserver_addresses=false
            in_routes=false
            current_interface=""  # Reset interface khi vào ethernets mới
            
        # Parse interface name trong ethernets (chỉ khi ở top level của ethernets, không trong subsection)
        elif [[ $in_ethernets == true ]] && [[ $in_addresses == false ]] && [[ $in_nameservers == false ]] && [[ $in_routes == false ]] \
            && [[ ! "$trimmed_line" =~ ^(addresses|nameservers|routes|dhcp4|dhcp6|gateway4|gateway6): ]] \
            && [[ $line =~ ^[[:space:]]{2,8}([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
            current_interface="${BASH_REMATCH[1]}"
            NETPLAN_CONFIG_ETHERNETS["$current_interface"]="true"
            echo "    🔍 Found interface: $current_interface" >&2
            # Reset tất cả flags khi tìm thấy interface mới
            in_addresses=false
            in_nameservers=false
            in_nameserver_addresses=false
            in_routes=false
            
        # Parse DHCP settings (phải parse trước addresses để không bị skip)
        elif [[ $in_ethernets == true ]] && [[ -n "$current_interface" ]] && [[ $line =~ ^[[:space:]]+dhcp4:[[:space:]]*(.+) ]]; then
            NETPLAN_CONFIG_OTHER_SETTINGS["${current_interface}.dhcp4"]="${BASH_REMATCH[1]}"
            echo "    🔍 Parsed dhcp4: ${BASH_REMATCH[1]} for interface: $current_interface"
            
        elif [[ $in_ethernets == true ]] && [[ -n "$current_interface" ]] && [[ $line =~ ^[[:space:]]+dhcp6:[[:space:]]*(.+) ]]; then
            NETPLAN_CONFIG_OTHER_SETTINGS["${current_interface}.dhcp6"]="${BASH_REMATCH[1]}"
            echo "    🔍 Parsed dhcp6: ${BASH_REMATCH[1]} for interface: $current_interface"
            
        # Parse addresses section
        elif [[ $in_ethernets == true ]] && [[ -n "$current_interface" ]] && [[ $in_nameservers == false ]] && [[ $trimmed_line == "addresses:" ]]; then
            in_addresses=true
            in_nameservers=false
            in_nameserver_addresses=false
            in_routes=false
            echo "    🔍 Found addresses section for interface: $current_interface"
            
        # Parse individual addresses - flexible regex
        elif [[ $in_addresses == true ]] && [[ $in_nameservers == false ]] && [[ $line =~ ^[[:space:]]*-[[:space:]]*(.+) ]]; then
            local address="${BASH_REMATCH[1]}"
            NETPLAN_CONFIG_ADDRESSES["${current_interface}.${address}"]="$address"
            echo "    🔍 Parsed address: $address for interface: $current_interface"
            
        # Parse routes section
        elif [[ $in_ethernets == true ]] && [[ -n "$current_interface" ]] && [[ $trimmed_line == "routes:" ]]; then
            in_routes=true
            in_addresses=false
            in_nameservers=false
            in_nameserver_addresses=false
            current_route_index=0
            echo "    🔍 Found routes section for interface: $current_interface"
            
        # Parse individual routes - flexible regex for various indentations
        elif [[ $in_routes == true ]] && [[ $line =~ ^[[:space:]]*-[[:space:]]*to:[[:space:]]*(.+) ]]; then
            local route_to="${BASH_REMATCH[1]}"
            NETPLAN_CONFIG_ROUTES["${current_interface}.route${current_route_index}.to"]="$route_to"
            echo "    🔍 Parsed route TO: $route_to (index: $current_route_index)"
            
        # Parse route via (gateway) - flexible indentation
        elif [[ $in_routes == true ]] && [[ $line =~ ^[[:space:]]*via:[[:space:]]*(.+) ]]; then
            local route_via="${BASH_REMATCH[1]}"
            NETPLAN_CONFIG_ROUTES["${current_interface}.route${current_route_index}.via"]="$route_via"
            echo "    🔍 Parsed route VIA: $route_via (index: $current_route_index)"
            ((current_route_index++))
            
        # Parse nameservers section
        elif [[ $in_ethernets == true ]] && [[ -n "$current_interface" ]] && [[ $trimmed_line == "nameservers:" ]]; then
            in_nameservers=true
            in_addresses=false
            in_nameserver_addresses=false
            in_routes=false
            echo "    🔍 Found nameservers section for interface: $current_interface"
            
        # Parse nameserver addresses section
        elif [[ $in_nameservers == true ]] && [[ $trimmed_line == "addresses:" ]]; then
            in_nameserver_addresses=true
            in_addresses=false
            echo "    🔍 Found nameserver addresses subsection"
            
        # Parse nameserver addresses - flexible regex
        elif [[ $in_nameserver_addresses == true ]] && [[ $line =~ ^[[:space:]]*-[[:space:]]*(.+) ]]; then
            local ns_address="${BASH_REMATCH[1]}"
            NETPLAN_CONFIG_NAMESERVERS["${current_interface}.${ns_address}"]="$ns_address"
            echo "    🔍 Parsed nameserver: $ns_address for interface: $current_interface">&2
            
        # Reset flags based on indentation and content
        else
            # Reset flags when we encounter lines that indicate we're leaving current sections
            if [[ $line =~ ^[[:space:]]*[a-zA-Z] ]] && [[ ! $line =~ ^[[:space:]]{6,} ]]; then
                # If it's a top-level section (not ethernets), reset everything
                if [[ ! $trimmed_line =~ ^(ethernets|addresses|nameservers|routes): ]]; then
                    if [[ $line =~ ^[a-zA-Z] ]]; then  # Top level
                        in_ethernets=false
                        current_interface=""
                        in_addresses=false
                        in_nameservers=false
                        in_nameserver_addresses=false
                        in_routes=false
                    elif [[ $line =~ ^[[:space:]]{2,4}[a-zA-Z] ]] && [[ $in_ethernets == true ]]; then  # Interface level
                        in_addresses=false
                        in_nameservers=false  
                        in_nameserver_addresses=false
                        in_routes=false
                    fi
                fi
            fi
        fi
        
    done < "$netplan_file"
    
    # Debug output với chi tiết về IPv4/IPv6
    local ipv4_count=0
    local ipv6_count=0
    for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
        local addr="${NETPLAN_CONFIG_ADDRESSES[$key]}"
        if [[ "$addr" =~ :: ]]; then
            ((ipv6_count++))
        else
            ((ipv4_count++))
        fi
    done
    
    echo "✅ Parsed netplan config:"
    echo "  📋 Version: ${NETPLAN_CONFIG_VERSION[version]:-none}"
    echo "  🖥️ Renderer: ${NETPLAN_CONFIG_RENDERER[renderer]:-none}"
    echo "  🔌 Interfaces: ${!NETPLAN_CONFIG_ETHERNETS[*]}"
    echo "  📍 Addresses: ${#NETPLAN_CONFIG_ADDRESSES[@]} found ($ipv4_count IPv4, $ipv6_count IPv6)"
    echo "  🚪 Gateways: ${#NETPLAN_CONFIG_GATEWAYS[@]} found (IPv4 only, IPv6 auto-detect)"
    echo "  �️ Routes: ${#NETPLAN_CONFIG_ROUTES[@]} found"
    echo "  �🔍 Nameservers: ${#NETPLAN_CONFIG_NAMESERVERS[@]} found"
    echo "  ⚙️ DHCP Settings: ${#NETPLAN_CONFIG_OTHER_SETTINGS[@]} found"
    
    # Debug: show tất cả addresses
    for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
        echo "    🏠 $key = ${NETPLAN_CONFIG_ADDRESSES[$key]}"
    done
    
    # Debug: show tất cả routes
    for key in "${!NETPLAN_CONFIG_ROUTES[@]}"; do
        echo "    🛣️ $key = ${NETPLAN_CONFIG_ROUTES[$key]}"
    done
    
    return 0
}

# Thêm IPv6 addresses vào config object
add_ipv6_addresses() {
    local interface="$1"
    shift
    local new_addresses=("$@")
    
    echo "➕ Thêm ${#new_addresses[@]} IPv6 addresses cho interface $interface"
    
    for addr in "${new_addresses[@]}"; do
        # Bỏ IPv6 cũ nếu đã tồn tại (tránh duplicate)
        for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
            if [[ "$key" == "${interface}."* ]] && [[ "${NETPLAN_CONFIG_ADDRESSES[$key]}" == "$addr" ]]; then
                unset NETPLAN_CONFIG_ADDRESSES["$key"]
            fi
        done
        
        # Thêm IPv6 mới
        NETPLAN_CONFIG_ADDRESSES["${interface}.${addr}"]="$addr"
    done
    
    echo "✅ Đã thêm IPv6 addresses vào config object"
}

# Xóa IPv6 addresses từ config object (giữ lại IPv4 và IPv6 đầu tiên)
remove_proxy_ipv6_addresses() {
    local interface="$1"
    
    echo "🗑️ Xóa proxy IPv6 addresses từ interface $interface"
    
    local first_ipv6=""
    local addresses_to_remove=()
    local ipv4_count=0
    local ipv6_count=0
    
    # Đếm và tìm IPv6 đầu tiên để giữ lại
    for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
        if [[ "$key" == "${interface}."* ]]; then
            local addr="${NETPLAN_CONFIG_ADDRESSES[$key]}"
            if [[ "$addr" =~ :: ]]; then
                ((ipv6_count++))
                if [[ -z "$first_ipv6" ]]; then
                    first_ipv6="$addr"
                fi
            else
                ((ipv4_count++))
            fi
        fi
    done
    
    echo "  📊 Tìm thấy: $ipv4_count IPv4, $ipv6_count IPv6"
    echo "  🔒 Giữ lại IPv6 đầu tiên: $first_ipv6"
    
    # Xóa tất cả IPv6 addresses trừ IPv6 đầu tiên (giữ nguyên tất cả IPv4)
    for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
        if [[ "$key" == "${interface}."* ]]; then
            local addr="${NETPLAN_CONFIG_ADDRESSES[$key]}"
            # Chỉ xóa IPv6 (có ::) và không phải IPv6 đầu tiên
            if [[ "$addr" =~ :: ]] && [[ "$addr" != "$first_ipv6" ]]; then
                addresses_to_remove+=("$key")
                echo "  🗑️ Sẽ xóa: $addr"
            elif [[ ! "$addr" =~ :: ]]; then
                echo "  🔒 Giữ lại IPv4: $addr"
            fi
        fi
    done
    
    # Xóa các addresses
    for key in "${addresses_to_remove[@]}"; do
        unset NETPLAN_CONFIG_ADDRESSES["$key"]
    done
    
    echo "✅ Đã xóa ${#addresses_to_remove[@]} proxy IPv6 addresses"
}

# Rebuild netplan config file từ object config
rebuild_netplan_config() {
    local output_file="$1"
    
    echo "🔨 Rebuilding netplan config từ object..."
    
    # Tạo temp file
    local temp_file="/tmp/netplan_rebuild_$$.yaml"
    
    # Bắt đầu tạo file netplan
    {
        echo "network:"
        
        # Version
        if [[ -n "${NETPLAN_CONFIG_VERSION[version]:-}" ]]; then
            echo "  version: ${NETPLAN_CONFIG_VERSION[version]}"
        else
            echo "  version: 2"
        fi
        
        # Renderer
        if [[ -n "${NETPLAN_CONFIG_RENDERER[renderer]:-}" ]]; then
            echo "  renderer: ${NETPLAN_CONFIG_RENDERER[renderer]}"
        fi
        
        # Ethernets section
        if [[ ${#NETPLAN_CONFIG_ETHERNETS[@]} -gt 0 ]]; then
            echo "  ethernets:"
            
            # Lặp qua từng interface
            for interface in "${!NETPLAN_CONFIG_ETHERNETS[@]}"; do
                echo "    $interface:"
                
                # DHCP settings - sử dụng config hiện có hoặc mặc định
                local has_dhcp4=false
                local has_dhcp6=false
                local has_ipv4_addresses=false
                
                # Kiểm tra xem có IPv4 addresses không
                for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
                    if [[ "$key" == "${interface}."* ]]; then
                        local addr="${NETPLAN_CONFIG_ADDRESSES[$key]}"
                        if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                            has_ipv4_addresses=true
                            break
                        fi
                    fi
                done
                
                # DHCP settings từ config hiện có
                for key in "${!NETPLAN_CONFIG_OTHER_SETTINGS[@]}"; do
                    if [[ "$key" == "${interface}.dhcp4" ]]; then
                        echo "      dhcp4: ${NETPLAN_CONFIG_OTHER_SETTINGS[$key]}"
                        has_dhcp4=true
                    elif [[ "$key" == "${interface}.dhcp6" ]]; then
                        echo "      dhcp6: ${NETPLAN_CONFIG_OTHER_SETTINGS[$key]}"
                        has_dhcp6=true
                    fi
                done
                
                # DHCP4 logic: nếu có IPv4 addresses thì dhcp4: false, ngược lại dhcp4: true
                if [[ "$has_dhcp4" == false ]]; then
                    if [[ "$has_ipv4_addresses" == true ]]; then
                        echo "      dhcp4: false"  # Có IPv4 static addresses
                    else
                        echo "      dhcp4: true"   # Không có IPv4 addresses, dùng DHCP
                    fi
                fi
                
                # Nếu không có DHCP6 setting, set dhcp6: false
                if [[ "$has_dhcp6" == false ]]; then
                    echo "      dhcp6: false"
                fi
                
                # Addresses
                local interface_addresses=()
                for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
                    if [[ "$key" == "${interface}."* ]]; then
                        interface_addresses+=("${NETPLAN_CONFIG_ADDRESSES[$key]}")
                    fi
                done
                
                if [[ ${#interface_addresses[@]} -gt 0 ]]; then
                    echo "      addresses:"
                    # Sort addresses để IPv4 trước, IPv6 sau
                    local sorted_addresses=($(printf '%s\n' "${interface_addresses[@]}" | sort -V))
                    for addr in "${sorted_addresses[@]}"; do
                        echo "        - $addr"
                    done
                fi
                
                # Gateways - chỉ giữ gateway4 (IPv4), bỏ qua gateway6 (IPv6 sẽ auto-detect)
                for key in "${!NETPLAN_CONFIG_GATEWAYS[@]}"; do
                    if [[ "$key" == "${interface}.gateway4" ]]; then
                        echo "      gateway4: ${NETPLAN_CONFIG_GATEWAYS[$key]}"
                    fi
                    # Bỏ qua gateway6 - IPv6 gateway thường là prefix::1 và auto-detect
                done
                
                # Nameservers
                local interface_nameservers=()
                for key in "${!NETPLAN_CONFIG_NAMESERVERS[@]}"; do
                    if [[ "$key" == "${interface}."* ]]; then
                        interface_nameservers+=("${NETPLAN_CONFIG_NAMESERVERS[$key]}")
                    fi
                done
                
                if [[ ${#interface_nameservers[@]} -gt 0 ]]; then
                    echo "      nameservers:"
                    echo "        addresses:"
                    for ns in "${interface_nameservers[@]}"; do
                        echo "          - $ns"
                    done
                fi
                
                # Routes
                local interface_routes_to=()
                local interface_routes_via=()
                local route_count=0
                
                # Collect routes for this interface (debug output to stderr)
                echo "    🔍 Checking routes for interface: $interface" >&2
                
                for key in "${!NETPLAN_CONFIG_ROUTES[@]}"; do
                    echo "    🔍 Checking route key: $key" >&2
                    if [[ "$key" == "${interface}.route"*".to" ]]; then
                        local route_index=$(echo "$key" | sed -n 's/.*route\([0-9]*\)\.to/\1/p')
                        local to_key="${interface}.route${route_index}.to"
                        local via_key="${interface}.route${route_index}.via"
                        
                        echo "    🔍 Route index: $route_index, to_key: $to_key, via_key: $via_key" >&2
                        
                        if [[ -n "${NETPLAN_CONFIG_ROUTES[$to_key]:-}" && -n "${NETPLAN_CONFIG_ROUTES[$via_key]:-}" ]]; then
                            interface_routes_to+=("${NETPLAN_CONFIG_ROUTES[$to_key]}")
                            interface_routes_via+=("${NETPLAN_CONFIG_ROUTES[$via_key]}")
                            ((route_count++))
                            echo "    ✅ Added route: ${NETPLAN_CONFIG_ROUTES[$to_key]} via ${NETPLAN_CONFIG_ROUTES[$via_key]}" >&2
                        else
                            echo "    ❌ Missing route data - to: '${NETPLAN_CONFIG_ROUTES[$to_key]:-}' via: '${NETPLAN_CONFIG_ROUTES[$via_key]:-}'" >&2
                        fi
                    fi
                done
                
                echo "    📊 Found $route_count routes for interface $interface" >&2
                
                if [[ $route_count -gt 0 ]]; then
                    echo "      routes:"
                    for ((r=0; r<route_count; r++)); do
                        echo "      - to: ${interface_routes_to[$r]}"
                        echo "        via: ${interface_routes_via[$r]}"
                    done
                fi
            done
        fi
        
    } > "$temp_file"
    
    # Validate YAML syntax
    if command -v python3 &>/dev/null; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$temp_file'))" 2>/dev/null; then
            echo "⚠️ YAML syntax warning, nhưng tiếp tục..."
        fi
    fi
    
    # Copy file với permissions phù hợp
    if sudo cp "$temp_file" "$output_file"; then
        sudo chmod 644 "$output_file"
        rm -f "$temp_file"
        echo "✅ Đã rebuild netplan config: $output_file"
        return 0
    else
        echo "❌ Lỗi khi copy netplan config"
        rm -f "$temp_file"
        return 1
    fi
}

# Hàm chính để cập nhật netplan với IPv6 addresses mới (thay thế insert_ips cũ)
update_netplan_with_ipv6() {
    echo "📝 Cập nhật Netplan với IPv6 addresses bằng object config approach..."
    
    # Parse config hiện tại
    if ! parse_netplan_config "$NETPLAN_FILE"; then
        echo "❌ Không thể parse netplan config"
        return 1
    fi
    
    # Tìm interface chính (thường là interface đầu tiên có addresses)
    local main_interface=""
    for interface in "${!NETPLAN_CONFIG_ETHERNETS[@]}"; do
        # Kiểm tra xem interface có addresses không
        for key in "${!NETPLAN_CONFIG_ADDRESSES[@]}"; do
            if [[ "$key" == "${interface}."* ]]; then
                main_interface="$interface"
                break 2
            fi
        done
    done
    
    # Nếu không tìm thấy interface nào có addresses, lấy interface đầu tiên
    if [[ -z "$main_interface" ]]; then
        main_interface=$(echo "${!NETPLAN_CONFIG_ETHERNETS[@]}" | cut -d' ' -f1)
    fi
    
    if [[ -z "$main_interface" ]]; then
        echo "❌ Không tìm thấy interface nào trong netplan config"
        return 1
    fi
    
    echo "🔌 Sử dụng interface: $main_interface"
    
    # Xóa proxy IPv6 addresses cũ (giữ IPv6 đầu tiên)
    remove_proxy_ipv6_addresses "$main_interface"
    
    # Kiểm tra IP_LIST có tồn tại không
    if [[ ${#IP_LIST[@]} -eq 0 ]]; then
        echo "❌ IP_LIST rỗng, không có gì để thêm"
        return 1
    fi
    
    # Thêm IPv6 addresses mới
    add_ipv6_addresses "$main_interface" "${IP_LIST[@]}"
    
    # Thêm nameservers mặc định nếu chưa có
    local has_cloudflare=false
    for key in "${!NETPLAN_CONFIG_NAMESERVERS[@]}"; do
        if [[ "${NETPLAN_CONFIG_NAMESERVERS[$key]}" == "2606:4700:4700::1111" ]]; then
            has_cloudflare=true
            break
        fi
    done
    
    if [[ "$has_cloudflare" == false ]]; then
        echo "➕ Thêm nameservers mặc định..."
        NETPLAN_CONFIG_NAMESERVERS["${main_interface}.8.8.8.8"]="8.8.8.8"
        NETPLAN_CONFIG_NAMESERVERS["${main_interface}.1.1.1.1"]="1.1.1.1"
        NETPLAN_CONFIG_NAMESERVERS["${main_interface}.2606:4700:4700::1111"]="2606:4700:4700::1111"
    fi
    
    # Rebuild config file
    if ! rebuild_netplan_config "$NETPLAN_FILE"; then
        echo "❌ Không thể rebuild netplan config"
        return 1
    fi
    
    echo "✅ Đã cập nhật Netplan với ${#IP_LIST[@]} IPv6 addresses"
    return 0
}

# Sử dụng approach mới với object config
if ! update_netplan_with_ipv6; then
    echo "❌ Không thể cập nhật netplan, sẽ khôi phục từ backup"
    if [[ -f "$BACKUP" ]]; then
        sudo cp "$BACKUP" "$NETPLAN_FILE"
        echo "🔄 Đã khôi phục netplan từ backup"
    fi
    exit 1
fi

echo "🚀 Áp dụng Netplan..."
if sudo netplan apply 2>/dev/null; then
    echo "✅ Netplan applied successfully"
else
    echo "⚠️ Netplan apply có warning, nhưng tiếp tục..."
fi

### === 2. Tạo cấu hình 3proxy với random password ===
echo "⚙️ Tạo cấu hình 3proxy..."

# Xóa file kết quả cũ và tạo mới
> "$RESULT_FILE"

# Tạo cấu hình 3proxy theo official Docker image format
cat >"$WORKDIR/3proxy.cfg" <<EOF
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
log
auth strong
EOF

USER_BLOCK="users "

echo "🔐 Tạo ${PROXY_COUNT} SOCKS proxy..."

# Kiểm tra IP_LIST có đủ không
if [[ ${#IP_LIST[@]} -lt $PROXY_COUNT ]]; then
  echo "❌ IP_LIST chỉ có ${#IP_LIST[@]} IP nhưng cần $PROXY_COUNT"
  exit 1
fi

# Biến đếm thống kê
reused_count=0
new_count=0

# Tối ưu: Tạo các arrays để batch processing
USER_BLOCKS=()
SOCKS_CONFIGS=()

# Tạm thời tắt strict mode cho vòng lặp này
set +euo pipefail

echo "🔄 Bắt đầu vòng lặp tạo proxy..."

for ((i=0; i<PROXY_COUNT; i++)); do
  # Debug cho 10 proxy đầu
  if [[ $i -lt 10 ]]; then
    echo "  🔧 Đang xử lý proxy $i..."
  fi
  
  # Kiểm tra IP_LIST[$i] tồn tại
  if [[ -z "${IP_LIST[$i]:-}" ]]; then
    echo "❌ IP_LIST[$i] không tồn tại, dừng lại"
    break
  fi
  
  # Lấy IPv6 từ IP_LIST đã tạo (bỏ /64 suffix)
  IPV6_FULL="${IP_LIST[$i]}"
  IPV6_OUT="${IPV6_FULL%/64}"       # IPv6 cho external (outbound traffic)
  PORT=$((PORT_START + i))
  USER="${PROXY_USER}${i}"
  
  # Debug cho 10 proxy đầu
  if [[ $i -lt 10 ]]; then
    echo "    📍 IPv6: $IPV6_OUT, Port: $PORT, User: $USER"
  fi
  
  # Kiểm tra có sử dụng credentials cũ không
  if [[ "$USE_EXISTING_CREDENTIALS" == "true" && -n "${OLD_CREDENTIALS[$PORT]:-}" ]]; then
    # Sử dụng credentials cũ
    IFS=':' read -r old_user old_pass <<< "${OLD_CREDENTIALS[$PORT]}"
    USER="$old_user"
    PASS="$old_pass"
    ((reused_count++))
  else
    # Tạo password mới
    PASS=$(openssl rand -hex 6)
    if [[ -z "$PASS" ]]; then
      echo "❌ Không thể tạo password cho proxy $i"
      PASS="default$(printf "%03d" $i)"  # Fallback password
    fi
    ((new_count++))
  fi
  
  # Thêm vào arrays
  USER_BLOCKS+=("${USER}:CL:${PASS}")
  SOCKS_CONFIGS+=("socks -6 -p${PORT} -e${IPV6_OUT}")
  
  # Lấy IP server (với fallback) - chỉ lần đầu
  if [[ $i -eq 0 ]]; then
    echo "🔍 Lấy IP server..."
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null || echo "YOUR_SERVER_IP")
    echo "  📡 Server IP: $SERVER_IP"
  fi
  
  # Ghi vào result file
  echo "${USER}:${PASS}@${SERVER_IP}:${PORT}" >>"$RESULT_FILE" || {
    echo "❌ Không thể ghi vào file $RESULT_FILE"
    break
  }
  
  # Progress indicator - ít thường xuyên hơn
  if ((i % 100 == 0 && i > 0)); then
    echo "  📊 Đã tạo $i/${PROXY_COUNT} proxy..."
  fi
  
  # Safety check - tránh vòng lặp vô hạn
  if [[ $i -gt 2000 ]]; then
    echo "⚠️ Vòng lặp quá 2000, dừng lại"
    break
  fi
done

echo "🔚 Hoàn tất vòng lặp. Đã tạo $i proxy"

# Khôi phục strict mode
set -euo pipefail

# Hiển thị thống kê
echo "✅ Hoàn tất tạo proxy:"
if [[ $reused_count -gt 0 ]]; then
  echo "  🔄 Sử dụng lại: $reused_count credentials"
fi
if [[ $new_count -gt 0 ]]; then
  echo "  🆕 Tạo mới: $new_count credentials"
fi

# Ghi users block vào file - sử dụng array để tối ưu
echo "🔧 Tạo cấu hình 3proxy..."
{
  echo "users $(IFS=' '; echo "${USER_BLOCKS[*]}")"
  echo ""
  echo "allow * * *"
  echo "flush"
  echo ""
  # Ghi tất cả SOCKS configs
  printf '%s\n' "${SOCKS_CONFIGS[@]}"
} >>"$WORKDIR/3proxy.cfg"

### === 3. Dockerfile và docker-compose ===
echo "🐳 Chuẩn bị Docker files..."

cat >"$WORKDIR/Dockerfile" <<'EOF'
FROM 3proxy/3proxy:latest

# Copy configuration file to the correct location for chroot
COPY 3proxy.cfg /usr/local/3proxy/conf/3proxy.cfg

# Expose port range
EXPOSE 33001-34000

# Use default entrypoint from official image
EOF

cat >"$WORKDIR/docker-compose.yml" <<'EOF'
version: '3.9'
services:
  proxy:
    build: .
    container_name: ipv4-to-ipv6-proxy
    restart: unless-stopped
    network_mode: "host"
    ports:
      - "33001-34000:33001-34000"
EOF

### === 4. Build và Deploy ===
echo "🔨 Building và deploying Docker container..."
cd "$WORKDIR"

# Kiểm tra Docker Compose version và sử dụng lệnh phù hợp
COMPOSE_CMD=""
if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
    echo "  🔍 Sử dụng docker-compose (v1)"
elif docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
    echo "  🔍 Sử dụng docker compose (v2)"
else
    echo "  ⚠️ Không tìm thấy Docker Compose, thử build trực tiếp..."
    # Fallback: build và run trực tiếp không dùng compose
    echo "  🏗️ Building Docker image..."
    if docker build -t 3proxy-docker-proxy . && \
       docker run -d --name ipv4-to-ipv6-proxy --restart unless-stopped --network host 3proxy-docker-proxy; then
        echo "✅ Container started successfully (direct mode)"
        # Nhảy đến phần verification
        COMPOSE_CMD=""  # Đặt rỗng để skip phần compose
    else
        echo "❌ Docker build/run failed"
        exit 1
    fi
fi

# Chỉ chạy compose nếu có COMPOSE_CMD
if [[ -n "$COMPOSE_CMD" ]]; then
    echo "  🚀 Deploying với $COMPOSE_CMD..."
    if $COMPOSE_CMD up -d --build --remove-orphans; then
        echo "✅ Docker container started successfully"
    else
        echo "❌ Docker compose deployment failed"
        exit 1
    fi
fi

# Đợi container sẵn sàng
echo "⏳ Đợi container khởi động..."
sleep 10

if docker ps | grep -q ipv4-to-ipv6-proxy; then
    echo "✅ Container đang chạy"
    
    # Test SOCKS proxy đầu tiên
    FIRST_PROXY=$(head -n1 "$RESULT_FILE")
    echo "🧪 Test SOCKS proxy đầu tiên: $FIRST_PROXY"
    echo "🧪 Ví dụ test với curl: curl --socks5 $FIRST_PROXY https://ip6.me"
    
    # Kiểm tra port đang listen
    echo "🔍 Kiểm tra port ${PORT_START} đang listen..."
    if netstat -tlnp 2>/dev/null | grep -q ":${PORT_START} "; then
        echo "✅ Port ${PORT_START} đang listen"
    else
        echo "⚠️ Port ${PORT_START} không listen, check logs"
    fi
    
    # Suggestion để mở firewall
    echo ""
    echo "🔥 Mở firewall ports:"
    echo "sudo ufw allow ${PORT_START}:$((PORT_START + PROXY_COUNT - 1))/tcp"
    echo ""
else
    echo "❌ Container không khởi động được"
    echo "🔍 Debug logs:"
    docker logs ipv4-to-ipv6-proxy 2>/dev/null || echo "No logs available"
    echo ""
    echo "🔧 Kiểm tra container status:"
    docker ps -a | grep ipv4-to-ipv6-proxy || echo "Container not found"
    exit 1
fi

### === 5. Kết quả ===
echo "🎉 Hoàn tất! Thông tin SOCKS proxy:"
echo "📄 File proxy result: $RESULT_FILE"
echo "🌍 File IPv6 list: $IPV6_LIST_FILE"
echo "📊 Số lượng proxy: $PROXY_COUNT"
echo "🌐 Port range: ${PORT_START}-$((PORT_START + PROXY_COUNT - 1))"
echo "🔗 SOCKS proxy đầu tiên: $(head -n1 $RESULT_FILE)"
echo ""
if [[ "$USE_EXISTING_CREDENTIALS" == "true" ]]; then
    echo "🔄 Đã sử dụng lại credentials cũ từ file proxy_result.txt"
else
    echo "🆕 Đã tạo mới tất cả credentials"
fi

if [[ "$USE_RANDOM_IPV6" == "true" ]]; then
    echo "🎲 Đã sử dụng IPv6 addresses ngẫu nhiên"
else
    echo "📝 Đã sử dụng IPv6 addresses tuần tự từ hex ${START_HEX}"
fi
echo ""

# Upload tới Telegram nếu được cấu hình
upload_to_telegram

echo "💡 Để sử dụng lại username/password cũ lần sau:"
echo "   Đặt USE_EXISTING_CREDENTIALS=true trong script"
echo ""
echo "💡 Để tự động upload kết quả tới Telegram:"
echo "   Đặt TELEGRAM_BOT_TOKEN và TELEGRAM_CHAT_ID trong script"
echo "   📤 Sẽ upload 2 files: proxy_result.txt và ipv6_list.txt"
echo ""
echo "💡 Để sử dụng IPv6 addresses ngẫu nhiên:"
echo "   Đặt USE_RANDOM_IPV6=true trong script (tạo random 4 nhóm sau ::)"
echo ""
echo "💡 Để tự động detect IPv6 prefix và gateway:"
echo "   Đặt PREFIX=\"auto\" và GATEWAY=\"auto\" trong script"
echo ""
echo "ℹ️ Script tự động cài đặt Netplan và migrate cấu hình từ ifupdown nếu cần"
echo ""
echo "🛠️ Các lệnh hữu ích:"
echo "  📋 Xem logs: docker logs -f ipv4-to-ipv6-proxy"
echo "  🔄 Restart: docker restart ipv4-to-ipv6-proxy"
echo "  🛑 Stop: docker stop ipv4-to-ipv6-proxy"
echo "  📊 Status: docker ps | grep proxy"
echo ""
echo "✅ Setup hoàn tất!"