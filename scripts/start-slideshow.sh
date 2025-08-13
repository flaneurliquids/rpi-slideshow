#!/bin/bash

# Slideshow Startup Script
# Sets up environment and starts the slideshow application

set -e

# Configuration
SLIDESHOW_DIR="/home/pi/slideshow"
LOG_FILE="$SLIDESHOW_DIR/logs/startup.log"
PYTHON_VENV="$SLIDESHOW_DIR/venv"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log "Starting slideshow startup script..."

# Check if running in GUI environment
if [[ -z "$DISPLAY" ]]; then
    export DISPLAY=:0
    info "Set DISPLAY to $DISPLAY"
fi

# Wait for X server to be available
wait_for_xserver() {
    log "Waiting for X server to be available..."
    
    local max_wait=30
    local count=0
    
    while ! xset q >/dev/null 2>&1; do
        if [[ $count -ge $max_wait ]]; then
            error "X server not available after $max_wait seconds"
            return 1
        fi
        
        sleep 1
        ((count++))
    done
    
    log "X server is available"
    return 0
}

# Setup display environment
setup_display() {
    log "Setting up display environment..."
    
    # Disable screen saver and power management
    xset s off >/dev/null 2>&1 || info "Could not disable screensaver"
    xset -dpms >/dev/null 2>&1 || info "Could not disable power management"
    xset s noblank >/dev/null 2>&1 || info "Could not disable screen blanking"
    
    # Hide mouse cursor (install unclutter if not present)
    if command -v unclutter >/dev/null 2>&1; then
        unclutter -idle 1 -root &
        log "Started unclutter to hide mouse cursor"
    else
        info "unclutter not available, mouse cursor will be visible"
    fi
    
    # Set background to black
    if command -v xsetroot >/dev/null 2>&1; then
        xsetroot -solid black
        log "Set background to black"
    fi
}

# Kill existing processes that might interfere
cleanup_processes() {
    log "Cleaning up existing processes..."
    
    # Kill existing feh processes
    pkill -f "feh" >/dev/null 2>&1 || true
    
    # Kill existing Python slideshow processes
    pkill -f "slideshow.py" >/dev/null 2>&1 || true
    
    # Wait for processes to terminate
    sleep 2
    
    log "Process cleanup completed"
}

# Check system resources
check_resources() {
    log "Checking system resources..."
    
    # Check available memory
    local available_mem=$(free -m | awk 'NR==2{printf "%.0f", $7}')
    if [[ $available_mem -lt 100 ]]; then
        error "Low available memory: ${available_mem}MB"
        # Try to free some memory
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
    
    # Check CPU temperature (Raspberry Pi specific)
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
        temp=$((temp / 1000))
        if [[ $temp -gt 80 ]]; then
            error "High CPU temperature: ${temp}°C"
        else
            info "CPU temperature: ${temp}°C"
        fi
    fi
    
    # Check disk space
    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        error "High disk usage: ${disk_usage}%"
    else
        info "Disk usage: ${disk_usage}%"
    fi
}

# Verify slideshow directory and files
verify_installation() {
    log "Verifying slideshow installation..."
    
    if [[ ! -d "$SLIDESHOW_DIR" ]]; then
        error "Slideshow directory not found: $SLIDESHOW_DIR"
        return 1
    fi
    
    if [[ ! -f "$SLIDESHOW_DIR/slideshow.py" ]]; then
        error "Slideshow application not found: $SLIDESHOW_DIR/slideshow.py"
        return 1
    fi
    
    if [[ ! -d "$PYTHON_VENV" ]]; then
        error "Python virtual environment not found: $PYTHON_VENV"
        return 1
    fi
    
    if [[ ! -f "$SLIDESHOW_DIR/config/slideshow.conf" ]]; then
        error "Configuration file not found: $SLIDESHOW_DIR/config/slideshow.conf"
        return 1
    fi
    
    # Check if images directory exists and has images
    local images_dir="$SLIDESHOW_DIR/images"
    if [[ ! -d "$images_dir" ]]; then
        info "Images directory not found, creating: $images_dir"
        mkdir -p "$images_dir"
    fi
    
    local image_count=$(find "$images_dir" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" \) 2>/dev/null | wc -l)
    info "Found $image_count images in $images_dir"
    
    if [[ $image_count -eq 0 ]]; then
        info "No images found. The slideshow will wait for images to be synced."
    fi
    
    log "Installation verification completed"
    return 0
}

# Start the slideshow application
start_slideshow() {
    log "Starting slideshow application..."
    
    # Change to slideshow directory
    cd "$SLIDESHOW_DIR"
    
    # Activate Python virtual environment
    source "$PYTHON_VENV/bin/activate"
    
    # Start the slideshow
    exec python slideshow.py
}

# Main execution
main() {
    log "=== Slideshow Startup ==="
    
    # Basic checks
    if ! wait_for_xserver; then
        error "Cannot start slideshow without X server"
        exit 1
    fi
    
    if ! verify_installation; then
        error "Installation verification failed"
        exit 1
    fi
    
    # Setup environment
    setup_display
    cleanup_processes
    check_resources
    
    # Give a moment for cleanup to complete
    sleep 3
    
    # Start slideshow
    log "All checks passed, starting slideshow..."
    start_slideshow
}

# Handle signals
trap 'log "Slideshow startup script terminated"; exit 0' TERM INT

# Run main function
main "$@"
