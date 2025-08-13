# Troubleshooting Guide

This guide helps you diagnose and fix common issues with the Raspberry Pi Slideshow system.

## Quick Diagnostics

### Check System Status
```bash
# Run maintenance script for overall status
/home/pi/slideshow/scripts/maintenance.sh status

# Check all services
sudo systemctl status slideshow slideshow-monitor slideshow-sync
```

### View Logs
```bash
# Monitor live logs
tail -f /home/pi/slideshow/logs/*.log

# Check specific logs
journalctl -u slideshow -f
journalctl -u slideshow-monitor -f
journalctl -u slideshow-sync -f
```

## Common Issues

### 1. Slideshow Not Starting

#### Symptoms
- Black screen or no display
- Service shows as inactive
- Error in slideshow.log

#### Diagnosis
```bash
# Check service status
sudo systemctl status slideshow

# Check X11 display
echo $DISPLAY
xset q

# Verify installation
ls -la /home/pi/slideshow/
```

#### Solutions

**X11 Not Available:**
```bash
# Start X11 manually
startx

# Or restart display manager
sudo systemctl restart lightdm

# Check if running in console mode
who am i
```

**Missing Dependencies:**
```bash
# Reinstall required packages
sudo apt install feh python3-pil imagemagick

# Recreate Python environment
cd /home/pi/slideshow
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install pillow watchdog psutil
```

**Permission Issues:**
```bash
# Fix file permissions
sudo chown -R pi:pi /home/pi/slideshow
chmod +x /home/pi/slideshow/*.py
chmod +x /home/pi/slideshow/scripts/*.sh
```

### 2. No Images Displayed

#### Symptoms
- Slideshow starts but shows blank screen
- "No images found" in logs
- Slideshow waiting for images

#### Diagnosis
```bash
# Check images directory
ls -la /home/pi/slideshow/images/
find /home/pi/slideshow/images/ -name "*.jpg" -o -name "*.png"

# Check supported formats
grep "supported_formats" /home/pi/slideshow/config/slideshow.conf
```

#### Solutions

**No Images in Directory:**
```bash
# Add test images manually
cp /usr/share/pixmaps/*.png /home/pi/slideshow/images/

# Force sync from Google Drive
sudo systemctl restart slideshow-sync
rclone sync gdrive:slideshow /home/pi/slideshow/images/
```

**Wrong File Formats:**
```bash
# Convert images to supported format
mogrify -format jpg /home/pi/slideshow/images/*.bmp
mogrify -format jpg /home/pi/slideshow/images/*.tiff
```

**File Permissions:**
```bash
# Fix file permissions
sudo chown -R pi:pi /home/pi/slideshow/images/
chmod 644 /home/pi/slideshow/images/*
```

### 3. Google Drive Sync Not Working

#### Symptoms
- Sync service inactive or failing
- Images not downloading from Drive
- Authentication errors in sync.log

#### Diagnosis
```bash
# Test rclone manually
rclone lsd gdrive:
rclone ls gdrive:slideshow

# Check rclone config
rclone config show gdrive
```

#### Solutions

**Authentication Issues:**
```bash
# Reconfigure Google Drive
rclone config delete gdrive
rclone config
# Follow setup prompts

# Or run setup script
/home/pi/slideshow/scripts/setup-rclone.sh
```

**Network Issues:**
```bash
# Test connectivity
ping google.com
curl -I https://drive.google.com

# Check proxy settings (if applicable)
echo $HTTP_PROXY
echo $HTTPS_PROXY
```

**Quota/Rate Limiting:**
```bash
# Check sync logs for quota messages
grep -i "quota\|limit\|rate" /home/pi/slideshow/logs/sync.log

# Increase sync interval
sed -i 's/sync_interval = 10/sync_interval = 30/' /home/pi/slideshow/config/slideshow.conf
sudo systemctl restart slideshow-sync
```

### 4. High CPU/Memory Usage

#### Symptoms
- System sluggish
- High temperature warnings
- Services crashing due to memory

#### Diagnosis
```bash
# Check system resources
top
htop
free -h
df -h

# Check temperature
vcgencmd measure_temp
cat /sys/class/thermal/thermal_zone0/temp
```

#### Solutions

**Reduce Image Processing:**
```bash
# Edit config to reduce cache and preloading
nano /home/pi/slideshow/config/slideshow.conf
# Set: enable_cache = false
# Set: preload_count = 0
# Set: memory_limit = 512
```

**Optimize Images:**
```bash
# Reduce image sizes
cd /home/pi/slideshow/images/
mogrify -resize 1920x1080 -quality 85 *.jpg
```

**Increase GPU Memory:**
```bash
sudo nano /boot/config.txt
# Add or modify: gpu_mem=128
sudo reboot
```

### 5. Display Issues

#### Symptoms
- Wrong resolution or aspect ratio
- Images not filling screen
- Display flickering

#### Diagnosis
```bash
# Check current resolution
xrandr
tvservice -s

# Check config
grep -E "resolution|fit_mode|fullscreen" /home/pi/slideshow/config/slideshow.conf
```

#### Solutions

**Force Display Resolution:**
```bash
sudo nano /boot/config.txt
# Add:
# hdmi_force_hotplug=1
# hdmi_group=1
# hdmi_mode=16  # 1080p 60Hz
sudo reboot
```

**Fix Aspect Ratio:**
```bash
# Edit slideshow config
nano /home/pi/slideshow/config/slideshow.conf
# Change fit_mode:
# contain = letterbox (maintains aspect ratio)
# cover = crop to fill screen
# fill = stretch to fill screen
```

**Disable Overscan:**
```bash
sudo nano /boot/config.txt
# Set: disable_overscan=1
sudo reboot
```

### 6. Services Keep Restarting

#### Symptoms
- High restart count in systemctl status
- Services constantly failing and restarting
- System unstable

#### Diagnosis
```bash
# Check restart counts
systemctl show slideshow --property=NRestarts
systemctl show slideshow-sync --property=NRestarts

# Check failure reasons
journalctl -u slideshow --since "1 hour ago"
```

#### Solutions

**Memory Issues:**
```bash
# Increase service memory limits
sudo nano /etc/systemd/system/slideshow.service
# Change: MemoryLimit=2G
sudo systemctl daemon-reload
sudo systemctl restart slideshow
```

**Configuration Errors:**
```bash
# Validate config file
python3 -c "
import configparser
config = configparser.ConfigParser()
config.read('/home/pi/slideshow/config/slideshow.conf')
print('Config is valid')
"
```

**Dependency Issues:**
```bash
# Rebuild Python environment
cd /home/pi/slideshow
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 7. Remote Access Issues

#### Symptoms
- Can't SSH to Pi
- VNC not working
- Web interface not accessible

#### Solutions

**SSH Issues:**
```bash
# Check SSH service (on Pi directly)
sudo systemctl status ssh
sudo systemctl start ssh

# Check network connectivity
ip addr show
ping gateway_ip
```

**Firewall Issues:**
```bash
# Check firewall status
sudo ufw status

# Allow SSH if blocked
sudo ufw allow ssh
sudo ufw allow 22
```

**Network Configuration:**
```bash
# Check WiFi connection
iwconfig
sudo iwlist scan | grep ESSID

# Restart networking
sudo systemctl restart dhcpcd
```

## Advanced Diagnostics

### System Information
```bash
# Comprehensive system check
/home/pi/slideshow/scripts/maintenance.sh health

# Hardware information
cat /proc/cpuinfo
cat /proc/meminfo
lsusb
vcgencmd get_config int
```

### Service Dependencies
```bash
# Check service dependency tree
systemctl list-dependencies slideshow
systemctl list-dependencies slideshow-sync

# Check what's preventing service start
systemd-analyze critical-chain slideshow.service
```

### Log Analysis
```bash
# Search for errors across all logs
grep -r "ERROR\|CRITICAL" /home/pi/slideshow/logs/

# Check system logs for hardware issues
dmesg | grep -i error
journalctl --priority=err --since "24 hours ago"
```

## Recovery Procedures

### Complete System Reset
```bash
# Stop all services
sudo systemctl stop slideshow slideshow-monitor slideshow-sync

# Reset configuration to defaults
cd /home/pi/slideshow
cp config/slideshow.conf config/slideshow.conf.backup
# Edit config with safe defaults

# Clear logs and cache
rm -rf logs/* /tmp/slideshow_*

# Restart services
sudo systemctl start slideshow-sync
sudo systemctl start slideshow-monitor  
sudo systemctl start slideshow
```

### Reinstall Application
```bash
# Backup configuration
cp -r /home/pi/slideshow/config /home/pi/slideshow-config-backup

# Remove current installation
sudo systemctl stop slideshow slideshow-monitor slideshow-sync
sudo systemctl disable slideshow slideshow-monitor slideshow-sync
sudo rm /etc/systemd/system/slideshow*.service
sudo systemctl daemon-reload

# Reinstall
cd /tmp
git clone https://github.com/yourusername/rpi-slideshow.git
cd rpi-slideshow
chmod +x install.sh
./install.sh

# Restore configuration
cp -r /home/pi/slideshow-config-backup/* /home/pi/slideshow/config/
```

### Emergency Boot Recovery
If the Pi won't boot properly:

1. **Remove SD card and mount on another computer**
2. **Edit files directly:**
   - Comment out auto-startx lines in `/home/pi/.profile`
   - Disable services in systemd
3. **Boot in recovery mode:**
   ```bash
   # Add to /boot/cmdline.txt
   init=/bin/bash
   ```
4. **Fix issues and reboot normally**

## Performance Tuning

### Optimize for Low-End Pi Models
```bash
# Reduce resource usage
nano /home/pi/slideshow/config/slideshow.conf
# Set:
# enable_cache = false
# preload_count = 0
# display_duration = 15  # Longer display time
# memory_limit = 256

# Reduce image quality
# image_quality = 75
```

### Monitor Performance
```bash
# Install monitoring tools
sudo apt install htop iotop

# Monitor in real-time
watch -n 1 'vcgencmd measure_temp && free -h'

# Log performance data
iostat -x 1 | tee performance.log
```

## Getting Help

### Information to Collect
When seeking help, collect this information:

```bash
# System information
uname -a
cat /proc/cpuinfo | grep Model
free -h && df -h

# Service status
systemctl status slideshow slideshow-monitor slideshow-sync

# Recent logs
journalctl -u slideshow --since "1 hour ago" --no-pager

# Configuration
cat /home/pi/slideshow/config/slideshow.conf

# Network and rclone status
ping -c 3 google.com
rclone config show gdrive
```

### Support Channels
- Check project documentation
- Review GitHub issues
- Run maintenance script diagnostics
- Check Raspberry Pi forums for hardware-specific issues

Remember to sanitize any sensitive information (passwords, tokens) before sharing logs or configurations.
