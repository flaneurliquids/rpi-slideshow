#!/usr/bin/env python3
"""
Google Drive Sync Daemon for Raspberry Pi Slideshow
Synchronizes images with Google Drive using rclone.
"""

import os
import sys
import time
import signal
import subprocess
import json
from pathlib import Path
from typing import Dict, Any, List
from utils import setup_logging, load_config, check_network_connection, get_system_info

class GoogleDriveSync:
    """Google Drive synchronization manager"""
    
    def __init__(self, config_path: str = "/home/pi/slideshow/config/slideshow.conf"):
        self.config = load_config(config_path)
        self.logger = setup_logging("slideshow-sync", self.config)
        
        # Configuration
        self.images_dir = Path(self.config.get('slideshow', 'images_dir'))
        self.remote_name = self.config.get('sync', 'remote_name')
        self.remote_path = self.config.get('sync', 'remote_path')
        self.sync_interval = self.config.getfloat('sync', 'sync_interval') * 60  # Convert to seconds
        self.bidirectional = self.config.getboolean('sync', 'bidirectional')
        self.bandwidth_limit = self.config.get('sync', 'bandwidth_limit')
        self.sync_deletes = self.config.getboolean('sync', 'sync_deletes')
        self.exclude_patterns = [p.strip() for p in self.config.get('sync', 'exclude_patterns').split(',') if p.strip()]
        self.sync_timeout = self.config.getint('network', 'sync_timeout')
        
        # Network settings
        self.monitor_network = self.config.getboolean('network', 'monitor_network')
        self.network_check_interval = self.config.getfloat('network', 'network_check_interval')
        self.offline_behavior = self.config.get('network', 'offline_behavior')
        
        # State
        self.running = False
        self.last_sync_time = 0
        self.sync_errors = 0
        self.max_sync_errors = 5
        self.is_online = True
        self.last_network_check = 0
        
        # Stats
        self.total_syncs = 0
        self.successful_syncs = 0
        self.total_files_synced = 0
        self.total_bytes_synced = 0
        
        self.logger.info("Google Drive sync initialized")
    
    def check_rclone_config(self) -> bool:
        """Check if rclone is properly configured"""
        try:
            result = subprocess.run(
                ['rclone', 'listremotes'],
                capture_output=True,
                text=True,
                timeout=10
            )
            
            if result.returncode == 0:
                remotes = result.stdout.strip().split('\n')
                remote_with_colon = f"{self.remote_name}:"
                
                if remote_with_colon in remotes:
                    self.logger.info(f"Found configured remote: {self.remote_name}")
                    return True
                else:
                    self.logger.error(f"Remote '{self.remote_name}' not found in rclone config")
                    self.logger.info(f"Available remotes: {', '.join(remotes)}")
                    return False
            else:
                self.logger.error(f"Error listing rclone remotes: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            self.logger.error("Timeout checking rclone configuration")
            return False
        except FileNotFoundError:
            self.logger.error("rclone not found. Please install rclone.")
            return False
        except Exception as e:
            self.logger.error(f"Error checking rclone config: {e}")
            return False
    
    def check_network_status(self) -> bool:
        """Check network connectivity"""
        current_time = time.time()
        
        # Only check network status periodically
        if current_time - self.last_network_check < self.network_check_interval:
            return self.is_online
        
        self.last_network_check = current_time
        was_online = self.is_online
        self.is_online = check_network_connection()
        
        if was_online != self.is_online:
            if self.is_online:
                self.logger.info("Network connection restored")
            else:
                self.logger.warning("Network connection lost")
        
        return self.is_online
    
    def build_rclone_command(self, operation: str) -> List[str]:
        """Build rclone command with options"""
        remote_full_path = f"{self.remote_name}:"
        if self.remote_path:
            remote_full_path += self.remote_path
        
        cmd = ['rclone', operation]
        
        # Add source and destination
        if operation in ['sync', 'copy']:
            if operation == 'sync' and self.bidirectional:
                # For bidirectional sync, we'll do two separate operations
                pass
            else:
                cmd.extend([remote_full_path, str(self.images_dir)])
        
        # Add common options
        cmd.extend([
            '--verbose',
            '--stats', '30s',
            '--progress'
        ])
        
        # Bandwidth limit
        if self.bandwidth_limit:
            cmd.extend(['--bwlimit', self.bandwidth_limit])
        
        # Exclude patterns
        for pattern in self.exclude_patterns:
            cmd.extend(['--exclude', pattern])
        
        # Delete handling
        if self.sync_deletes and operation == 'sync':
            cmd.append('--delete-after')
        
        # Timeout
        cmd.extend(['--timeout', f"{self.sync_timeout}s"])
        
        # Additional safety options
        cmd.extend([
            '--check-first',  # Check before transferring
            '--no-check-certificate',  # Handle cert issues
            '--retries', '3',  # Retry failed operations
            '--low-level-retries', '10'  # Low-level retries
        ])
        
        return cmd
    
    def run_rclone_command(self, cmd: List[str]) -> Dict[str, Any]:
        """Run rclone command and return results"""
        result = {
            'success': False,
            'stdout': '',
            'stderr': '',
            'files_transferred': 0,
            'bytes_transferred': 0,
            'duration': 0
        }
        
        start_time = time.time()
        
        try:
            self.logger.info(f"Running rclone command: {' '.join(cmd)}")
            
            process = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.sync_timeout + 60  # Add buffer to command timeout
            )
            
            result['duration'] = time.time() - start_time
            result['stdout'] = process.stdout
            result['stderr'] = process.stderr
            result['success'] = process.returncode == 0
            
            if result['success']:
                # Parse output for statistics
                self._parse_rclone_output(result)
                self.logger.info(f"Rclone completed successfully in {result['duration']:.1f}s")
            else:
                self.logger.error(f"Rclone failed with return code {process.returncode}")
                self.logger.error(f"Error output: {result['stderr']}")
            
        except subprocess.TimeoutExpired:
            self.logger.error("Rclone command timed out")
            result['stderr'] = "Command timed out"
        except Exception as e:
            self.logger.error(f"Error running rclone command: {e}")
            result['stderr'] = str(e)
        
        return result
    
    def _parse_rclone_output(self, result: Dict[str, Any]):
        """Parse rclone output for statistics"""
        try:
            output = result['stdout'] + result['stderr']
            
            # Look for transfer statistics
            for line in output.split('\n'):
                if 'Transferred:' in line and 'Bytes' in line:
                    # Parse bytes transferred
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part == 'Bytes' and i > 0:
                            try:
                                bytes_str = parts[i-1].replace(',', '')
                                result['bytes_transferred'] = int(bytes_str)
                            except (ValueError, IndexError):
                                pass
                
                elif line.strip().startswith('Transferred:') and 'file' in line:
                    # Parse files transferred
                    try:
                        files_part = line.split('/')[0].split()[-1]
                        result['files_transferred'] = int(files_part)
                    except (ValueError, IndexError):
                        pass
                        
        except Exception as e:
            self.logger.debug(f"Error parsing rclone output: {e}")
    
    def sync_from_drive(self) -> bool:
        """Sync images from Google Drive to local directory"""
        self.logger.info("Starting sync from Google Drive")
        
        # Ensure local directory exists
        self.images_dir.mkdir(parents=True, exist_ok=True)
        
        # Build and run rclone command
        cmd = self.build_rclone_command('sync')
        # Adjust command for download direction
        remote_full_path = f"{self.remote_name}:"
        if self.remote_path:
            remote_full_path += self.remote_path
        
        cmd[2] = remote_full_path  # Source (remote)
        cmd[3] = str(self.images_dir)  # Destination (local)
        
        result = self.run_rclone_command(cmd)
        
        if result['success']:
            self.total_files_synced += result['files_transferred']
            self.total_bytes_synced += result['bytes_transferred']
            
            if result['files_transferred'] > 0:
                self.logger.info(f"Downloaded {result['files_transferred']} files "
                               f"({result['bytes_transferred']} bytes)")
            else:
                self.logger.debug("No new files to download")
                
            return True
        else:
            return False
    
    def sync_to_drive(self) -> bool:
        """Sync local images to Google Drive (if bidirectional enabled)"""
        if not self.bidirectional:
            return True
        
        self.logger.info("Starting sync to Google Drive")
        
        # Build and run rclone command
        cmd = self.build_rclone_command('sync')
        # Adjust command for upload direction
        remote_full_path = f"{self.remote_name}:"
        if self.remote_path:
            remote_full_path += self.remote_path
        
        cmd[2] = str(self.images_dir)  # Source (local)
        cmd[3] = remote_full_path  # Destination (remote)
        
        result = self.run_rclone_command(cmd)
        
        if result['success']:
            if result['files_transferred'] > 0:
                self.logger.info(f"Uploaded {result['files_transferred']} files "
                               f"({result['bytes_transferred']} bytes)")
            else:
                self.logger.debug("No new files to upload")
            return True
        else:
            return False
    
    def perform_sync(self) -> bool:
        """Perform complete sync operation"""
        self.logger.info("Starting synchronization cycle")
        sync_start_time = time.time()
        
        try:
            # Download from Drive
            download_success = self.sync_from_drive()
            
            # Upload to Drive (if bidirectional)
            upload_success = self.sync_to_drive()
            
            success = download_success and upload_success
            
            if success:
                self.successful_syncs += 1
                self.sync_errors = 0  # Reset error counter on success
                self.last_sync_time = time.time()
                
                sync_duration = time.time() - sync_start_time
                self.logger.info(f"Synchronization completed successfully in {sync_duration:.1f}s")
            else:
                self.sync_errors += 1
                self.logger.error(f"Synchronization failed (error count: {self.sync_errors})")
            
            self.total_syncs += 1
            return success
            
        except Exception as e:
            self.logger.error(f"Error during synchronization: {e}")
            self.sync_errors += 1
            self.total_syncs += 1
            return False
    
    def get_sync_stats(self) -> Dict[str, Any]:
        """Get synchronization statistics"""
        return {
            'total_syncs': self.total_syncs,
            'successful_syncs': self.successful_syncs,
            'success_rate': (self.successful_syncs / self.total_syncs * 100) if self.total_syncs > 0 else 0,
            'total_files_synced': self.total_files_synced,
            'total_bytes_synced': self.total_bytes_synced,
            'last_sync_time': self.last_sync_time,
            'sync_errors': self.sync_errors,
            'is_online': self.is_online,
            'next_sync_time': self.last_sync_time + self.sync_interval
        }
    
    def run(self):
        """Main sync loop"""
        self.logger.info("Starting Google Drive sync daemon")
        self.running = True
        
        # Check rclone configuration
        if not self.check_rclone_config():
            self.logger.error("Invalid rclone configuration. Exiting.")
            return
        
        # Initial network check
        self.check_network_status()
        
        # Main sync loop
        try:
            while self.running:
                current_time = time.time()
                
                # Check if it's time to sync
                if current_time - self.last_sync_time >= self.sync_interval:
                    
                    # Check network status if monitoring enabled
                    if self.monitor_network:
                        if not self.check_network_status():
                            if self.offline_behavior == 'pause':
                                self.logger.info("Offline, pausing sync")
                                time.sleep(60)  # Wait a minute before rechecking
                                continue
                            elif self.offline_behavior == 'shutdown':
                                self.logger.info("Offline, shutting down sync")
                                break
                            # For 'continue', we just proceed and let rclone handle the error
                    
                    # Check if we have too many consecutive errors
                    if self.sync_errors >= self.max_sync_errors:
                        self.logger.error(f"Too many consecutive sync errors ({self.sync_errors}). "
                                        f"Waiting before retry.")
                        time.sleep(self.sync_interval * 2)  # Wait longer after repeated failures
                        self.sync_errors = 0  # Reset counter
                        continue
                    
                    # Perform synchronization
                    self.perform_sync()
                
                # Wait before next check
                time.sleep(60)  # Check every minute
                
                # Log status periodically
                if int(current_time) % 600 == 0:  # Every 10 minutes
                    stats = self.get_sync_stats()
                    self.logger.info(f"Sync stats: {stats['successful_syncs']}/{stats['total_syncs']} "
                                   f"successful ({stats['success_rate']:.1f}%)")
                
        except KeyboardInterrupt:
            self.logger.info("Sync interrupted by user")
        except Exception as e:
            self.logger.error(f"Error in sync loop: {e}")
        finally:
            self.stop()
    
    def stop(self):
        """Stop sync daemon"""
        self.logger.info("Stopping Google Drive sync daemon")
        self.running = False
        
        # Log final statistics
        stats = self.get_sync_stats()
        self.logger.info(f"Final sync statistics:")
        self.logger.info(f"  Total syncs: {stats['total_syncs']}")
        self.logger.info(f"  Successful syncs: {stats['successful_syncs']}")
        self.logger.info(f"  Success rate: {stats['success_rate']:.1f}%")
        self.logger.info(f"  Total files synced: {stats['total_files_synced']}")
        self.logger.info(f"  Total bytes synced: {stats['total_bytes_synced']}")
        
        self.logger.info("Google Drive sync daemon stopped")

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
        sync_daemon = GoogleDriveSync(config_path)
        sync_daemon.run()
    except Exception as e:
        print(f"Error starting sync daemon: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
