#!/bin/bash

# Script tự động cấu hình IPv6 cho VPS
# Tên file: setup_ipv6.sh
# Sử dụng: chmod +x setup_ipv6.sh && sudo ./setup_ipv6.sh

set -euo pipefail  # Exit on error, undefined vars, pipe failures

echo "=========================================="
echo "Script tự động cấu hình IPv6 cho VPS"
echo "=========================================="

# Màu sắc cho output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Variables
MAIN_INTERFACE=""
NETPLAN_FILE=""
BACKUP_DIR=""

# Hàm in màu
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

# Kiểm tra quyền root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Script này cần chạy với quyền root (sudo)"
        exit 1
    fi
}

# Backup file cấu hình hiện tại
backup_configs() {
    print_info "Backup cấu hình hiện tại..."
    BACKUP_DIR="/root/netplan_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    if [[ -d /etc/netplan ]]; then
        cp -r /etc/netplan/* "$BACKUP_DIR/" 2>/dev/null || true
        print_success "Backup hoàn tất tại: $BACKUP_DIR"
    else
        print_warning "Thư mục /etc/netplan không tồn tại"
    fi
}

# Kiểm tra interface mạng chính
detect_interface() {
    print_info "Phát hiện interface mạng chính..."
    MAIN_INTERFACE=$(ip route show default | head -1 | awk '{print $5}')
    
    if [[ -z "$MAIN_INTERFACE" ]]; then
        print_error "Không tìm thấy interface mạng chính"
        exit 1
    fi
    
    print_success "Interface mạng chính: $MAIN_INTERFACE"
}

# Kiểm tra trạng thái IPv6 hiện tại
check_ipv6_status() {
    print_info "Kiểm tra trạng thái IPv6 hiện tại..."
    
    # Kiểm tra IPv6 có enabled không
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        print_warning "IPv6 đang bị disable"
        return 1
    else
        print_success "IPv6 đã được enable trong kernel"
    fi
    
    # Kiểm tra địa chỉ IPv6 hiện tại
    local ipv6_global
    ipv6_global=$(ip -6 addr show "$MAIN_INTERFACE" | grep "scope global" | awk '{print $2}' | head -1)
    
    if [[ -n "$ipv6_global" ]]; then
        print_success "Đã có địa chỉ IPv6 global: $ipv6_global"
        return 0
    else
        print_warning "Chưa có địa chỉ IPv6 global"
        return 1
    fi
}

# Enable IPv6 trong kernel
enable_ipv6_kernel() {
    print_info "Enabling IPv6 trong kernel..."
    
    # Enable IPv6 ngay lập tức
    echo 0 | tee /proc/sys/net/ipv6/conf/all/disable_ipv6 >/dev/null
    echo 0 | tee /proc/sys/net/ipv6/conf/default/disable_ipv6 >/dev/null
    echo 0 | tee /proc/sys/net/ipv6/conf/lo/disable_ipv6 >/dev/null
    
    # Tạo file cấu hình persistent
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
EOF
    
    sysctl -p /etc/sysctl.d/99-ipv6.conf >/dev/null
    print_success "IPv6 đã được enable"
}

# Tìm file netplan phù hợp
find_netplan_file() {
    print_info "Tìm file netplan..."
    
    # Tìm file netplan hiện tại theo thứ tự ưu tiên
    local candidates=(
        "/etc/netplan/01-netcfg.yaml"
        "/etc/netplan/00-installer-config.yaml"
        "/etc/netplan/50-cloud-init.yaml"
    )
    
    for file in "${candidates[@]}"; do
        if [[ -f "$file" ]]; then
            NETPLAN_FILE="$file"
            print_success "Sử dụng file: $NETPLAN_FILE"
            return 0
        fi
    done
    
    # Nếu không tìm thấy, tạo file mới
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    print_info "Tạo file netplan mới: $NETPLAN_FILE"
}

# Tạo cấu hình Netplan
create_netplan_config() {
    print_info "Tạo cấu hình Netplan..."
    
    find_netplan_file
    
    # Tạo cấu hình mới
    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${MAIN_INTERFACE}:
      # IPv4 configuration
      dhcp4: true
      dhcp4-overrides:
        use-routes: true
        use-dns: true
      
      # IPv6 configuration
      dhcp6: true
      dhcp6-overrides:
        use-routes: true
        use-dns: true
      
      # Accept Router Advertisements
      accept-ra: true
      
      # Set link-local address
      link-local: ['ipv6']
      
      # DNS servers (IPv4 + IPv6)
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
          - 2001:4860:4860::8888
          - 2001:4860:4860::8844
        search: []
EOF
    
    # Sửa quyền truy cập
    chmod 600 "$NETPLAN_FILE"
    
    # Sửa quyền cho tất cả file netplan
    chmod 600 /etc/netplan/*.yaml 2>/dev/null || true
    
    print_success "Cấu hình Netplan đã được tạo"
}

# Áp dụng cấu hình
apply_netplan() {
    print_info "Áp dụng cấu hình Netplan..."
    
    # Kiểm tra syntax
    if ! netplan generate 2>/dev/null; then
        print_error "Cấu hình Netplan không hợp lệ"
        return 1
    fi
    
    print_success "Cấu hình Netplan hợp lệ"
    
    # Áp dụng cấu hình
    netplan apply 2>/dev/null || {
        print_error "Lỗi khi áp dụng cấu hình netplan"
        return 1
    }
    
    print_success "Cấu hình đã được áp dụng"
    return 0
}

# Kiểm tra và chờ IPv6
wait_for_ipv6() {
    print_info "Chờ nhận địa chỉ IPv6..."
    
    local count=0
    local max_attempts=30
    
    while [[ $count -lt $max_attempts ]]; do
        local ipv6_global
        ipv6_global=$(ip -6 addr show "$MAIN_INTERFACE" | grep "scope global" | awk '{print $2}' | head -1)
        
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

# Test kết nối IPv6
test_ipv6_connectivity() {
    print_info "Test kết nối IPv6..."
    
    # Test ping6
    if timeout 10 ping6 -c 2 google.com >/dev/null 2>&1; then
        print_success "Ping6 Google thành công"
    else
        print_error "Ping6 Google thất bại"
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

# Hiển thị thông tin hệ thống
show_system_info() {
    print_info "Thông tin hệ thống sau khi cấu hình:"
    
    echo ""
    echo "=== Địa chỉ IP ==="
    ip addr show "$MAIN_INTERFACE" | grep -E "(inet|inet6)" | sed 's/^/  /'
    
    echo ""
    echo "=== Route IPv6 ==="
    ip -6 route show | sed 's/^/  /'
    
    echo ""
    echo "=== Test kết nối ==="
    ping6 -c 2 google.com 2>/dev/null | sed 's/^/  /' || echo "  Kết nối IPv6 thất bại"
}

# Tạo script monitoring
create_monitoring_script() {
    print_info "Tạo script monitoring IPv6..."
    
    cat > /usr/local/bin/check_ipv6.sh << 'EOF'
#!/bin/bash
# IPv6 Health Check Script

set -euo pipefail

check_ipv6_health() {
    # Check IPv6 is enabled
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        echo "ERROR: IPv6 is disabled"
        return 1
    fi
    
    # Check IPv6 global address
    local main_interface
    main_interface=$(ip route show default | head -1 | awk '{print $5}')
    
    if [[ -z "$main_interface" ]]; then
        echo "ERROR: No default interface found"
        return 1
    fi
    
    local ipv6_global
    ipv6_global=$(ip -6 addr show "$main_interface" | grep "scope global" | awk '{print $2}' | head -1)
    
    if [[ -z "$ipv6_global" ]]; then
        echo "ERROR: No IPv6 global address"
        return 1
    fi
    
    # Check IPv6 connectivity
    if ! timeout 5 ping6 -c 2 google.com >/dev/null 2>&1; then
        echo "ERROR: IPv6 connectivity failed"
        return 1
    fi
    
    echo "OK: IPv6 is working properly"
    echo "IPv6 Address: $ipv6_global"
    return 0
}

# Main
case "${1:-}" in
    "check")
        check_ipv6_health
        ;;
    "status")
        echo "=== IPv6 Status ==="
        ip -6 addr show | grep -E "(inet6|scope)" | sed 's/^/  /'
        echo ""
        echo "=== IPv6 Routes ==="
        ip -6 route show | sed 's/^/  /'
        ;;
    "test")
        echo "Testing IPv6 connectivity..."
        ping6 -c 4 google.com
        ;;
    *)
        echo "Usage: $0 {check|status|test}"
        exit 1
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/check_ipv6.sh
    print_success "Script monitoring đã được tạo tại /usr/local/bin/check_ipv6.sh"
}

# Rollback function
rollback_config() {
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        print_warning "Rollback cấu hình về trạng thái ban đầu..."
        cp -r "$BACKUP_DIR"/* /etc/netplan/ 2>/dev/null || true
        netplan apply 2>/dev/null || true
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

# Trap để cleanup khi script bị interrupt
trap cleanup EXIT INT TERM

# Hàm main
main() {
    print_info "Bắt đầu cấu hình IPv6..."
    
    # Kiểm tra quyền root
    check_root
    
    # Backup cấu hình
    backup_configs
    
    # Detect interface
    detect_interface
    
    # Check current IPv6 status
    if check_ipv6_status; then
        print_success "IPv6 đã hoạt động, tiếp tục cấu hình để tối ưu..."
    fi
    
    # Enable IPv6 in kernel
    enable_ipv6_kernel
    
    # Create netplan config
    create_netplan_config
    
    # Apply configuration
    if ! apply_netplan; then
        print_error "Không thể áp dụng cấu hình netplan"
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
    
    # Show system info
    show_system_info
    
    # Create monitoring script
    create_monitoring_script
    
    echo ""
    print_success "=== Hoàn tất cấu hình IPv6 ==="
    echo "Sử dụng lệnh sau để kiểm tra:"
    echo "  check_ipv6.sh check   - Kiểm tra tình trạng IPv6"
    echo "  check_ipv6.sh status  - Hiển thị thông tin IPv6"
    echo "  check_ipv6.sh test    - Test kết nối IPv6"
    echo ""
    echo "File backup: $BACKUP_DIR"
}

# Chạy script
main "$@"
