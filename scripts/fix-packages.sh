#!/bin/bash

# Package Recovery Script for Raspberry Pi
# Fixes common package installation issues, especially kernel-related problems

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check available disk space
check_disk_space() {
    log "Checking available disk space..."
    
    local available=$(df / | awk 'NR==2 {print $4}')
    local available_mb=$((available / 1024))
    
    info "Available disk space: ${available_mb}MB"
    
    if [[ $available_mb -lt 500 ]]; then
        error "Insufficient disk space. At least 500MB required."
        echo "Consider running: sudo apt clean && sudo apt autoclean"
        exit 1
    fi
}

# Clean package cache and temporary files
clean_package_system() {
    log "Cleaning package system..."
    
    # Clean package cache
    sudo apt clean
    sudo apt autoclean
    
    # Remove orphaned packages
    sudo apt autoremove -y
    
    # Clean temporary files
    sudo rm -rf /tmp/* 2>/dev/null || true
    sudo rm -rf /var/tmp/* 2>/dev/null || true
}

# Fix broken packages
fix_broken_packages() {
    log "Attempting to fix broken packages..."
    
    # Configure any unconfigured packages
    sudo dpkg --configure -a
    
    # Fix broken dependencies
    sudo apt --fix-broken install -y
    
    # Force install of problematic packages
    sudo apt install -f -y
}

# Handle kernel update issues specifically
fix_kernel_issues() {
    log "Handling kernel update issues..."
    
    # Remove incomplete kernel installations
    warning "Removing incomplete kernel packages..."
    
    # Get list of broken kernel packages
    local broken_kernels=$(dpkg -l | grep "^iU\|^iF" | grep -E "(linux-|initramfs-)" | awk '{print $2}')
    
    if [[ -n "$broken_kernels" ]]; then
        info "Found broken kernel packages: $broken_kernels"
        
        # Remove broken kernel packages
        for package in $broken_kernels; do
            info "Removing broken package: $package"
            sudo dpkg --remove --force-remove-reinstreq "$package" || true
        done
    fi
    
    # Clean up initramfs
    sudo update-initramfs -c -k all 2>/dev/null || true
    
    # Reinstall kernel packages
    info "Reinstalling kernel packages..."
    sudo apt install --reinstall linux-image-rpi-v8 linux-headers-rpi-v8 -y || warning "Could not reinstall some kernel packages"
}

# Update bootloader and firmware
update_firmware() {
    log "Updating firmware and bootloader..."
    
    # Update firmware
    if command -v rpi-update >/dev/null 2>&1; then
        sudo rpi-update || warning "Firmware update failed"
    else
        info "rpi-update not available, skipping firmware update"
    fi
    
    # Update bootloader
    sudo apt install --reinstall raspberrypi-bootloader raspberrypi-kernel -y || warning "Could not update bootloader"
}

# Comprehensive package system recovery
full_recovery() {
    log "Starting full package system recovery..."
    
    check_disk_space
    clean_package_system
    fix_broken_packages
    fix_kernel_issues
    
    # Update package lists
    log "Updating package lists..."
    sudo apt update
    
    # Try a partial upgrade first
    log "Attempting partial upgrade..."
    sudo apt upgrade --with-new-pkgs -y || warning "Partial upgrade had issues"
    
    # Try to complete the full upgrade
    log "Attempting full upgrade..."
    if sudo apt full-upgrade -y; then
        log "Full upgrade completed successfully"
    else
        warning "Full upgrade had issues, but continuing..."
    fi
    
    # Final cleanup
    clean_package_system
    
    log "Package system recovery completed"
}

# Show current system status
show_status() {
    echo
    echo "=========================================="
    echo "System Status"
    echo "=========================================="
    
    # Disk space
    local disk_info=$(df -h / | tail -1)
    local disk_used=$(echo $disk_info | awk '{print $3}')
    local disk_total=$(echo $disk_info | awk '{print $2}')
    local disk_percent=$(echo $disk_info | awk '{print $5}')
    info "Disk usage: $disk_used / $disk_total ($disk_percent)"
    
    # Memory
    local mem_info=$(free -h | grep "Mem:")
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    info "Memory usage: $mem_used / $mem_total"
    
    # Broken packages
    local broken_count=$(dpkg -l | grep -c "^iU\|^iF" || true)
    if [[ $broken_count -gt 0 ]]; then
        warning "Broken packages found: $broken_count"
    else
        info "No broken packages found"
    fi
    
    # Available updates
    local updates=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
    info "Available updates: $updates"
    
    echo
}

# Interactive menu
show_menu() {
    echo
    echo "=========================================="
    echo "Package Recovery Menu"
    echo "=========================================="
    echo
    echo "1. Show system status"
    echo "2. Clean package cache"
    echo "3. Fix broken packages"
    echo "4. Fix kernel issues"
    echo "5. Update firmware"
    echo "6. Full recovery (all of the above)"
    echo "7. Try system upgrade again"
    echo "0. Exit"
    echo
}

# Retry system upgrade
retry_upgrade() {
    log "Retrying system upgrade..."
    
    # Update package lists
    sudo apt update
    
    # Try upgrade with various options
    if sudo apt upgrade -y; then
        log "System upgrade completed successfully"
    elif sudo apt upgrade -y --fix-missing; then
        log "System upgrade completed with --fix-missing"
    elif sudo apt dist-upgrade -y; then
        log "System upgrade completed with dist-upgrade"
    else
        error "System upgrade still failing. Manual intervention may be required."
        echo
        echo "You can try:"
        echo "1. sudo apt upgrade --simulate (to see what would happen)"
        echo "2. sudo apt upgrade package-name (to upgrade specific packages)"
        echo "3. Check /var/log/dpkg.log for detailed error information"
    fi
}

# Main function
main() {
    echo
    echo "=========================================="
    echo "Raspberry Pi Package Recovery Tool"
    echo "=========================================="
    echo
    
    if [[ $# -eq 0 ]]; then
        # Interactive mode
        while true; do
            show_menu
            read -p "Select option (0-7): " choice
            
            case $choice in
                1) show_status ;;
                2) clean_package_system ;;
                3) fix_broken_packages ;;
                4) fix_kernel_issues ;;
                5) update_firmware ;;
                6) full_recovery ;;
                7) retry_upgrade ;;
                0) log "Goodbye!"; exit 0 ;;
                *) error "Invalid option. Please try again." ;;
            esac
            
            echo
            read -p "Press Enter to continue..."
        done
    else
        # Command line mode
        case "$1" in
            "status") show_status ;;
            "clean") clean_package_system ;;
            "fix") fix_broken_packages ;;
            "kernel") fix_kernel_issues ;;
            "firmware") update_firmware ;;
            "full") full_recovery ;;
            "upgrade") retry_upgrade ;;
            *)
                echo "Usage: $0 [status|clean|fix|kernel|firmware|full|upgrade]"
                echo "  status   - Show system status"
                echo "  clean    - Clean package cache"
                echo "  fix      - Fix broken packages"
                echo "  kernel   - Fix kernel issues"
                echo "  firmware - Update firmware"
                echo "  full     - Full recovery"
                echo "  upgrade  - Retry system upgrade"
                echo "  (no args) - Interactive menu"
                exit 1
                ;;
        esac
    fi
}

# Check if running as root
if [[ $EUID -ne 0 && "$1" != "status" ]]; then
    error "This script needs to be run with sudo for most operations."
    echo "Usage: sudo $0 [command]"
    exit 1
fi

# Run main function
main "$@"
