#!/bin/bash

# Raspberry Pi Slideshow System Installer
# Installs all components for automated slideshow with Google Drive sync

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/home/pi/slideshow"
SERVICE_DIR="/etc/systemd/system"
USER="pi"

# Logging function
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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as pi user."
        error "If you need to run with sudo, the script will prompt when needed."
        exit 1
    fi
}

# Check if running on Raspberry Pi
check_pi() {
    if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        warning "Not running on a Raspberry Pi. Some features may not work correctly."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Update system packages
update_system() {
    log "Updating system packages..."
    
    # Update package lists
    if ! sudo apt update; then
        error "Failed to update package lists"
        exit 1
    fi
    
    # Try to upgrade packages, but don't fail if kernel updates have issues
    log "Upgrading system packages (may take several minutes)..."
    if ! sudo apt upgrade -y; then
        warning "System upgrade encountered errors. This is often related to kernel updates."
        warning "Attempting to fix broken packages..."
        
        # Try to fix broken packages
        sudo apt --fix-broken install -y
        sudo dpkg --configure -a
        
        # Clean package cache
        sudo apt clean
        sudo apt autoclean
        
        # Try upgrade again with less strict error handling
        if ! sudo apt upgrade -y --fix-missing; then
            warning "Some package updates failed. Continuing with installation..."
            warning "You may need to run 'sudo apt upgrade' manually after installation."
        else
            log "Package issues resolved successfully"
        fi
    else
        log "System upgrade completed successfully"
    fi
}

# Install required packages
install_packages() {
    log "Installing required packages..."
    
    # Essential packages for slideshow
    local packages=(
        "python3"
        "python3-pip"
        "python3-venv"
        "feh"                    # Lightweight image viewer
        "imagemagick"            # Image processing
        "curl"                   # For downloading rclone
        "unzip"                  # For extracting rclone
        "inotify-tools"          # For file monitoring
        "xorg"                   # X server for display
        "xinit"                  # X initialization
        "x11-xserver-utils"      # X server utilities
        "matchbox-window-manager" # Minimal window manager
        "chromium-browser"       # For web-based monitoring (optional)
    )
    
    for package in "${packages[@]}"; do
        info "Installing $package..."
        sudo apt install -y "$package" || warning "Failed to install $package"
    done
}

# Install rclone for Google Drive sync
install_rclone() {
    log "Installing rclone..."
    
    if command -v rclone >/dev/null 2>&1; then
        info "rclone is already installed"
        return
    fi
    
    cd /tmp
    curl https://rclone.org/install.sh | sudo bash
    
    if command -v rclone >/dev/null 2>&1; then
        log "rclone installed successfully"
    else
        error "Failed to install rclone"
        exit 1
    fi
}

# Create directory structure
create_directories() {
    log "Creating directory structure..."
    
    sudo mkdir -p "$INSTALL_DIR"/{images,logs,config,scripts}
    sudo chown -R $USER:$USER "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    
    # Create systemd log directory
    sudo mkdir -p /var/log/slideshow
    sudo chown $USER:$USER /var/log/slideshow
}

# Copy application files
copy_files() {
    log "Copying application files..."
    
    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Copy source files
    if [[ -d "$SCRIPT_DIR/src" ]]; then
        cp -r "$SCRIPT_DIR/src"/* "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR"/*.py
    fi
    
    # Copy configuration files
    if [[ -d "$SCRIPT_DIR/config" ]]; then
        cp -r "$SCRIPT_DIR/config"/* "$INSTALL_DIR/config/"
    fi
    
    # Copy scripts
    if [[ -d "$SCRIPT_DIR/scripts" ]]; then
        cp -r "$SCRIPT_DIR/scripts"/* "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts"/*.sh
    fi
    
    # Copy service files
    if [[ -d "$SCRIPT_DIR/services" ]]; then
        sudo cp "$SCRIPT_DIR/services"/*.service "$SERVICE_DIR/"
    fi
}

# Install Python dependencies
install_python_deps() {
    log "Installing Python dependencies..."
    
    # Create virtual environment
    cd "$INSTALL_DIR"
    python3 -m venv venv
    source venv/bin/activate
    
    # Install required packages
    pip install --upgrade pip
    pip install \
        pillow \
        watchdog \
        psutil \
        requests \
        configparser \
        python-daemon
        
    deactivate
}

# Configure X11 for auto-login and slideshow
configure_x11() {
    log "Configuring X11 for automatic slideshow..."
    
    # Enable auto-login for pi user
    sudo systemctl set-default graphical.target
    
    # Configure automatic X11 startup
    cat > /home/pi/.xinitrc << 'EOF'
#!/bin/bash
# Start window manager
matchbox-window-manager -use_cursor no -use_titlebar no &

# Disable screen saver and power management
xset s off
xset -dpms
xset s noblank

# Hide cursor after 1 second of inactivity
unclutter -idle 1 &

# Start slideshow
/home/pi/slideshow/scripts/start-slideshow.sh
EOF

    chmod +x /home/pi/.xinitrc
    
    # Configure auto-startx in .profile
    if ! grep -q "startx" /home/pi/.profile; then
        echo "" >> /home/pi/.profile
        echo "# Auto-start X11 for slideshow" >> /home/pi/.profile
        echo "if [ -z \"\$DISPLAY\" ] && [ \"\$(tty)\" = \"/dev/tty1\" ]; then" >> /home/pi/.profile
        echo "    startx" >> /home/pi/.profile
        echo "fi" >> /home/pi/.profile
    fi
}

# Setup systemd services
setup_services() {
    log "Setting up systemd services..."
    
    # Reload systemd daemon
    sudo systemctl daemon-reload
    
    # Enable services (but don't start them yet)
    sudo systemctl enable slideshow-monitor.service
    sudo systemctl enable slideshow-sync.service
    
    info "Services configured but not started. Use 'sudo systemctl start slideshow' after setup is complete."
}

# Setup Google Drive (interactive)
setup_google_drive() {
    log "Setting up Google Drive sync..."
    
    echo
    echo "=========================================="
    echo "Google Drive Configuration"
    echo "=========================================="
    echo
    echo "You need to configure rclone to access your Google Drive."
    echo "This requires a web browser for authentication."
    echo
    read -p "Do you want to configure Google Drive sync now? (Y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        warning "Skipping Google Drive setup. You can run it later with:"
        warning "  $INSTALL_DIR/scripts/setup-rclone.sh"
        return
    fi
    
    # Run rclone config
    info "Starting rclone configuration..."
    echo "When prompted:"
    echo "1. Choose 'n' for new remote"
    echo "2. Name it 'gdrive'"
    echo "3. Choose 'drive' for Google Drive"
    echo "4. Leave client_id and client_secret blank"
    echo "5. Choose '1' for full access"
    echo "6. Leave root_folder_id blank"
    echo "7. Leave service_account_file blank"
    echo "8. Choose 'n' for advanced config"
    echo "9. Choose 'y' for auto config (opens browser)"
    echo "10. Choose 'n' for team drive"
    echo "11. Choose 'y' to confirm"
    echo
    read -p "Press Enter to continue..."
    
    rclone config
    
    # Test the configuration
    info "Testing Google Drive connection..."
    if rclone lsd gdrive: >/dev/null 2>&1; then
        log "Google Drive connection successful!"
    else
        error "Google Drive connection failed. Please run setup again."
        exit 1
    fi
}

# Create sample configuration
create_config() {
    log "Creating configuration files..."
    
    # Create main config if it doesn't exist
    if [[ ! -f "$INSTALL_DIR/config/slideshow.conf" ]]; then
        cat > "$INSTALL_DIR/config/slideshow.conf" << 'EOF'
[slideshow]
# Local directory containing images
images_dir = /home/pi/slideshow/images
# Display duration per image (seconds)
display_duration = 10
# Supported image formats
supported_formats = jpg,jpeg,png,gif
# Slideshow transition effect
transition = fade
# Enable random order
random_order = true

[sync]
# Google Drive remote name (configured with rclone)
remote_name = gdrive
# Remote directory path (empty for root)
remote_path = slideshow
# Sync interval in minutes
sync_interval = 10
# Enable bidirectional sync
bidirectional = true
# Bandwidth limit (empty for unlimited)
bandwidth_limit = 

[monitor]
# File monitoring interval (seconds)
check_interval = 10
# Enable recursive monitoring
recursive = true
# Restart delay after changes (seconds)
restart_delay = 5

[logging]
# Log directory
log_dir = /home/pi/slideshow/logs
# Log level (DEBUG, INFO, WARNING, ERROR)
log_level = INFO
# Enable log rotation
log_rotation = true
# Max log file size (MB)
max_log_size = 10
# Number of backup log files
backup_count = 5

[display]
# Display number (0 for primary)
display = 0
# Enable fullscreen
fullscreen = true
# Background color (hex)
background_color = #000000
# Enable image scaling
scale_images = true
# Image fit mode (contain, cover, fill)
fit_mode = contain
EOF
    fi
    
    log "Configuration files created in $INSTALL_DIR/config/"
}

# Final setup and instructions
final_setup() {
    log "Performing final setup..."
    
    # Set correct permissions
    sudo chown -R $USER:$USER "$INSTALL_DIR"
    find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \;
    find "$INSTALL_DIR" -name "*.py" -exec chmod +x {} \;
    
    # Create some sample images directory structure
    mkdir -p "$INSTALL_DIR/images"
    
    echo
    echo "=========================================="
    echo "Installation Complete!"
    echo "=========================================="
    echo
    log "Raspberry Pi Slideshow system has been installed successfully!"
    echo
    echo "Directory: $INSTALL_DIR"
    echo "Services installed:"
    echo "  - slideshow-monitor.service (file monitoring)"
    echo "  - slideshow-sync.service (Google Drive sync)"
    echo "  - slideshow.service (main slideshow)"
    echo
    echo "Next steps:"
    echo "1. Add images to: $INSTALL_DIR/images/"
    echo "2. Or sync from Google Drive: sudo systemctl start slideshow-sync"
    echo "3. Start the slideshow: sudo systemctl start slideshow"
    echo "4. Enable auto-start: sudo systemctl enable slideshow"
    echo
    echo "View logs:"
    echo "  tail -f $INSTALL_DIR/logs/*.log"
    echo
    echo "Configuration:"
    echo "  Edit $INSTALL_DIR/config/slideshow.conf"
    echo
    echo "Reboot recommended to ensure all services start correctly."
}

# Main installation process
main() {
    echo
    echo "=========================================="
    echo "Raspberry Pi Slideshow System Installer"
    echo "=========================================="
    echo
    
    check_root
    check_pi
    
    log "Starting installation..."
    
    update_system
    install_packages
    install_rclone
    create_directories
    copy_files
    install_python_deps
    configure_x11
    create_config
    setup_services
    setup_google_drive
    final_setup
    
    log "Installation completed successfully!"
    echo
    echo "Reboot now? (recommended)"
    read -p "Reboot? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sudo reboot
    fi
}

# Run main function
main "$@"
