#!/usr/bin/env python3
"""
Raspberry Pi Slideshow Application
Main slideshow engine with image display, caching, and transition effects.
"""

import os
import sys
import time
import random
import signal
import logging
import threading
from pathlib import Path
from typing import List, Optional, Tuple
import configparser
import subprocess
from PIL import Image, ImageOps, ExifTags
from utils import setup_logging, load_config, get_supported_images

class SlideshowEngine:
    """Main slideshow engine handling image display and transitions"""
    
    def __init__(self, config_path: str = "/home/pi/slideshow/config/slideshow.conf"):
        self.config = load_config(config_path)
        self.logger = setup_logging("slideshow", self.config)
        
        # Configuration
        self.images_dir = Path(self.config.get('slideshow', 'images_dir'))
        self.display_duration = self.config.getfloat('slideshow', 'display_duration')
        self.random_order = self.config.getboolean('slideshow', 'random_order')
        self.auto_rotate = self.config.getboolean('slideshow', 'auto_rotate')
        self.transition = self.config.get('slideshow', 'transition')
        self.fullscreen = self.config.getboolean('display', 'fullscreen')
        self.background_color = self.config.get('display', 'background_color')
        self.fit_mode = self.config.get('display', 'fit_mode')
        
        # Cache settings
        self.enable_cache = self.config.getboolean('performance', 'enable_cache')
        self.cache_size = self.config.getint('performance', 'cache_size') * 1024 * 1024  # Convert to bytes
        self.preload_count = self.config.getint('performance', 'preload_count')
        
        # State
        self.current_images: List[Path] = []
        self.current_index = 0
        self.running = False
        self.feh_process: Optional[subprocess.Popen] = None
        self.cache = {}
        self.cache_size_used = 0
        
        # Threading
        self.preload_thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()
        
        self.logger.info("Slideshow engine initialized")
    
    def get_screen_resolution(self) -> Tuple[int, int]:
        """Get the current screen resolution"""
        try:
            # Try to get resolution from xrandr
            result = subprocess.run(['xrandr'], capture_output=True, text=True)
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if '*' in line and '+' in line:
                        resolution = line.split()[0]
                        width, height = map(int, resolution.split('x'))
                        return width, height
        except Exception as e:
            self.logger.warning(f"Could not get screen resolution: {e}")
        
        # Default resolution for Raspberry Pi
        return 1920, 1080
    
    def process_image(self, image_path: Path) -> Optional[str]:
        """Process image for optimal display"""
        try:
            # Check cache first
            cache_key = f"{image_path}_{os.path.getmtime(image_path)}"
            if cache_key in self.cache:
                return self.cache[cache_key]
            
            # Open and process image
            with Image.open(image_path) as img:
                # Handle EXIF rotation
                if self.auto_rotate:
                    img = ImageOps.exif_transpose(img)
                
                # Get screen resolution
                screen_width, screen_height = self.get_screen_resolution()
                
                # Calculate optimal size based on fit mode
                if self.fit_mode == 'contain':
                    # Letterbox - maintain aspect ratio, fit within screen
                    img.thumbnail((screen_width, screen_height), Image.Resampling.LANCZOS)
                elif self.fit_mode == 'cover':
                    # Crop - fill screen, maintain aspect ratio
                    img_ratio = img.width / img.height
                    screen_ratio = screen_width / screen_height
                    
                    if img_ratio > screen_ratio:
                        # Image wider than screen
                        new_height = screen_height
                        new_width = int(new_height * img_ratio)
                    else:
                        # Image taller than screen
                        new_width = screen_width
                        new_height = int(new_width / img_ratio)
                    
                    img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                    
                    # Crop to screen size
                    left = (new_width - screen_width) // 2
                    top = (new_height - screen_height) // 2
                    img = img.crop((left, top, left + screen_width, top + screen_height))
                
                elif self.fit_mode == 'fill':
                    # Stretch - fill screen, ignore aspect ratio
                    img = img.resize((screen_width, screen_height), Image.Resampling.LANCZOS)
                
                # Save processed image to temp file
                temp_path = f"/tmp/slideshow_processed_{hash(str(image_path))}.jpg"
                img.save(temp_path, "JPEG", quality=95, optimize=True)
                
                # Add to cache if enabled
                if self.enable_cache:
                    file_size = os.path.getsize(temp_path)
                    if self.cache_size_used + file_size <= self.cache_size:
                        self.cache[cache_key] = temp_path
                        self.cache_size_used += file_size
                    else:
                        # Cache full, clean oldest entries
                        self._clean_cache()
                        if self.cache_size_used + file_size <= self.cache_size:
                            self.cache[cache_key] = temp_path
                            self.cache_size_used += file_size
                
                return temp_path
                
        except Exception as e:
            self.logger.error(f"Error processing image {image_path}: {e}")
            return None
    
    def _clean_cache(self):
        """Clean cache to make room for new images"""
        # Simple LRU-like cleanup - remove half the cache
        items_to_remove = len(self.cache) // 2
        removed = 0
        
        for key in list(self.cache.keys()):
            if removed >= items_to_remove:
                break
            
            temp_path = self.cache[key]
            try:
                if os.path.exists(temp_path):
                    file_size = os.path.getsize(temp_path)
                    os.remove(temp_path)
                    self.cache_size_used -= file_size
            except Exception as e:
                self.logger.warning(f"Error cleaning cache file {temp_path}: {e}")
            
            del self.cache[key]
            removed += 1
    
    def scan_images(self) -> List[Path]:
        """Scan directory for supported image files"""
        if not self.images_dir.exists():
            self.logger.warning(f"Images directory does not exist: {self.images_dir}")
            return []
        
        images = get_supported_images(self.images_dir, self.config)
        self.logger.info(f"Found {len(images)} images in {self.images_dir}")
        return images
    
    def preload_images(self):
        """Preload images in background thread"""
        while not self.stop_event.is_set():
            try:
                # Preload next few images
                for i in range(self.preload_count):
                    if self.stop_event.is_set():
                        break
                    
                    next_index = (self.current_index + i + 1) % len(self.current_images)
                    if next_index < len(self.current_images):
                        image_path = self.current_images[next_index]
                        self.process_image(image_path)
                
                # Wait before next preload cycle
                self.stop_event.wait(30)  # Wait 30 seconds
                
            except Exception as e:
                self.logger.error(f"Error in preload thread: {e}")
                self.stop_event.wait(10)  # Wait before retrying
    
    def start_feh(self, image_path: str):
        """Start feh image viewer with specific image"""
        try:
            # Kill existing feh process
            if self.feh_process:
                self.feh_process.terminate()
                self.feh_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.feh_process.kill()
        except Exception:
            pass
        
        # Build feh command
        cmd = ['feh']
        
        if self.fullscreen:
            cmd.append('--fullscreen')
        
        cmd.extend([
            '--hide-pointer',
            '--no-menus',
            '--quiet',
            '--bg-fill' if self.fit_mode == 'fill' else '--bg-scale',
            image_path
        ])
        
        try:
            self.feh_process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env={**os.environ, 'DISPLAY': ':0'}
            )
            self.logger.debug(f"Started feh with image: {image_path}")
        except Exception as e:
            self.logger.error(f"Error starting feh: {e}")
    
    def display_image(self, image_path: Path):
        """Display a single image"""
        self.logger.debug(f"Displaying image: {image_path}")
        
        # Process image if needed
        processed_path = self.process_image(image_path)
        if not processed_path:
            self.logger.error(f"Failed to process image: {image_path}")
            return
        
        # Display with feh
        self.start_feh(processed_path)
    
    def next_image(self):
        """Move to next image"""
        if not self.current_images:
            return
        
        self.current_index = (self.current_index + 1) % len(self.current_images)
        image_path = self.current_images[self.current_index]
        self.display_image(image_path)
    
    def refresh_images(self):
        """Refresh image list and restart if needed"""
        new_images = self.scan_images()
        
        if new_images != self.current_images:
            self.logger.info("Image list changed, refreshing slideshow")
            self.current_images = new_images
            
            if self.random_order:
                random.shuffle(self.current_images)
            
            # Reset to first image if current index is out of bounds
            if self.current_index >= len(self.current_images):
                self.current_index = 0
            
            # Display current image if we have images
            if self.current_images:
                self.display_image(self.current_images[self.current_index])
    
    def run(self):
        """Main slideshow loop"""
        self.logger.info("Starting slideshow")
        self.running = True
        
        # Initial scan
        self.refresh_images()
        
        if not self.current_images:
            self.logger.error("No images found to display")
            return
        
        # Start preload thread if caching enabled
        if self.enable_cache and self.preload_count > 0:
            self.preload_thread = threading.Thread(target=self.preload_images, daemon=True)
            self.preload_thread.start()
        
        # Main display loop
        try:
            while self.running:
                # Check for image changes periodically
                self.refresh_images()
                
                if not self.current_images:
                    self.logger.warning("No images available, waiting...")
                    time.sleep(10)
                    continue
                
                # Display current image
                current_image = self.current_images[self.current_index]
                self.display_image(current_image)
                
                # Wait for display duration
                time.sleep(self.display_duration)
                
                # Move to next image
                self.next_image()
                
        except KeyboardInterrupt:
            self.logger.info("Slideshow interrupted by user")
        except Exception as e:
            self.logger.error(f"Error in slideshow loop: {e}")
        finally:
            self.stop()
    
    def stop(self):
        """Stop slideshow and cleanup"""
        self.logger.info("Stopping slideshow")
        self.running = False
        self.stop_event.set()
        
        # Stop feh process
        if self.feh_process:
            try:
                self.feh_process.terminate()
                self.feh_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.feh_process.kill()
            except Exception:
                pass
        
        # Wait for preload thread to finish
        if self.preload_thread and self.preload_thread.is_alive():
            self.preload_thread.join(timeout=5)
        
        # Clean up cache
        for temp_path in self.cache.values():
            try:
                if os.path.exists(temp_path):
                    os.remove(temp_path)
            except Exception:
                pass
        
        self.cache.clear()
        self.cache_size_used = 0
        
        self.logger.info("Slideshow stopped")

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    print(f"\nReceived signal {signum}, shutting down...")
    if 'slideshow' in globals():
        slideshow.stop()
    sys.exit(0)

def main():
    """Main entry point"""
    global slideshow
    
    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Parse command line arguments
    config_path = "/home/pi/slideshow/config/slideshow.conf"
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    
    try:
        # Create and run slideshow
        slideshow = SlideshowEngine(config_path)
        slideshow.run()
    except Exception as e:
        print(f"Error starting slideshow: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
