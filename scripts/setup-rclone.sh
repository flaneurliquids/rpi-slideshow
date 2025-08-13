#!/bin/bash

# Google Drive Setup Script for Raspberry Pi Slideshow
# Configures rclone for Google Drive access

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
REMOTE_NAME="gdrive"
REMOTE_FOLDER="slideshow"

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        error "rclone is not installed. Please install it first:"
        echo "  curl https://rclone.org/install.sh | sudo bash"
        exit 1
    fi
    
    log "rclone is installed: $(rclone version | head -1)"
}

check_existing_config() {
    if rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
        warning "Remote '${REMOTE_NAME}' already exists."
        echo
        read -p "Do you want to reconfigure it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Keeping existing configuration."
            return 0
        fi
        
        log "Deleting existing remote..."
        rclone config delete "$REMOTE_NAME"
    fi
    return 1
}

setup_google_drive() {
    log "Setting up Google Drive remote..."
    
    echo
    echo "=========================================="
    echo "Google Drive Configuration"
    echo "=========================================="
    echo
    echo "This will guide you through setting up Google Drive access."
    echo "You'll need:"
    echo "1. A web browser (can be on another device)"
    echo "2. Your Google account credentials"
    echo "3. Internet connection"
    echo
    read -p "Press Enter to continue..."
    
    echo
    info "Starting rclone configuration..."
    echo
    echo "Follow these steps in the rclone configuration:"
    echo "1. Choose 'n' for new remote"
    echo "2. Name: $REMOTE_NAME"
    echo "3. Choose 'drive' for Google Drive"
    echo "4. Leave client_id blank (just press Enter)"
    echo "5. Leave client_secret blank (just press Enter)"
    echo "6. Choose '1' for full access"
    echo "7. Leave root_folder_id blank (just press Enter)"
    echo "8. Leave service_account_file blank (just press Enter)"
    echo "9. Choose 'n' for advanced config"
    echo "10. Choose 'y' for auto config (will open browser)"
    echo "11. Choose 'n' for team drive"
    echo "12. Choose 'y' to confirm configuration"
    echo
    read -p "Press Enter to start configuration..."
    
    # Run rclone config
    if ! rclone config; then
        error "rclone configuration failed"
        exit 1
    fi
}

test_connection() {
    log "Testing Google Drive connection..."
    
    if rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        log "✓ Google Drive connection successful!"
    else
        error "✗ Google Drive connection failed!"
        echo "Please check your configuration and try again."
        return 1
    fi
}

create_remote_folder() {
    log "Creating remote slideshow folder..."
    
    # Check if folder exists
    if rclone lsf "${REMOTE_NAME}:" | grep -q "^${REMOTE_FOLDER}/\$"; then
        info "Remote folder '${REMOTE_FOLDER}' already exists."
        return 0
    fi
    
    # Create folder
    if rclone mkdir "${REMOTE_NAME}:${REMOTE_FOLDER}"; then
        log "✓ Created remote folder '${REMOTE_FOLDER}'"
    else
        warning "Could not create remote folder '${REMOTE_FOLDER}'"
        echo "You may need to create it manually in Google Drive."
    fi
}

upload_sample_images() {
    echo
    read -p "Do you want to upload some sample images? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi
    
    # Create temporary sample images
    log "Creating sample images..."
    temp_dir="/tmp/slideshow_samples"
    mkdir -p "$temp_dir"
    
    # Create simple colored rectangles as sample images
    for i in {1..3}; do
        # Use ImageMagick to create sample images if available
        if command -v convert >/dev/null 2>&1; then
            case $i in
                1) color="red" ;;
                2) color="green" ;;
                3) color="blue" ;;
            esac
            
            convert -size 1920x1080 "xc:$color" -pointsize 72 -fill white \
                -gravity center -annotate 0 "Sample Image $i\n$color" \
                "$temp_dir/sample_$i.jpg"
        else
            # Create placeholder files if ImageMagick not available
            echo "Sample Image $i" > "$temp_dir/sample_$i.txt"
        fi
    done
    
    # Upload samples
    log "Uploading sample images..."
    if rclone copy "$temp_dir" "${REMOTE_NAME}:${REMOTE_FOLDER}/samples/"; then
        log "✓ Sample images uploaded successfully"
    else
        warning "Could not upload sample images"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

show_next_steps() {
    echo
    echo "=========================================="
    echo "Setup Complete!"
    echo "=========================================="
    echo
    log "Google Drive sync is now configured!"
    echo
    echo "Configuration summary:"
    echo "  Remote name: $REMOTE_NAME"
    echo "  Remote folder: $REMOTE_FOLDER"
    echo "  Local folder: /home/pi/slideshow/images"
    echo
    echo "Next steps:"
    echo "1. Upload images to Google Drive folder: $REMOTE_FOLDER"
    echo "2. Start the sync service: sudo systemctl start slideshow-sync"
    echo "3. Enable auto-start: sudo systemctl enable slideshow-sync"
    echo "4. Check sync logs: tail -f /home/pi/slideshow/logs/slideshow-sync.log"
    echo
    echo "Useful commands:"
    echo "  Manual sync: rclone sync ${REMOTE_NAME}:${REMOTE_FOLDER} /home/pi/slideshow/images"
    echo "  List remote files: rclone ls ${REMOTE_NAME}:${REMOTE_FOLDER}"
    echo "  Check sync status: systemctl status slideshow-sync"
    echo
}

main() {
    echo
    echo "=========================================="
    echo "Raspberry Pi Slideshow - Google Drive Setup"
    echo "=========================================="
    echo
    
    check_rclone
    
    if check_existing_config; then
        log "Using existing Google Drive configuration."
    else
        setup_google_drive
    fi
    
    test_connection
    create_remote_folder
    upload_sample_images
    show_next_steps
    
    log "Google Drive setup completed successfully!"
}

# Run main function
main "$@"
