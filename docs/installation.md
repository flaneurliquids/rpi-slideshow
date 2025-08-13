# Installation Guide

Complete step-by-step installation guide for the Raspberry Pi Slideshow system.

## Prerequisites

### Hardware Requirements
- Raspberry Pi 3B+ or newer (4GB RAM recommended)
- MicroSD card (16GB or larger, Class 10 recommended)
- HDMI cable for TV/monitor connection
- Reliable internet connection (WiFi or Ethernet)
- USB keyboard for initial setup (optional after setup)

### Software Requirements
- Raspberry Pi OS (Lite or Desktop)
- SSH enabled (for remote management)
- Internet connection for downloading packages

## Step 1: Prepare Raspberry Pi OS

### Flash SD Card
1. Download [Raspberry Pi Imager](https://rpi.org/imager)
2. Flash Raspberry Pi OS to SD card
3. Enable SSH and configure WiFi using the imager's advanced options
4. Insert SD card and boot the Pi

### Initial Setup
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Enable SSH (if not done during imaging)
sudo systemctl enable ssh
sudo systemctl start ssh

# Set up WiFi (if using command line)
sudo raspi-config
# Navigate to: Network Options > Wi-Fi
```

## Step 2: Download and Install

### Method 1: Automated Installation (Recommended)
```bash
# Download and run installation script
curl -sSL https://raw.githubusercontent.com/yourusername/rpi-slideshow/main/install.sh | bash
```

### Method 2: Manual Installation
```bash
# Clone repository
git clone https://github.com/yourusername/rpi-slideshow.git
cd rpi-slideshow

# Make script executable and run
chmod +x install.sh
./install.sh
```

## Step 3: Configuration

### Google Drive Setup
The installation script will prompt you to configure Google Drive access. You can also run this separately:

```bash
/home/pi/slideshow/scripts/setup-rclone.sh
```

Follow the prompts to:
1. Create a new remote called 'gdrive'
2. Authenticate with your Google account
3. Grant necessary permissions
4. Test the connection

### Configuration File
Edit the main configuration file:
```bash
nano /home/pi/slideshow/config/slideshow.conf
```

Key settings to review:
- `display_duration`: Seconds per image (default: 10)
- `sync_interval`: Minutes between syncs (default: 10)
- `random_order`: Randomize image order (default: true)
- `remote_path`: Google Drive folder name (default: slideshow)

## Step 4: Service Management

### Enable Services
```bash
# Enable auto-start
sudo systemctl enable slideshow-monitor.service
sudo systemctl enable slideshow-sync.service
sudo systemctl enable slideshow.service

# Start services
sudo systemctl start slideshow-sync
sudo systemctl start slideshow-monitor
sudo systemctl start slideshow
```

### Check Status
```bash
# Check service status
sudo systemctl status slideshow
sudo systemctl status slideshow-monitor
sudo systemctl status slideshow-sync

# View logs
tail -f /home/pi/slideshow/logs/slideshow.log
tail -f /home/pi/slideshow/logs/sync.log
tail -f /home/pi/slideshow/logs/monitor.log
```

## Step 5: Add Images

### Upload to Google Drive
1. Open Google Drive in your web browser
2. Create a folder named 'slideshow' (or whatever you configured)
3. Upload your images to this folder
4. Wait for sync (up to 10 minutes)

### Add Images Locally
```bash
# Copy images directly
cp /path/to/your/images/* /home/pi/slideshow/images/

# Or use USB drive
sudo mount /dev/sda1 /mnt
cp /mnt/*.jpg /home/pi/slideshow/images/
sudo umount /mnt
```

## Step 6: Auto-Start Configuration

### Boot to Desktop (GUI Method)
```bash
# Set boot target to desktop
sudo systemctl set-default graphical.target

# Configure auto-login
sudo raspi-config
# Navigate to: System Options > Boot / Auto Login > Desktop Autologin
```

### Boot to Console (Headless Method)
The installation script configures automatic X11 startup for the pi user. This happens via:
- `.xinitrc` configuration
- `.profile` modification for auto-startx

## Troubleshooting Common Issues

### Display Issues
```bash
# Check X11 is running
echo $DISPLAY
xset q

# Restart X11
sudo systemctl restart lightdm
```

### Service Issues
```bash
# View detailed service status
systemctl status slideshow.service -l

# Restart problematic service
sudo systemctl restart slideshow

# Check journalctl logs
journalctl -u slideshow -f
```

### Network Issues
```bash
# Test network connectivity
ping google.com

# Check WiFi status
iwconfig

# Restart networking
sudo systemctl restart networking
```

### Google Drive Sync Issues
```bash
# Test rclone manually
rclone lsd gdrive:

# Reconfigure if needed
rclone config

# Check sync logs
tail -f /home/pi/slideshow/logs/sync.log
```

## Performance Optimization

### GPU Memory Split
For better performance, optimize GPU memory allocation:
```bash
sudo nano /boot/config.txt
# Add or modify:
gpu_mem=64
```

### Disable Unnecessary Services
```bash
# Disable Bluetooth if not needed
sudo systemctl disable bluetooth

# Disable audio if not needed
sudo systemctl disable alsa-state
```

### SD Card Optimization
```bash
# Reduce writes to SD card
echo 'tmpfs /tmp tmpfs defaults,noatime,nosuid,size=100m 0 0' | sudo tee -a /etc/fstab
echo 'tmpfs /var/tmp tmpfs defaults,noatime,nosuid,size=30m 0 0' | sudo tee -a /etc/fstab
```

## Security Considerations

### Change Default Password
```bash
passwd
# Enter new password
```

### Configure Firewall (Optional)
```bash
sudo ufw enable
sudo ufw allow ssh
sudo ufw allow from 192.168.1.0/24  # Allow local network
```

### Regular Updates
```bash
# Set up automatic updates
sudo apt install unattended-upgrades
sudo dpkg-reconfigure unattended-upgrades
```

## Maintenance

### Regular Maintenance Script
The system includes a maintenance script:
```bash
# Interactive maintenance menu
/home/pi/slideshow/scripts/maintenance.sh

# Quick status check
/home/pi/slideshow/scripts/maintenance.sh status

# Full maintenance
/home/pi/slideshow/scripts/maintenance.sh full
```

### Backup Configuration
```bash
# Backup current configuration
/home/pi/slideshow/scripts/maintenance.sh backup
```

## Next Steps

After successful installation:

1. **Upload Images**: Add your photos to Google Drive
2. **Test System**: Verify slideshow is working
3. **Configure Display**: Adjust timing and display settings
4. **Set Up Remote Access**: Configure SSH and VNC if needed
5. **Schedule Maintenance**: Set up cron jobs for regular maintenance

## Support

If you encounter issues:

1. Check the [Troubleshooting Guide](troubleshooting.md)
2. Review log files in `/home/pi/slideshow/logs/`
3. Run the maintenance script for health checks
4. Check service status with `systemctl status`

For additional help, please refer to the project documentation or create an issue in the repository.
