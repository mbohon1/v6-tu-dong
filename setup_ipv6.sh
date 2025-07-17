#!/bin/bash

# Script tự động cấu hình IPv6 cho VPS (Ubuntu/Debian)
# GitHub: https://github.com/mbohon1/v6-tu-dong
# Usage: curl -fsSL https://raw.githubusercontent.com/mbohon1/v6-tu-dong/refs/heads/main/setup_ipv6.sh | sudo bash

set -euo pipefail

echo "=========================================="
echo "Script tự động cấu hình IPv6 cho VPS"
echo "Hỗ trợ: Ubuntu, Debian"
echo "=========================================="

# Constants
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Global variables
MAIN_INTERFACE=""
NETPLAN_FILE=""
BACKUP_DIR=""
OS_TYPE=""
OS_VERSION=""
NETWORK_CONFIG_TYPE=""
PING_CMD=""

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $1"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Script này cần chạy với quyền root (sudo)"
        exit 1
    fi
}

# Detect operating system
detect_os() {
    print_info "Nhận diện hệ điều hành..."
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    else
        print_error "Không thể nhận diện hệ điều hành"
        exit 1
    fi
    
    case "$OS_TYPE" in
        ubuntu)
            print_success "Phát hiện Ubuntu $OS_VERSION"
            ;;
        debian)
            print_success "Phát hiện Debian $OS_VERSION"
            ;;
        *)
            print_error "Hệ điều hành không được hỗ trợ: $OS_TYPE"
            print_info "Script chỉ hỗ trợ Ubuntu và Debian"
            exit 1
            ;;
    esac
}

# Detect network configuration type
detect_network_config() {
    print_info "Nhận diện loại cấu hình mạng..."
    
    if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]]; then
        NETWORK_CONFIG_TYPE="netplan"
        print_success "Sử dụng Netplan"
    elif [[ -f /etc/network/interfaces ]]; then
        NETWORK_CONFIG_TYPE="interfaces"
        print_success "Sử dụng /etc/network/interfaces"
    else
        print_error "Không thể nhận diện loại cấu hình mạng"
        exit 1
    fi
}

# Install required packages
install_packages() {
    print_info "Cài đặt các gói cần thiết..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package list quietly
    apt-get update -qq >/dev/null 2>&1
    
    # Required packages
    local packages=("iputils-ping" "dnsutils" "net-tools")
    
    if [[ "$NETWORK_CONFIG_TYPE" == "netplan" ]]; then
        packages+=("netplan.io")
    else
        packages+=("ifupdown")
    fi
    
    # Install only missing packages
    local to_install=()
    for package in "${packages[@]}"; do
        if ! dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
            to_install+=("$package")
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        print_info "Cài đặt: ${to_install[*]}"
        apt-get install -y "${to_install[@]}" >/dev/null 2>&1
    fi
    
    print_success "Các gói đã được cài đặt"
}

# Detect ping command
detect_ping_command() {
    if command -v ping6 >/dev/null 2>&1; then
        PING_CMD="ping6"
    else
        PING_CMD="ping -6"
    fi
}

# Backup configurations
backup_configs() {
    print_info "Backup cấu hình hiện tại..."
    BACKUP_DIR="/root/network_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    case "$NETWORK_CONFIG_TYPE" in
        netplan)
            [[ -d /etc/netplan ]] && cp -r /etc/netplan/* "$BACKUP_DIR/" 2>/dev/null || true
            ;;
        interfaces)
            [[ -f /etc/network/interfaces ]] && cp /etc/network/interfaces "$BACKUP_DIR/"
            [[ -d /etc/network/interfaces.d ]] && cp -r /etc/network/interfaces.d "$BACKUP_DIR/" 2>/dev/null || true
            ;;
    esac
    
    # Backup sysctl configuration
    [[ -f /etc/sysctl.d/99-ipv6.conf ]] && cp /etc/sysctl.d/99-ipv6.conf "$BACKUP_DIR/"
    
    print_success "Backup hoàn tất tại: $BACKUP_DIR"
}

# Detect main network interface
detect_interface() {
    print_info "Phát hiện interface mạng chính..."
    
    # Try multiple methods to find the main interface
    MAIN_INTERFACE=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        MAIN_INTERFACE=$(ip -4 addr show 2>/dev/null | grep -E "inet.*global" | head -1 | awk '{print $NF}')
    fi
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        print_error "Không tìm thấy interface mạng chính"
        print_info "Các interface hiện có:"
        ip link show | grep -E "^[0-9]+" | awk '{print "  " $2}' | sed 's/://'
        exit 1
    fi
    
    print_success "Interface mạng chính: $MAIN_INTERFACE"
}

# Check current IPv6 status
check_ipv6_status() {
    print_info "Kiểm tra trạng thái IPv6 hiện tại..."
    
    # Check if IPv6 is enabled
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        print_warning "IPv6 đang bị disable"
        return 1
    fi
    
    print_success "IPv6 đã được enable trong kernel"
    
    # Check for existing IPv6 global address
    local ipv6_global
    ipv6_global=$(ip -6 addr show "$MAIN_INTERFACE" 2>/dev/null | grep "scope global" | awk '{print $2}' | head -1)
    
    if [[ -n "$ipv6_global" ]]; then
        print_success "Đã có địa chỉ IPv6 global: $ipv6_global"
        return 0
    else
        print_warning "Chưa có địa chỉ IPv6 global"
        return 1
    fi
}

# Enable IPv6 in kernel
enable_ipv6_kernel() {
    print_info "Enabling IPv6 trong kernel..."
    
    # Enable IPv6 immediately
    {
        echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6
        echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6
        echo 0 > /proc/sys/net/ipv6/conf/lo/disable_ipv6
    } 2>/dev/null || true
    
    # Create persistent configuration
    cat > /etc/sysctl.d/99-ipv6.conf << EOF
# Enable IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

# Accept Router Advertisements
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.${MAIN_INTERFACE}.accept_ra = 1

# IPv6 Privacy Extensions
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2

# IPv6 forwarding (disabled by default)
net.ipv6.conf.all.forwarding = 0
EOF
    
    sysctl -p /etc/sysctl.d/99-ipv6.conf >/dev/null 2>&1
    print_success "IPv6 đã được enable"
}

# Find appropriate netplan file
find_netplan_file() {
    print_info "Tìm file netplan..."
    
    # Priority order for netplan files
    local candidates=(
        "/etc/netplan/01-netcfg.yaml"
        "/etc/netplan/00-installer-config.yaml"
        "/etc/netplan/50-cloud-init.yaml"
        "/etc/netplan/01-network-manager-all.yaml"
    )
    
    for file in "${candidates[@]}"; do
        if [[ -f "$file" ]]; then
            NETPLAN_FILE="$file"
            print_success "Sử dụng file netplan: $NETPLAN_FILE"
            return 0
        fi
    done
    
    # Find any existing netplan file
    local existing_file
    existing_file=$(find /etc/netplan -name "*.yaml" -type f 2>/dev/null | head -1)
    
    if [[ -n "$existing_file" ]]; then
        NETPLAN_FILE="$existing_file"
        print_success "Sử dụng file netplan hiện có: $NETPLAN_FILE"
        return 0
    fi
    
    # Create new file if none found
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    print_info "Tạo file netplan mới: $NETPLAN_FILE"
}

# Configure Netplan
configure_netplan() {
    print_info "Cấu hình Netplan..."
    
    find_netplan_file
    
    # Create netplan configuration
    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${MAIN_INTERFACE}:
      dhcp4: true
      dhcp4-overrides:
        use-routes: true
        use-dns: true
      
      dhcp6: true
      dhcp6-overrides:
        use-routes: true
        use-dns: true
      
      accept-ra: true
      link-local: ['ipv6']
      
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
          - 2001:4860:4860::8888
          - 2001:4860:4860::8844
        search: []
EOF
    
    # Set proper permissions
    chmod 600 "$NETPLAN_FILE"
    find /etc/netplan -name "*.yaml" -exec chmod 600 {} \; 2>/dev/null || true
    
    print_success "Cấu hình Netplan đã được tạo"
}

# Configure interfaces file
configure_interfaces() {
    print_info "Cấu hình /etc/network/interfaces..."
    
    # Backup original file
    cp /etc/network/interfaces "/etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Create new configuration
    cat > /etc/network/interfaces << EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto ${MAIN_INTERFACE}
iface ${MAIN_INTERFACE} inet dhcp

# IPv6 configuration
iface ${MAIN_INTERFACE} inet6 auto
    accept_ra 1
    privext 2
    
iface ${MAIN_INTERFACE} inet6 dhcp
    accept_ra 1
EOF
    
    print_success "Cấu hình interfaces đã được tạo"
}

# Apply network configuration
apply_network_config() {
    print_info "Áp dụng cấu hình mạng..."
    
    case "$NETWORK_CONFIG_TYPE" in
        netplan)
            if ! netplan generate 2>/dev/null; then
                print_error "Cấu hình Netplan không hợp lệ"
                return 1
            fi
            
            print_success "Cấu hình Netplan hợp lệ"
            
            if ! netplan apply 2>/dev/null; then
                print_error "Lỗi khi áp dụng cấu hình netplan"
                return 1
            fi
            ;;
            
        interfaces)
            if systemctl is-active --quiet networking; then
                systemctl restart networking
            else
                /etc/init.d/networking restart
            fi
            ;;
    esac
    
    print_success "Cấu hình mạng đã được áp dụng"
}

# Wait for IPv6 address
wait_for_ipv6() {
    print_info "Chờ nhận địa chỉ IPv6..."
    
    local count=0
    local max_attempts=30
    
    while [[ $count -lt $max_attempts ]]; do
        local ipv6_global
        ipv6_global=$(ip -6 addr show "$MAIN_INTERFACE" 2>/dev/null | grep "scope global" | awk '{print $2}' | head -1)
        
        if [[ -n "$ipv6_global" ]]; then
            print_success "Đã nhận địa chỉ IPv6: $ipv6_global"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((count++))
    done
    
    echo ""
    print_warning "Chưa nhận được địa chỉ IPv6 global sau $((max_attempts * 2)) giây"
    return 1
}

# Test IPv6 connectivity
test_ipv6_connectivity() {
    print_info "Test kết nối IPv6..."
    
    # Test ping6
    if timeout 10 $PING_CMD -c 2 google.com >/dev/null 2>&1; then
        print_success "Ping IPv6 Google thành công"
    else
        print_error "Ping IPv6 Google thất bại"
        return 1
    fi
    
    # Test DNS over IPv6
    if timeout 10 nslookup google.com 2001:4860:4860::8888 >/dev/null 2>&1; then
        print_success "DNS over IPv6 hoạt động"
    else
        print_warning "DNS over IPv6 có vấn đề"
    fi
    
    return 0
}

# Show system information
show_system_info() {
    print_info "Thông tin hệ thống sau khi cấu hình:"
    
    echo ""
    echo "=== Hệ điều hành ==="
    echo "  OS: $OS_TYPE $OS_VERSION"
    echo "  Network Config: $NETWORK_CONFIG_TYPE"
    
    echo ""
    echo "=== Địa chỉ IP ==="
    ip addr show "$MAIN_INTERFACE" | grep -E "(inet|inet6)" | sed 's/^/  /'
    
    echo ""
    echo "=== Route IPv6 ==="
    ip -6 route show | sed 's/^/  /'
    
    echo ""
    echo "=== Test kết nối IPv6 ==="
    if timeout 5 $PING_CMD -c 2 google.com >/dev/null 2>&1; then
        echo "  IPv6 connectivity: OK"
    else
        echo "  IPv6 connectivity: FAILED"
    fi
}

# Create monitoring script
create_monitoring_script() {
    print_info "Tạo script monitoring IPv6..."
    
    cat > /usr/local/bin/check_ipv6.sh << 'EOF'
#!/bin/bash
# IPv6 Health Check Script (Ubuntu/Debian)

set -euo pipefail

# Detect ping command
if command -v ping6 >/dev/null 2>&1; then
    PING_CMD="ping6"
else
    PING_CMD="ping -6"
fi

check_ipv6_health() {
    # Check IPv6 is enabled
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        echo "ERROR: IPv6 is disabled"
        return 1
    fi
    
    # Check main interface
    local main_interface
    main_interface=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    
    if [[ -z "$main_interface" ]]; then
        echo "ERROR: No default interface found"
        return 1
    fi
    
    # Check IPv6 global address
    local ipv6_global
    ipv6_global=$(ip -6 addr show "$main_interface" 2>/dev/null | grep "scope global" | awk '{print $2}' | head -1)
    
    if [[ -z "$ipv6_global" ]]; then
        echo "ERROR: No IPv6 global address"
        return 1
    fi
    
    # Check IPv6 connectivity
    if ! timeout 5 $PING_CMD -c 2 google.com >/dev/null 2>&1; then
        echo "ERROR: IPv6 connectivity failed"
        return 1
    fi
    
    echo "OK: IPv6 is working properly"
    echo "Interface: $main_interface"
    echo "IPv6 Address: $ipv6_global"
    return 0
}

show_status() {
    echo "=== System Info ==="
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "  OS: $ID $VERSION_ID"
    fi
    
    echo ""
    echo "=== IPv6 Status ==="
    ip -6 addr show | grep -E "(inet6|scope)" | sed 's/^/  /'
    
    echo ""
    echo "=== IPv6 Routes ==="
    ip -6 route show | sed 's/^/  /'
}

test_connectivity() {
    echo "Testing IPv6 connectivity..."
    echo ""
    echo "=== Ping Test ==="
    $PING_CMD -c 4 google.com
    
    echo ""
    echo "=== DNS Test ==="
    nslookup google.com 2001:4860:4860::8888
}

# Main function
main() {
    case "${1:-}" in
        check)
            check_ipv6_health
            ;;
        status)
            show_status
            ;;
        test)
            test_connectivity
            ;;
        *)
            echo "IPv6 Health Check Script"
            echo "Usage: $0 {check|status|test}"
            echo ""
            echo "Commands:"
            echo "  check  - Check IPv6 health"
            echo "  status - Show IPv6 status"
            echo "  test   - Test IPv6 connectivity"
            exit 1
            ;;
    esac
}

main "$@"
EOF
    
    chmod +x /usr/local/bin/check_ipv6.sh
    print_success "Script monitoring đã được tạo tại /usr/local/bin/check_ipv6.sh"
}

# Rollback configuration
rollback_config() {
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        print_warning "Rollback cấu hình về trạng thái ban đầu..."
        
        case "$NETWORK_CONFIG_TYPE" in
            netplan)
                rm -f /etc/netplan/*.yaml
                cp -r "$BACKUP_DIR"/* /etc/netplan/ 2>/dev/null || true
                netplan apply 2>/dev/null || true
                ;;
            interfaces)
                [[ -f "$BACKUP_DIR/interfaces" ]] && cp "$BACKUP_DIR/interfaces" /etc/network/interfaces
                systemctl restart networking 2>/dev/null || /etc/init.d/networking restart
                ;;
        esac
        
        print_info "Rollback hoàn tất"
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "Script thất bại với exit code: $exit_code"
        read -p "Bạn có muốn rollback không? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rollback_config
        fi
    fi
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Main function
main() {
    print_info "Bắt đầu cấu hình IPv6..."
    
    # Initial checks
    check_root
    detect_os
    detect_network_config
    detect_ping_command
    
    # Install required packages
    install_packages
    
    # Backup and configure
    backup_configs
    detect_interface
    
    # Check current IPv6 status
    if check_ipv6_status; then
        print_success "IPv6 đã hoạt động, tiếp tục cấu hình để tối ưu..."
    fi
    
    # Configure IPv6
    enable_ipv6_kernel
    
    # Configure network based on type
    case "$NETWORK_CONFIG_TYPE" in
        netplan)
            configure_netplan
            ;;
        interfaces)
            configure_interfaces
            ;;
    esac
    
    # Apply and test configuration
    if ! apply_network_config; then
        print_error "Không thể áp dụng cấu hình mạng"
        exit 1
    fi
    
    # Wait for IPv6 address
    sleep 3
    if ! wait_for_ipv6; then
        print_warning "Có thể nhà cung cấp chưa hỗ trợ IPv6 hoặc cần cấu hình thêm"
    fi
    
    # Test connectivity
    if test_ipv6_connectivity; then
        print_success "IPv6 đã được cấu hình thành công!"
    else
        print_warning "IPv6 cấu hình hoàn tất nhưng có thể có vấn đề kết nối"
    fi
    
    # Show results
    show_system_info
    create_monitoring_script
    
    echo ""
    print_success "=== Hoàn tất cấu hình IPv6 ==="
    echo "Hệ điều hành: $OS_TYPE $OS_VERSION"
    echo "Cấu hình mạng: $NETWORK_CONFIG_TYPE"
    echo ""
    echo "Sử dụng lệnh sau để kiểm tra:"
    echo "  check_ipv6.sh check   - Kiểm tra tình trạng IPv6"
    echo "  check_ipv6.sh status  - Hiển thị thông tin IPv6"
    echo "  check_ipv6.sh test    - Test kết nối IPv6"
    echo ""
    echo "File backup: $BACKUP_DIR"
}

# Execute main function
main "$@"
