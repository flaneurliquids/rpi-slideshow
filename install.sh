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
USER="$(whoami)"
INSTALL_DIR="/home/$USER/slideshow"
SERVICE_DIR="/etc/systemd/system"

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
    
    # Download files from GitHub if not running from cloned repo
    if [[ ! -d "$SCRIPT_DIR/src" ]]; then
        download_from_github
    fi
    
    # Copy source files
    if [[ -d "$SCRIPT_DIR/src" ]]; then
        cp -r "$SCRIPT_DIR/src"/* "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR"/*.py
    else
        create_python_files
    fi
    
    # Copy configuration files
    if [[ -d "$SCRIPT_DIR/config" ]]; then
        cp -r "$SCRIPT_DIR/config"/* "$INSTALL_DIR/config/"
    fi
    
    # Copy scripts
    if [[ -d "$SCRIPT_DIR/scripts" ]]; then
        cp -r "$SCRIPT_DIR/scripts"/* "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts"/*.sh
    else
        create_scripts
    fi
    
    # Copy or create service files
    if [[ -d "$SCRIPT_DIR/services" ]]; then
        sudo cp "$SCRIPT_DIR/services"/*.service "$SERVICE_DIR/"
    else
        create_service_files
    fi
}

# Download files from GitHub
download_from_github() {
    log "Downloading files from GitHub..."
    
    local repo_url="https://api.github.com/repos/flaneurliquids/rpi-slideshow"
    local temp_dir="/tmp/rpi-slideshow-$$"
    
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # Download and extract repository
    if curl -sL "https://github.com/flaneurliquids/rpi-slideshow/archive/main.tar.gz" | tar xz; then
        mv rpi-slideshow-main/* "$SCRIPT_DIR/" 2>/dev/null || true
        log "Files downloaded successfully"
    else
        warning "Failed to download from GitHub, will create files manually"
    fi
    
    cd - >/dev/null
    rm -rf "$temp_dir"
}

# Create Python files manually if download failed
create_python_files() {
    warning "Creating Python files manually (GitHub download failed)"
    # For now, we'll skip this and rely on the service creation
}

# Create scripts manually
create_scripts() {
    log "Creating essential scripts..."
    
    mkdir -p "$INSTALL_DIR/scripts"
    
    # Create basic start script
    cat > "$INSTALL_DIR/scripts/start-slideshow.sh" << EOF
#!/bin/bash
cd $INSTALL_DIR
source venv/bin/activate
export DISPLAY=:0
python slideshow.py
EOF
    
    chmod +x "$INSTALL_DIR/scripts/start-slideshow.sh"
}

# Create service files directly
create_service_files() {
    log "Creating systemd service files..."
    
    # Slideshow service
    sudo tee "$SERVICE_DIR/slideshow.service" > /dev/null << EOF
[Unit]
Description=Raspberry Pi Slideshow
After=graphical-session.target network.target
Wants=graphical-session.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$INSTALL_DIR
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStartPre=/bin/sleep 10
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/slideshow.py
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical-session.target
EOF

    # Monitor service
    sudo tee "$SERVICE_DIR/slideshow-monitor.service" > /dev/null << EOF
[Unit]
Description=Slideshow File Monitor
After=multi-user.target
Wants=slideshow.service

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Sync service
    sudo tee "$SERVICE_DIR/slideshow-sync.service" > /dev/null << EOF
[Unit]
Description=Slideshow Google Drive Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/sync.py
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log "Service files created successfully"
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
    
    # Enable auto-login for current user
    sudo systemctl set-default graphical.target
    
    # Configure automatic X11 startup
    cat > "/home/$USER/.xinitrc" << EOF
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
$INSTALL_DIR/scripts/start-slideshow.sh
EOF

    chmod +x "/home/$USER/.xinitrc"
    
    # Configure auto-startx in .profile
    if ! grep -q "startx" "/home/$USER/.profile"; then
        echo "" >> "/home/$USER/.profile"
        echo "# Auto-start X11 for slideshow" >> "/home/$USER/.profile"
        echo 'if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then' >> "/home/$USER/.profile"
        echo "    startx" >> "/home/$USER/.profile"
        echo "fi" >> "/home/$USER/.profile"
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
    echo "Choose your Google Drive sync method:"
    echo
    echo "1. Simple Method (Recommended)"
    echo "   - Uses a public folder link (no authentication required)"
    echo "   - Just share your folder with 'Anyone with the link'"
    echo "   - Much easier to set up"
    echo
    echo "2. rclone Method (Advanced)"
    echo "   - Requires OAuth authentication"
    echo "   - Supports private folders and bidirectional sync"
    echo "   - More complex setup"
    echo
    read -p "Choose method (1 for Simple, 2 for rclone, or N to skip): " -n 1 -r
    echo
    
    case $REPLY in
        1)
            setup_simple_sync
            ;;
        2)
            setup_rclone_sync
            ;;
        [Nn])
            warning "Skipping Google Drive setup. You can configure it later by editing:"
            warning "  $INSTALL_DIR/config/slideshow.conf"
            ;;
        *)
            warning "Invalid choice. Skipping Google Drive setup."
            ;;
    esac
}

# Setup simple sync method
setup_simple_sync() {
    log "Setting up simple Google Drive sync..."
    
    echo
    echo "To use the simple sync method:"
    echo "1. Create a folder in your Google Drive"
    echo "2. Upload your images to this folder"
    echo "3. Right-click the folder → Share → 'Anyone with the link'"
    echo "4. Copy the folder URL"
    echo
    read -p "Do you have a public Google Drive folder URL ready? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        read -p "Enter your Google Drive folder URL: " folder_url
        
        if [[ -n "$folder_url" ]]; then
            # Update config file with the URL
            sed -i "s|^public_folder_url = .*|public_folder_url = $folder_url|" "$INSTALL_DIR/config/slideshow.conf"
            sed -i "s|^sync_method = .*|sync_method = simple|" "$INSTALL_DIR/config/slideshow.conf"
            
            log "✓ Simple sync configured with your folder URL"
            info "Your images will be synced from: $folder_url"
        else
            warning "No URL provided. You can add it later in the config file."
        fi
    else
        info "You can configure the folder URL later by editing:"
        info "  $INSTALL_DIR/config/slideshow.conf"
        info "Just add your public folder URL to the 'public_folder_url' setting"
    fi
}

# Setup rclone sync method
setup_rclone_sync() {
    log "Setting up rclone Google Drive sync..."
    
    echo
    echo "This method requires OAuth authentication and a web browser."
    read -p "Continue with rclone setup? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Update config to use rclone method
    sed -i "s|^sync_method = .*|sync_method = rclone|" "$INSTALL_DIR/config/slideshow.conf"
    
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
        log "✓ rclone Google Drive connection successful!"
    else
        error "rclone Google Drive connection failed. Please run setup again."
        exit 1
    fi
}

# Create sample configuration
create_config() {
    log "Creating configuration files..."
    
    # Create main config if it doesn't exist
    if [[ ! -f "$INSTALL_DIR/config/slideshow.conf" ]]; then
        cat > "$INSTALL_DIR/config/slideshow.conf" << EOF
[slideshow]
# Local directory containing images
images_dir = $INSTALL_DIR/images
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
log_dir = $INSTALL_DIR/logs
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
