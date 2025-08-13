# Raspberry Pi Slideshow System with Google Drive Sync

A complete slideshow system for Raspberry Pi that automatically syncs images from Google Drive and displays them in full-screen mode with real-time monitoring.

## Features

- **Full-screen slideshow** with automatic image scaling and rotation
- **Real-time folder monitoring** using inotify (checks every 10 seconds)
- **Google Drive sync** every 10 minutes using rclone
- **Auto-restart slideshow** when images are added/removed
- **Systemd services** for reliable auto-start and management
- **Comprehensive logging** and error handling
- **Support for JPG, PNG, GIF** formats
- **Smooth transitions** with configurable timing
- **Offline mode handling** when internet unavailable
- **Remote monitoring** via SSH and web interface

## Hardware Requirements

- Raspberry Pi (3B+ or newer recommended)
- MicroSD card (16GB+ recommended)
- HDMI cable for TV connection
- Internet connection (WiFi or Ethernet)

## Quick Installation

1. Flash Raspberry Pi OS to your SD card
2. SSH into your Raspberry Pi and run:
   ```bash
   curl -sSL https://raw.githubusercontent.com/flaneurliquids/rpi-slideshow/main/install.sh | bash
   ```
3. Follow the Google Drive authentication prompts
4. Reboot and enjoy your slideshow!

## Manual Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/flaneurliquids/rpi-slideshow.git
   cd rpi-slideshow
   chmod +x install.sh
   ./install.sh
   ```

## Project Structure

```
rpi-slideshow/
├── README.md               # This file
├── install.sh              # Main installation script
├── config/
│   ├── slideshow.conf      # Main configuration file
│   └── rclone.conf.template # Google Drive config template
├── src/
│   ├── slideshow.py        # Main slideshow application
│   ├── monitor.py          # File monitoring daemon
│   ├── sync.py             # Google Drive sync daemon
│   └── utils.py            # Utility functions
├── services/
│   ├── slideshow.service   # Slideshow systemd service
│   ├── slideshow-monitor.service # File monitor service
│   └── slideshow-sync.service    # Sync service
├── scripts/
│   ├── setup-rclone.sh     # Google Drive setup
│   ├── start-slideshow.sh  # Slideshow starter script
│   └── maintenance.sh      # System maintenance
├── docs/
│   ├── installation.md     # Detailed installation guide
│   ├── configuration.md    # Configuration options
│   ├── google-drive-setup.md # Google Drive setup
│   └── troubleshooting.md  # Common issues and fixes
└── logs/                   # Log files (created during runtime)
```

## Default Configuration

- **Slideshow folder**: `/home/pi/slideshow/images`
- **Display duration**: 10 seconds per image
- **Sync interval**: 10 minutes
- **Monitor interval**: 10 seconds
- **Supported formats**: JPG, JPEG, PNG, GIF
- **Log location**: `/home/pi/slideshow/logs/`

## Services Status

Check service status:
```bash
sudo systemctl status slideshow
sudo systemctl status slideshow-monitor
sudo systemctl status slideshow-sync
```

View logs:
```bash
tail -f /home/pi/slideshow/logs/slideshow.log
tail -f /home/pi/slideshow/logs/sync.log
tail -f /home/pi/slideshow/logs/monitor.log
```

## Remote Control

Start/stop slideshow:
```bash
sudo systemctl start slideshow
sudo systemctl stop slideshow
```

Force sync:
```bash
sudo systemctl restart slideshow-sync
```

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and solutions.

## License

MIT License - Feel free to modify and distribute!
