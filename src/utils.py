#!/usr/bin/env python3
"""
Utility functions for Raspberry Pi Slideshow system
Common functions for logging, configuration, file handling, etc.
"""

import os
import logging
import configparser
from pathlib import Path
from typing import List, Dict, Any
import logging.handlers
import subprocess
import time
import psutil

def load_config(config_path: str) -> configparser.ConfigParser:
    """Load configuration from file with defaults"""
    config = configparser.ConfigParser()
    
    # Set defaults
    defaults = {
        'slideshow': {
            'images_dir': '/home/pi/slideshow/images',
            'display_duration': '10',
            'supported_formats': 'jpg,jpeg,png,gif',
            'transition': 'fade',
            'random_order': 'true',
            'auto_rotate': 'true',
            'image_quality': '95'
        },
        'sync': {
            'remote_name': 'gdrive',
            'remote_path': 'slideshow',
            'sync_interval': '10',
            'bidirectional': 'true',
            'bandwidth_limit': '',
            'sync_deletes': 'true',
            'exclude_patterns': '*.tmp,*.DS_Store,Thumbs.db'
        },
        'monitor': {
            'check_interval': '10',
            'recursive': 'true',
            'restart_delay': '5',
            'min_file_size': '1024'
        },
        'logging': {
            'log_dir': '/home/pi/slideshow/logs',
            'log_level': 'INFO',
            'log_rotation': 'true',
            'max_log_size': '10',
            'backup_count': '5',
            'log_format': '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        },
        'display': {
            'display': '0',
            'fullscreen': 'true',
            'background_color': '#000000',
            'scale_images': 'true',
            'fit_mode': 'contain',
            'resolution': '',
            'vsync': 'true'
        },
        'network': {
            'monitor_network': 'true',
            'network_check_interval': '60',
            'offline_behavior': 'continue',
            'sync_timeout': '300'
        },
        'performance': {
            'enable_cache': 'true',
            'cache_size': '500',
            'preload_count': '3',
            'hardware_accel': 'auto',
            'memory_limit': '1024'
        }
    }
    
    # Apply defaults
    for section_name, section_data in defaults.items():
        if not config.has_section(section_name):
            config.add_section(section_name)
        for key, value in section_data.items():
            config.set(section_name, key, value)
    
    # Load from file if it exists
    if os.path.exists(config_path):
        config.read(config_path)
    else:
        # Create default config file
        os.makedirs(os.path.dirname(config_path), exist_ok=True)
        with open(config_path, 'w') as f:
            config.write(f)
    
    return config

def setup_logging(logger_name: str, config: configparser.ConfigParser) -> logging.Logger:
    """Setup logging with rotation and proper formatting"""
    logger = logging.getLogger(logger_name)
    
    # Clear existing handlers
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)
    
    # Get logging configuration
    log_dir = Path(config.get('logging', 'log_dir'))
    log_level = getattr(logging, config.get('logging', 'log_level').upper())
    log_rotation = config.getboolean('logging', 'log_rotation')
    max_log_size = config.getint('logging', 'max_log_size') * 1024 * 1024  # Convert to bytes
    backup_count = config.getint('logging', 'backup_count')
    log_format = config.get('logging', 'log_format')
    
    # Create log directory
    log_dir.mkdir(parents=True, exist_ok=True)
    
    # Setup formatter
    formatter = logging.Formatter(log_format)
    
    # File handler with rotation
    log_file = log_dir / f"{logger_name}.log"
    if log_rotation:
        file_handler = logging.handlers.RotatingFileHandler(
            log_file,
            maxBytes=max_log_size,
            backupCount=backup_count
        )
    else:
        file_handler = logging.FileHandler(log_file)
    
    file_handler.setFormatter(formatter)
    file_handler.setLevel(log_level)
    logger.addHandler(file_handler)
    
    # Console handler (only for INFO and above)
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    console_handler.setLevel(logging.INFO)
    logger.addHandler(console_handler)
    
    logger.setLevel(log_level)
    
    return logger

def get_supported_images(directory: Path, config: configparser.ConfigParser) -> List[Path]:
    """Get list of supported image files from directory"""
    supported_formats = config.get('slideshow', 'supported_formats').lower().split(',')
    supported_formats = [fmt.strip() for fmt in supported_formats]
    
    min_file_size = config.getint('monitor', 'min_file_size')
    recursive = config.getboolean('monitor', 'recursive')
    
    images = []
    
    if recursive:
        pattern = "**/*"
    else:
        pattern = "*"
    
    for file_path in directory.glob(pattern):
        if not file_path.is_file():
            continue
        
        # Check file extension
        if file_path.suffix.lower().lstrip('.') not in supported_formats:
            continue
        
        # Check file size
        try:
            if file_path.stat().st_size < min_file_size:
                continue
        except OSError:
            continue
        
        images.append(file_path)
    
    return sorted(images)

def check_network_connection(timeout: int = 5) -> bool:
    """Check if network connection is available"""
    try:
        # Try to ping Google DNS
        result = subprocess.run(
            ['ping', '-c', '1', '-W', str(timeout), '8.8.8.8'],
            capture_output=True,
            timeout=timeout + 2
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False

def get_system_info() -> Dict[str, Any]:
    """Get system information for monitoring"""
    info = {}
    
    try:
        # CPU usage
        info['cpu_percent'] = psutil.cpu_percent(interval=1)
        
        # Memory usage
        memory = psutil.virtual_memory()
        info['memory_percent'] = memory.percent
        info['memory_available_mb'] = memory.available // 1024 // 1024
        
        # Disk usage
        disk = psutil.disk_usage('/')
        info['disk_percent'] = (disk.used / disk.total) * 100
        info['disk_free_gb'] = disk.free // 1024 // 1024 // 1024
        
        # Temperature (Raspberry Pi specific)
        try:
            with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
                temp = int(f.read()) / 1000.0
                info['cpu_temperature'] = temp
        except (FileNotFoundError, ValueError):
            info['cpu_temperature'] = None
        
        # Load average
        load_avg = os.getloadavg()
        info['load_average'] = load_avg[0]  # 1-minute average
        
        # Uptime
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.read().split()[0])
            info['uptime_hours'] = uptime_seconds / 3600
        
    except Exception as e:
        info['error'] = str(e)
    
    return info

def is_process_running(process_name: str) -> bool:
    """Check if a process is running"""
    try:
        for process in psutil.process_iter(['pid', 'name']):
            if process.info['name'] == process_name:
                return True
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass
    return False

def kill_process_by_name(process_name: str) -> bool:
    """Kill all processes with given name"""
    killed = False
    try:
        for process in psutil.process_iter(['pid', 'name']):
            if process.info['name'] == process_name:
                process.terminate()
                killed = True
        
        # Wait for processes to terminate
        time.sleep(1)
        
        # Force kill if still running
        for process in psutil.process_iter(['pid', 'name']):
            if process.info['name'] == process_name:
                process.kill()
                killed = True
                
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass
    
    return killed

def ensure_display_available() -> bool:
    """Ensure X11 display is available"""
    display = os.environ.get('DISPLAY', ':0')
    
    try:
        result = subprocess.run(
            ['xset', '-display', display, 'q'],
            capture_output=True,
            timeout=5
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False

def get_display_resolution(display: str = ':0') -> tuple:
    """Get display resolution"""
    try:
        result = subprocess.run(
            ['xrandr', '-display', display],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if '*' in line and '+' in line:
                    resolution = line.split()[0]
                    width, height = map(int, resolution.split('x'))
                    return width, height
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError):
        pass
    
    # Default resolution
    return 1920, 1080

def create_pid_file(pid_file: str) -> bool:
    """Create PID file for daemon"""
    try:
        pid = os.getpid()
        with open(pid_file, 'w') as f:
            f.write(str(pid))
        return True
    except Exception:
        return False

def remove_pid_file(pid_file: str) -> bool:
    """Remove PID file"""
    try:
        if os.path.exists(pid_file):
            os.remove(pid_file)
        return True
    except Exception:
        return False

def is_raspberry_pi() -> bool:
    """Check if running on a Raspberry Pi"""
    try:
        with open('/proc/cpuinfo', 'r') as f:
            cpuinfo = f.read()
            return 'Raspberry Pi' in cpuinfo
    except FileNotFoundError:
        return False

def get_rpi_model() -> str:
    """Get Raspberry Pi model string"""
    try:
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if line.startswith('Model'):
                    return line.split(':', 1)[1].strip()
    except FileNotFoundError:
        pass
    return "Unknown"

def format_bytes(bytes_value: int) -> str:
    """Format bytes as human readable string"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_value < 1024.0:
            return f"{bytes_value:.1f} {unit}"
        bytes_value /= 1024.0
    return f"{bytes_value:.1f} PB"

def format_duration(seconds: float) -> str:
    """Format seconds as human readable duration"""
    if seconds < 60:
        return f"{seconds:.0f}s"
    elif seconds < 3600:
        minutes = seconds // 60
        secs = seconds % 60
        return f"{minutes:.0f}m {secs:.0f}s"
    else:
        hours = seconds // 3600
        minutes = (seconds % 3600) // 60
        return f"{hours:.0f}h {minutes:.0f}m"

def safe_read_file(file_path: str, default: str = "") -> str:
    """Safely read file content with fallback"""
    try:
        with open(file_path, 'r') as f:
            return f.read().strip()
    except Exception:
        return default

def safe_write_file(file_path: str, content: str) -> bool:
    """Safely write file content"""
    try:
        os.makedirs(os.path.dirname(file_path), exist_ok=True)
        with open(file_path, 'w') as f:
            f.write(content)
        return True
    except Exception:
        return False
