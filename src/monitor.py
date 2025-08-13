#!/usr/bin/env python3
"""
File Monitor Daemon for Raspberry Pi Slideshow
Monitors image directory for changes and restarts slideshow when needed.
"""

import os
import sys
import time
import signal
import subprocess
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from utils import setup_logging, load_config, get_supported_images, is_process_running

class SlideshowFileHandler(FileSystemEventHandler):
    """File system event handler for slideshow images"""
    
    def __init__(self, monitor):
        self.monitor = monitor
        self.logger = monitor.logger
        
    def on_any_event(self, event):
        """Handle any file system event"""
        if event.is_directory:
            return
        
        # Check if it's a supported image file
        file_path = Path(event.src_path)
        if self._is_image_file(file_path):
            self.logger.info(f"Image file changed: {event.event_type} - {file_path}")
            self.monitor.schedule_restart()
    
    def _is_image_file(self, file_path: Path) -> bool:
        """Check if file is a supported image"""
        supported_formats = self.monitor.config.get('slideshow', 'supported_formats').lower().split(',')
        supported_formats = [fmt.strip() for fmt in supported_formats]
        
        return file_path.suffix.lower().lstrip('.') in supported_formats

class SlideshowMonitor:
    """Monitor for slideshow image directory"""
    
    def __init__(self, config_path: str = "/home/pi/slideshow/config/slideshow.conf"):
        self.config = load_config(config_path)
        self.logger = setup_logging("slideshow-monitor", self.config)
        
        # Configuration
        self.images_dir = Path(self.config.get('slideshow', 'images_dir'))
        self.check_interval = self.config.getfloat('monitor', 'check_interval')
        self.recursive = self.config.getboolean('monitor', 'recursive')
        self.restart_delay = self.config.getfloat('monitor', 'restart_delay')
        
        # State
        self.running = False
        self.observer = None
        self.last_restart_time = 0
        self.pending_restart = False
        self.current_image_count = 0
        
        self.logger.info("Slideshow monitor initialized")
    
    def count_images(self) -> int:
        """Count current number of images"""
        try:
            images = get_supported_images(self.images_dir, self.config)
            return len(images)
        except Exception as e:
            self.logger.error(f"Error counting images: {e}")
            return 0
    
    def schedule_restart(self):
        """Schedule a slideshow restart"""
        current_time = time.time()
        
        # Prevent too frequent restarts
        if current_time - self.last_restart_time < self.restart_delay:
            self.logger.debug("Restart already scheduled or too soon")
            self.pending_restart = True
            return
        
        self.pending_restart = True
        self.logger.info(f"Scheduling slideshow restart in {self.restart_delay} seconds")
    
    def restart_slideshow(self):
        """Restart the slideshow service"""
        try:
            self.logger.info("Restarting slideshow service")
            
            # Use systemctl to restart the slideshow service
            result = subprocess.run(
                ['sudo', 'systemctl', 'restart', 'slideshow.service'],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            if result.returncode == 0:
                self.logger.info("Slideshow service restarted successfully")
                self.last_restart_time = time.time()
                self.pending_restart = False
            else:
                self.logger.error(f"Failed to restart slideshow service: {result.stderr}")
                
        except subprocess.TimeoutExpired:
            self.logger.error("Timeout while restarting slideshow service")
        except Exception as e:
            self.logger.error(f"Error restarting slideshow service: {e}")
    
    def check_image_changes(self):
        """Check for image changes manually (fallback)"""
        try:
            current_count = self.count_images()
            
            if current_count != self.current_image_count:
                self.logger.info(f"Image count changed: {self.current_image_count} -> {current_count}")
                self.current_image_count = current_count
                self.schedule_restart()
                
        except Exception as e:
            self.logger.error(f"Error checking for image changes: {e}")
    
    def setup_watchdog(self):
        """Setup file system monitoring with watchdog"""
        try:
            if not self.images_dir.exists():
                self.logger.warning(f"Images directory does not exist: {self.images_dir}")
                self.images_dir.mkdir(parents=True, exist_ok=True)
                self.logger.info(f"Created images directory: {self.images_dir}")
            
            # Create event handler
            event_handler = SlideshowFileHandler(self)
            
            # Create observer
            self.observer = Observer()
            self.observer.schedule(
                event_handler,
                str(self.images_dir),
                recursive=self.recursive
            )
            
            # Start observer
            self.observer.start()
            self.logger.info(f"Started watching directory: {self.images_dir} (recursive={self.recursive})")
            
        except Exception as e:
            self.logger.error(f"Error setting up file system monitoring: {e}")
            self.observer = None
    
    def run(self):
        """Main monitoring loop"""
        self.logger.info("Starting slideshow monitor")
        self.running = True
        
        # Get initial image count
        self.current_image_count = self.count_images()
        self.logger.info(f"Initial image count: {self.current_image_count}")
        
        # Setup file system monitoring
        self.setup_watchdog()
        
        # Main monitoring loop
        try:
            while self.running:
                # Handle pending restarts
                if self.pending_restart:
                    current_time = time.time()
                    if current_time - self.last_restart_time >= self.restart_delay:
                        self.restart_slideshow()
                
                # Fallback check for image changes (in case watchdog fails)
                self.check_image_changes()
                
                # Check if slideshow service is running
                if not is_process_running('python3'):  # This is approximate
                    try:
                        result = subprocess.run(
                            ['systemctl', 'is-active', 'slideshow.service'],
                            capture_output=True,
                            text=True
                        )
                        if result.returncode != 0:
                            self.logger.warning("Slideshow service is not active")
                    except Exception:
                        pass
                
                # Wait before next check
                time.sleep(self.check_interval)
                
        except KeyboardInterrupt:
            self.logger.info("Monitor interrupted by user")
        except Exception as e:
            self.logger.error(f"Error in monitor loop: {e}")
        finally:
            self.stop()
    
    def stop(self):
        """Stop monitoring"""
        self.logger.info("Stopping slideshow monitor")
        self.running = False
        
        # Stop file system observer
        if self.observer:
            self.observer.stop()
            self.observer.join(timeout=5)
        
        self.logger.info("Slideshow monitor stopped")

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    print(f"\nReceived signal {signum}, shutting down...")
    if 'monitor' in globals():
        monitor.stop()
    sys.exit(0)

def main():
    """Main entry point"""
    global monitor
    
    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Parse command line arguments
    config_path = "/home/pi/slideshow/config/slideshow.conf"
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    
    try:
        # Create and run monitor
        monitor = SlideshowMonitor(config_path)
        monitor.run()
    except Exception as e:
        print(f"Error starting monitor: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
