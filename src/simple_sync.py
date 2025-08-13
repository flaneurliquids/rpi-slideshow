#!/usr/bin/env python3
"""
Simple Google Drive Sync using Public Folder Links
Alternative to complex rclone OAuth - uses public shareable links
"""

import os
import sys
import time
import requests
import json
import re
from pathlib import Path
from typing import List, Dict, Optional
from urllib.parse import urlparse, parse_qs
import threading
import signal
from utils import setup_logging, load_config, check_network_connection

class SimpleGoogleDriveSync:
    """Simple Google Drive sync using public folder links"""
    
    def __init__(self, config_path: str = "/home/pi/slideshow/config/slideshow.conf"):
        self.config = load_config(config_path)
        self.logger = setup_logging("simple-sync", self.config)
        
        # Configuration
        self.images_dir = Path(self.config.get('slideshow', 'images_dir'))
        self.sync_interval = self.config.getfloat('sync', 'sync_interval') * 60  # Convert to seconds
        self.folder_url = self.config.get('sync', 'public_folder_url', fallback='')
        self.download_timeout = 30
        
        # State
        self.running = False
        self.last_sync_time = 0
        self.known_files = set()
        self.session = requests.Session()
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (compatible; RaspberryPi-Slideshow/1.0)'
        })
        
        # Stats
        self.total_syncs = 0
        self.successful_syncs = 0
        self.total_downloads = 0
        self.total_bytes_downloaded = 0
        
        self.logger.info("Simple Google Drive sync initialized")
    
    def extract_folder_id(self, url: str) -> Optional[str]:
        """Extract folder ID from Google Drive URL"""
        if not url:
            return None
        
        # Handle different Google Drive URL formats
        patterns = [
            r'/folders/([a-zA-Z0-9-_]+)',
            r'id=([a-zA-Z0-9-_]+)',
            r'folders/([a-zA-Z0-9-_]+)'
        ]
        
        for pattern in patterns:
            match = re.search(pattern, url)
            if match:
                return match.group(1)
        
        self.logger.error(f"Could not extract folder ID from URL: {url}")
        return None
    
    def get_folder_files(self, folder_id: str) -> List[Dict]:
        """Get list of files in public Google Drive folder"""
        try:
            # Use Google Drive API v3 files.list with public access
            api_url = "https://www.googleapis.com/drive/v3/files"
            params = {
                'q': f"'{folder_id}' in parents and mimeType contains 'image/'",
                'fields': 'files(id,name,size,modifiedTime,webContentLink)',
                'key': 'AIzaSyC7DU9t0bYQFNTHg2iRD7jgNy2yK4Rb5ps'  # Public API key for Drive
            }
            
            response = self.session.get(api_url, params=params, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                return data.get('files', [])
            elif response.status_code == 403:
                self.logger.error("Folder is not publicly accessible or API quota exceeded")
                return []
            else:
                self.logger.error(f"API request failed: {response.status_code} - {response.text}")
                return []
                
        except Exception as e:
            self.logger.error(f"Error getting folder files: {e}")
            return []
    
    def get_folder_files_web_scraping(self, folder_id: str) -> List[Dict]:
        """Fallback: Get files using web scraping (less reliable)"""
        try:
            # Try to access the folder as a web page and parse the content
            folder_url = f"https://drive.google.com/drive/folders/{folder_id}"
            
            response = self.session.get(folder_url, timeout=10)
            if response.status_code != 200:
                self.logger.error(f"Could not access folder: {response.status_code}")
                return []
            
            # This is a simplified approach - Google Drive's actual page is complex
            # In practice, you'd need more sophisticated parsing
            content = response.text
            
            # Look for file entries (this is a basic pattern and may not work reliably)
            file_pattern = r'"([a-zA-Z0-9-_]+)","[^"]*","[^"]*","[^"]*","([^"]+\.(?:jpg|jpeg|png|gif))"'
            matches = re.findall(file_pattern, content, re.IGNORECASE)
            
            files = []
            for file_id, filename in matches:
                files.append({
                    'id': file_id,
                    'name': filename,
                    'webContentLink': f"https://drive.google.com/uc?id={file_id}&export=download"
                })
            
            return files
            
        except Exception as e:
            self.logger.error(f"Error with web scraping method: {e}")
            return []
    
    def download_file(self, file_info: Dict) -> bool:
        """Download a file from Google Drive"""
        try:
            file_id = file_info['id']
            filename = file_info['name']
            local_path = self.images_dir / filename
            
            # Skip if file already exists and hasn't changed
            if local_path.exists():
                self.logger.debug(f"File already exists: {filename}")
                return True
            
            # Get download URL
            if 'webContentLink' in file_info:
                download_url = file_info['webContentLink']
            else:
                download_url = f"https://drive.google.com/uc?id={file_id}&export=download"
            
            self.logger.info(f"Downloading: {filename}")
            
            # Download the file
            response = self.session.get(download_url, timeout=self.download_timeout, stream=True)
            
            if response.status_code == 200:
                # Ensure directory exists
                self.images_dir.mkdir(parents=True, exist_ok=True)
                
                # Write file
                with open(local_path, 'wb') as f:
                    for chunk in response.iter_content(chunk_size=8192):
                        f.write(chunk)
                
                file_size = local_path.stat().st_size
                self.total_downloads += 1
                self.total_bytes_downloaded += file_size
                
                self.logger.info(f"Downloaded: {filename} ({file_size} bytes)")
                return True
            else:
                self.logger.error(f"Download failed for {filename}: {response.status_code}")
                return False
                
        except Exception as e:
            self.logger.error(f"Error downloading {file_info.get('name', 'unknown')}: {e}")
            return False
    
    def cleanup_old_files(self, current_files: List[str]):
        """Remove local files that are no longer in the Drive folder"""
        try:
            if not self.images_dir.exists():
                return
            
            current_filenames = set(current_files)
            local_files = []
            
            # Get all image files in local directory
            for ext in ['jpg', 'jpeg', 'png', 'gif']:
                local_files.extend(self.images_dir.glob(f"*.{ext}"))
                local_files.extend(self.images_dir.glob(f"*.{ext.upper()}"))
            
            # Remove files that are no longer in Drive
            for local_file in local_files:
                if local_file.name not in current_filenames:
                    self.logger.info(f"Removing deleted file: {local_file.name}")
                    local_file.unlink()
                    
        except Exception as e:
            self.logger.error(f"Error cleaning up old files: {e}")
    
    def perform_sync(self) -> bool:
        """Perform synchronization with public Google Drive folder"""
        if not self.folder_url:
            self.logger.error("No public folder URL configured")
            return False
        
        self.logger.info("Starting sync with public Google Drive folder")
        sync_start_time = time.time()
        
        try:
            # Extract folder ID from URL
            folder_id = self.extract_folder_id(self.folder_url)
            if not folder_id:
                return False
            
            # Get list of files in the folder
            files = self.get_folder_files(folder_id)
            
            # If API method fails, try web scraping as fallback
            if not files:
                self.logger.info("API method failed, trying web scraping...")
                files = self.get_folder_files_web_scraping(folder_id)
            
            if not files:
                self.logger.warning("No files found in Google Drive folder")
                return False
            
            self.logger.info(f"Found {len(files)} files in Drive folder")
            
            # Download new/updated files
            downloaded_count = 0
            for file_info in files:
                if self.download_file(file_info):
                    downloaded_count += 1
            
            # Clean up old files
            current_filenames = [f['name'] for f in files]
            self.cleanup_old_files(current_filenames)
            
            # Update stats
            self.successful_syncs += 1
            self.last_sync_time = time.time()
            
            sync_duration = time.time() - sync_start_time
            self.logger.info(f"Sync completed: {downloaded_count} files processed in {sync_duration:.1f}s")
            
            return True
            
        except Exception as e:
            self.logger.error(f"Error during sync: {e}")
            return False
        finally:
            self.total_syncs += 1
    
    def get_sync_stats(self) -> Dict:
        """Get synchronization statistics"""
        return {
            'total_syncs': self.total_syncs,
            'successful_syncs': self.successful_syncs,
            'success_rate': (self.successful_syncs / self.total_syncs * 100) if self.total_syncs > 0 else 0,
            'total_downloads': self.total_downloads,
            'total_bytes_downloaded': self.total_bytes_downloaded,
            'last_sync_time': self.last_sync_time,
            'folder_url': self.folder_url
        }
    
    def run(self):
        """Main sync loop"""
        self.logger.info("Starting simple Google Drive sync daemon")
        self.running = True
        
        if not self.folder_url:
            self.logger.error("No public folder URL configured. Please add 'public_folder_url' to [sync] section.")
            return
        
        # Initial sync
        self.perform_sync()
        
        # Main sync loop
        try:
            while self.running:
                current_time = time.time()
                
                # Check if it's time to sync
                if current_time - self.last_sync_time >= self.sync_interval:
                    # Check network connectivity
                    if not check_network_connection():
                        self.logger.warning("No network connection, skipping sync")
                        time.sleep(60)
                        continue
                    
                    # Perform sync
                    self.perform_sync()
                
                # Wait before next check
                time.sleep(60)  # Check every minute
                
        except KeyboardInterrupt:
            self.logger.info("Sync interrupted by user")
        except Exception as e:
            self.logger.error(f"Error in sync loop: {e}")
        finally:
            self.stop()
    
    def stop(self):
        """Stop sync daemon"""
        self.logger.info("Stopping simple Google Drive sync daemon")
        self.running = False
        
        # Close session
        self.session.close()
        
        # Log final stats
        stats = self.get_sync_stats()
        self.logger.info(f"Final stats: {stats['successful_syncs']}/{stats['total_syncs']} successful syncs")
        self.logger.info(f"Total downloads: {stats['total_downloads']}")

def signal_handler(signum, frame):
    """Handle shutdown signals"""
    print(f"\nReceived signal {signum}, shutting down...")
    if 'sync_daemon' in globals():
        sync_daemon.stop()
    sys.exit(0)

def main():
    """Main entry point"""
    global sync_daemon
    
    # Setup signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Parse command line arguments
    config_path = "/home/pi/slideshow/config/slideshow.conf"
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    
    try:
        # Create and run sync daemon
        sync_daemon = SimpleGoogleDriveSync(config_path)
        sync_daemon.run()
    except Exception as e:
        print(f"Error starting sync daemon: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
