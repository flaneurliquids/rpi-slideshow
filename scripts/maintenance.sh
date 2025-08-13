#!/bin/bash

# Raspberry Pi Slideshow System Maintenance Script
# Performs system cleanup, monitoring, and maintenance tasks

set -e

# Configuration
SLIDESHOW_DIR="/home/pi/slideshow"
LOG_DIR="$SLIDESHOW_DIR/logs"
BACKUP_DIR="/home/pi/slideshow-backup"
MAX_LOG_SIZE="50M"
MAX_LOG_AGE="30"

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
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Display system status
show_system_status() {
    log "=== System Status ==="
    
    # System info
    if [[ -f /proc/cpuinfo ]]; then
        local model=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
        info "System: $model"
    fi
    
    # Uptime
    local uptime=$(uptime -p)
    info "Uptime: $uptime"
    
    # CPU temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp=$((temp / 1000))
        if [[ $temp -gt 70 ]]; then
            warning "CPU Temperature: ${temp}°C (HIGH)"
        else
            info "CPU Temperature: ${temp}°C"
        fi
    fi
    
    # Memory usage
    local mem_info=$(free -h | grep "Mem:")
    local mem_used=$(echo $mem_info | awk '{print $3}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_percent=$(free | grep "Mem:" | awk '{printf "%.1f", $3/$2 * 100.0}')
    info "Memory: $mem_used / $mem_total (${mem_percent}%)"
    
    # Disk usage
    local disk_info=$(df -h / | tail -1)
    local disk_used=$(echo $disk_info | awk '{print $3}')
    local disk_total=$(echo $disk_info | awk '{print $2}')
    local disk_percent=$(echo $disk_info | awk '{print $5}')
    info "Disk: $disk_used / $disk_total ($disk_percent)"
    
    # Network status
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        info "Network: Connected"
    else
        warning "Network: Disconnected"
    fi
    
    echo
}

# Show service status
show_service_status() {
    log "=== Service Status ==="
    
    local services=("slideshow" "slideshow-monitor" "slideshow-sync")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            local status="ACTIVE"
            local color="${GREEN}"
        else
            local status="INACTIVE"
            local color="${RED}"
        fi
        
        echo -e "  ${color}$service${NC}: $status"
        
        # Show restart count
        local restart_count=$(systemctl show "$service" --property=NRestarts --value)
        if [[ $restart_count -gt 0 ]]; then
            info "    Restarts: $restart_count"
        fi
    done
    
    echo
}

# Clean up log files
cleanup_logs() {
    log "=== Cleaning up log files ==="
    
    if [[ ! -d "$LOG_DIR" ]]; then
        warning "Log directory not found: $LOG_DIR"
        return
    fi
    
    local cleaned=0
    
    # Remove large log files
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            info "Truncating large log file: $(basename "$file")"
            tail -n 1000 "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
            ((cleaned++))
        fi
    done < <(find "$LOG_DIR" -name "*.log" -size +$MAX_LOG_SIZE -print0)
    
    # Remove old log files
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            info "Removing old log file: $(basename "$file")"
            rm "$file"
            ((cleaned++))
        fi
    done < <(find "$LOG_DIR" -name "*.log.*" -mtime +$MAX_LOG_AGE -print0)
    
    # Remove temporary files
    find /tmp -name "slideshow_*" -mtime +1 -delete 2>/dev/null || true
    
    info "Cleaned $cleaned log files"
    echo
}

# Clean up image cache
cleanup_cache() {
    log "=== Cleaning up image cache ==="
    
    local cache_dir="/tmp"
    local cleaned=0
    
    # Remove old processed images
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            rm "$file"
            ((cleaned++))
        fi
    done < <(find "$cache_dir" -name "slideshow_processed_*" -mtime +1 -print0 2>/dev/null)
    
    info "Cleaned $cleaned cache files"
    echo
}

# Check system health
check_health() {
    log "=== Health Check ==="
    
    local issues=0
    
    # Check CPU temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp=$((temp / 1000))
        if [[ $temp -gt 80 ]]; then
            error "CPU temperature is critically high: ${temp}°C"
            ((issues++))
        fi
    fi
    
    # Check memory usage
    local mem_percent=$(free | grep "Mem:" | awk '{printf "%.0f", $3/$2 * 100.0}')
    if [[ $mem_percent -gt 90 ]]; then
        error "Memory usage is critically high: ${mem_percent}%"
        ((issues++))
    fi
    
    # Check disk usage
    local disk_percent=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_percent -gt 95 ]]; then
        error "Disk usage is critically high: ${disk_percent}%"
        ((issues++))
    elif [[ $disk_percent -gt 85 ]]; then
        warning "Disk usage is high: ${disk_percent}%"
    fi
    
    # Check if services are running
    local services=("slideshow-monitor" "slideshow-sync")
    for service in "${services[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
            warning "Service $service is not running"
            ((issues++))
        fi
    done
    
    # Check network connectivity
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        warning "Network connectivity issue detected"
        ((issues++))
    fi
    
    # Check rclone configuration
    if ! rclone listremotes | grep -q "gdrive:"; then
        warning "Google Drive remote not configured"
        ((issues++))
    fi
    
    if [[ $issues -eq 0 ]]; then
        info "✓ All health checks passed"
    else
        warning "Found $issues potential issues"
    fi
    
    echo
}

# Backup configuration
backup_config() {
    log "=== Backing up configuration ==="
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    local backup_file="$BACKUP_DIR/slideshow-config-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    # Create backup
    if tar -czf "$backup_file" -C "$(dirname "$SLIDESHOW_DIR")" \
        "$(basename "$SLIDESHOW_DIR")/config" \
        "$(basename "$SLIDESHOW_DIR")/*.py" \
        "$(basename "$SLIDESHOW_DIR")/scripts" 2>/dev/null; then
        info "Configuration backed up to: $backup_file"
        
        # Keep only last 5 backups
        ls -t "$BACKUP_DIR"/slideshow-config-*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f
    else
        error "Failed to create backup"
    fi
    
    echo
}

# Optimize system performance
optimize_system() {
    log "=== System Optimization ==="
    
    # Clear page cache
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches
        info "Cleared page cache"
    fi
    
    # Optimize GPU memory split (Raspberry Pi specific)
    local current_gpu_mem=$(vcgencmd get_mem gpu 2>/dev/null | cut -d= -f2 | sed 's/M//')
    if [[ -n "$current_gpu_mem" && "$current_gpu_mem" -gt 128 ]]; then
        warning "GPU memory allocation might be high for slideshow use: ${current_gpu_mem}M"
        info "Consider reducing GPU memory in /boot/config.txt: gpu_mem=64"
    fi
    
    echo
}

# Show slideshow statistics
show_stats() {
    log "=== Slideshow Statistics ==="
    
    # Count images
    local images_dir="$SLIDESHOW_DIR/images"
    if [[ -d "$images_dir" ]]; then
        local image_count=$(find "$images_dir" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" \) | wc -l)
        info "Total images: $image_count"
        
        # Image directory size
        local dir_size=$(du -sh "$images_dir" 2>/dev/null | cut -f1)
        info "Images directory size: $dir_size"
    else
        warning "Images directory not found: $images_dir"
    fi
    
    # Service uptime
    local services=("slideshow" "slideshow-monitor" "slideshow-sync")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            local uptime=$(systemctl show "$service" --property=ActiveEnterTimestamp --value)
            if [[ -n "$uptime" ]]; then
                local uptime_sec=$(( $(date +%s) - $(date -d "$uptime" +%s) ))
                local uptime_human=$(date -u -d @$uptime_sec +"%H:%M:%S" 2>/dev/null || echo "unknown")
                info "$service uptime: $uptime_human"
            fi
        fi
    done
    
    # Log file sizes
    if [[ -d "$LOG_DIR" ]]; then
        local total_log_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
        info "Total log size: $total_log_size"
    fi
    
    echo
}

# Main menu
show_menu() {
    echo
    echo "=========================================="
    echo "Raspberry Pi Slideshow Maintenance Menu"
    echo "=========================================="
    echo
    echo "1. Show system status"
    echo "2. Show service status" 
    echo "3. Show slideshow statistics"
    echo "4. Clean up log files"
    echo "5. Clean up cache files"
    echo "6. Run health check"
    echo "7. Backup configuration"
    echo "8. Optimize system"
    echo "9. Full maintenance (all tasks)"
    echo "10. Restart services"
    echo "0. Exit"
    echo
}

# Restart services
restart_services() {
    log "=== Restarting Services ==="
    
    local services=("slideshow" "slideshow-monitor" "slideshow-sync")
    
    for service in "${services[@]}"; do
        info "Restarting $service..."
        sudo systemctl restart "$service" || warning "Failed to restart $service"
    done
    
    sleep 2
    show_service_status
}

# Full maintenance
full_maintenance() {
    log "=== Running Full Maintenance ==="
    
    show_system_status
    show_service_status
    cleanup_logs
    cleanup_cache
    check_health
    backup_config
    optimize_system
    show_stats
    
    log "Full maintenance completed!"
}

# Main execution
main() {
    # Check if running with menu or specific task
    case "${1:-menu}" in
        "menu")
            while true; do
                show_menu
                read -p "Select option (0-10): " choice
                
                case $choice in
                    1) show_system_status ;;
                    2) show_service_status ;;
                    3) show_stats ;;
                    4) cleanup_logs ;;
                    5) cleanup_cache ;;
                    6) check_health ;;
                    7) backup_config ;;
                    8) optimize_system ;;
                    9) full_maintenance ;;
                    10) restart_services ;;
                    0) log "Goodbye!"; exit 0 ;;
                    *) error "Invalid option. Please try again." ;;
                esac
                
                echo
                read -p "Press Enter to continue..."
            done
            ;;
        "status") show_system_status; show_service_status; show_stats ;;
        "clean") cleanup_logs; cleanup_cache ;;
        "health") check_health ;;
        "backup") backup_config ;;
        "optimize") optimize_system ;;
        "restart") restart_services ;;
        "full") full_maintenance ;;
        *) 
            echo "Usage: $0 [menu|status|clean|health|backup|optimize|restart|full]"
            echo "  menu     - Interactive menu (default)"
            echo "  status   - Show system and service status"
            echo "  clean    - Clean up logs and cache"
            echo "  health   - Run health check"
            echo "  backup   - Backup configuration"
            echo "  optimize - Optimize system performance"
            echo "  restart  - Restart all services"
            echo "  full     - Run all maintenance tasks"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
