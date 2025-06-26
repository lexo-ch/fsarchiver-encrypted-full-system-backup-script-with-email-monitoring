# Ultimate Linux Full System Backup Script

## Overview

This repository contains a powerful, open-source bash script for creating secure, encrypted, and automated full system backups on Linux. Our solution addresses the critical need for reliable, efficient, and flexible backup strategies in Linux environments with intelligent drive selection and comprehensive error handling.

### Key Features

- **Live System Backups**: Create full backups without rebooting or interrupting system operations
- **Full Disk Image Creation**: Generate complete disk images while the system is running
- **Intelligent Drive Selection**: Automatically selects the optimal backup drive from multiple configured drives
- **Multi-Drive Support**: Supports both local drives (UUID-based) and network drives (SMB/CIFS, NFS)
- **Automatic Versioning**: Timestamped backups with configurable retention of old versions
- **Email Notifications**: Comprehensive status updates with success, error, and interruption notifications
- **Secure Encrypted Backups**: Optional encryption with external password file support
- **LUKS Support**: Backup Linux Unified Key Setup (LUKS) encrypted volumes seamlessly
- **Flexible Restoration**: Restore backups to volumes smaller than the original source
- **Signal Handling**: Graceful handling of interruptions (CTRL+C, SIGTERM) with proper cleanup
- **Comprehensive Path Exclusions**: Extensive built-in exclusion list for cache, temp, and system files
- **Backup Validation**: Multiple layers of error detection and file integrity checking
- **Open Source**: Free to use, modify, and distribute

## Main Components

1. **FSArchiver**: The core backup utility, known for its efficiency and security features
2. **SSMTP**: Handles email notifications with automatic configuration validation
3. **Drive Detection**: UUID-based local drive detection and network path recognition
4. **Version Management**: Automatic cleanup of old backup versions with configurable retention
5. **Error Handling**: Multi-layer error detection including exit codes, log analysis, and file validation
6. **Signal Management**: Proper cleanup of incomplete backups and temporary mount points
7. **Logging**: Comprehensive logging for troubleshooting and audit purposes

## Getting Started

### Prerequisites

- A Linux system with root access
- FSArchiver installed (`sudo apt install fsarchiver` on Debian-based systems)
- SSMTP installed and configured for email notifications (`sudo apt install ssmtp`)

### Installation

1. **Clone this repository**: `git clone https://github.com/lexo-ch/fsarchiver-encrypted-full-system-backup-script-with-email-monitoring.git`
2. **Navigate to the script directory**: `cd fsarchiver-encrypted-full-system-backup-script-with-email-monitoring`
3. **Make the script executable**: `chmod +x backup_script.sh`

### Configuration

1. **Open the script in a text editor**: `nano backup_script.sh`
2. Configure the following parameters:

#### Essential Configuration
- `BACKUP_PARAMETERS`: Define backup sources and targets (supports both mount points and device paths)
- `BACKUP_DRIVE_UUIDS`: Array of UUIDs for local drives and network paths for network drives
- `VERSIONS_TO_KEEP`: Number of backup versions to retain per backup type
- `BACKUP_LOG`: Set the path for log files

#### Optional Configuration
- `PASSWORD_FILE`: Specify the location of the encryption password file (optional)
- Email settings (`MAIL_FROM`, `MAIL_TO`, `MAIL_SUBJECT_*`, `MAIL_BODY_*`)
- `EXCLUDE_PATHS`: Comprehensive list of paths to exclude from backups (pre-configured)
- `ZSTD_COMPRESSION_VALUE`: Adjust compression level (0-22, default: 5)

3. **Configure SSMTP**: Edit `/etc/ssmtp/ssmtp.conf` with your email server settings
4. Save and exit the editor

### Usage

1. Run the script with root privileges: `sudo ./backup_script.sh`

## Detailed Features

### Intelligent Drive Selection

The script automatically selects the best available backup drive from your configured list:
- **Multiple Drive Support**: Configure multiple backup drives (local and network)
- **Smart Selection**: Chooses the drive with the oldest newest backup to distribute backup load
- **Drive Validation**: Ensures backup drive is different from source drives (for local drives)
- **Network Drive Support**: Seamlessly handles SMB/CIFS and NFS mounted network drives

### Live System Backups

Our script leverages FSArchiver's capabilities to create full system backups without the need for downtime or reboots. This ensures continuous system availability, crucial for production environments.

### Automatic Versioning and Cleanup

- **Timestamped Backups**: Each backup gets a unique timestamp (YYYYMMDD-HHMMSS)
- **Automatic Cleanup**: Maintains only the configured number of recent versions
- **Version Analysis**: Compares backup ages across multiple drives for optimal selection

### Encryption and Security

Backups can be encrypted using a password stored in a separate, secure file. This adds an extra layer of protection for your sensitive data while keeping the password separate from the script.

### Comprehensive Error Handling

Multiple layers of error detection ensure backup reliability:
- **FSArchiver Exit Codes**: Monitors process exit status
- **Log Analysis**: Scans backup logs for error keywords
- **File Validation**: Checks backup file existence and minimum size
- **Mount Point Cleanup**: Automatically cleans up temporary fsarchiver mount points

### Signal Handling and Interruption Management

- **Graceful Interruption**: Handles CTRL+C, SIGTERM, and SIGHUP signals
- **Cleanup on Exit**: Removes incomplete backup files and cleans up mount points
- **Process Management**: Properly terminates fsarchiver processes on interruption
- **Email Notifications**: Sends interruption notifications with runtime details

### Email Notifications

Stay informed about your backup processes with detailed email notifications:
- **Success Notifications**: Detailed completion reports with runtime statistics
- **Error Alerts**: Comprehensive error reports with diagnostic information
- **Interruption Notices**: Notifications when backups are manually interrupted
- **SSMTP Validation**: Automatic checking of email configuration before backup starts

### Advanced Path Exclusions

Comprehensive built-in exclusion list covering:
- **Cache Directories**: All variants of cache folders (cache, Cache, .cache, etc.)
- **Temporary Files**: System and application temporary directories
- **Log Files**: System logs and application logs
- **Development Files**: Node modules, build directories, package caches
- **Virtual Filesystems**: /proc, /sys, /dev, /run
- **Container Data**: Docker and Podman data directories
- **Flatpak/Snap Caches**: Application-specific caches that can be regenerated

## Performance Tuning

The script uses ZSTD compression with configurable levels:

- **Higher compression levels (15-22)**: Better compression ratios, slower backup times, "ultra" settings
- **Medium levels (5-10)**: Balanced compression and speed (recommended)
- **Lower levels (1-4)**: Faster backups with less compression
- **Level 0**: No compression (fastest)

Modify the `ZSTD_COMPRESSION_VALUE` in the script to balance between backup size and speed.

## Network Drive Configuration

The script supports both local and network backup drives:

### Local Drives
- Use UUID-based identification: `lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT`
- Configure in `BACKUP_DRIVE_UUIDS` array with the drive UUID

### Network Drives
- **SMB/CIFS**: Format as `//server/share` or `//ip-address/share`
- **NFS**: Format as `server:/path` or `ip-address:/path`
- Must be mounted before running the script
- Script validates network connectivity and write permissions

## Backup Validation

Multiple validation layers ensure backup integrity:
- **File Creation**: Verifies backup files are actually created
- **Size Validation**: Ensures backup files meet minimum size requirements
- **Process Monitoring**: Tracks fsarchiver process status and exit codes
- **Log Analysis**: Scans for error patterns in backup logs

## Troubleshooting

Common issues and solutions:

1. **Permission Denied Errors**: Ensure you're running the script with sudo or as root
2. **Email Notifications Not Working**: Script validates SSMTP configuration and provides specific error messages
3. **Backup Failing for Specific Partitions**: Verify the partition paths in `BACKUP_PARAMETERS`
4. **Out of Space Errors**: Script detects and reports insufficient disk space errors
5. **Network Drive Issues**: Check network connectivity and mount status
6. **Mount Point Cleanup**: Script automatically handles fsarchiver temporary mount points

For more detailed troubleshooting, check the log file specified in `BACKUP_LOG`.

## Best Practices

1. **Test Your Backups**: Regularly test your backups by performing test restores
2. **Multiple Locations**: Store backups in multiple locations (local and off-site/network)
3. **Password Security**: Store encryption passwords on encrypted volumes with restricted access
4. **Regular Updates**: Keep the script and FSArchiver updated to the latest versions
5. **Monitor Logs**: Check backup logs for any recurring issues or anomalies
6. **Drive Rotation**: Configure multiple backup drives for redundancy
7. **Schedule Backups**: Use cron to schedule regular automated backups
8. **Network Reliability**: Ensure stable network connections for network drive backups

## Cloud Integration

While not built-in, you can easily extend the script to integrate with cloud storage solutions:

1. Install and configure a tool like `rclone`
2. Add a command at the end of the script to sync your backup files to your preferred cloud storage: `rclone copy /path/to/backup remote:backup-folder`

## License

This project is open-source and free to use. There is no specific license attached, meaning you can use, modify, and distribute it freely. However, we appreciate attribution if you find this script helpful.

## Disclaimer

This script is provided as-is, without any warranty or guarantee. Users should understand that they are using this script at their own risk. We do not take any responsibility or liability for any data loss, system damage, or any other issues that may arise from the use of this script. It is strongly recommended to thoroughly test the script in a non-production environment before using it on critical systems. Always ensure you have multiple backups of your important data using various methods.

## Further Resources

* [FSArchiver Documentation](https://www.fsarchiver.org/documentation/)
* [Arch Linux FSArchiver Wiki](https://wiki.archlinux.org/index.php/Fsarchiver)
* [FSArchiver Man Page](https://linux.die.net/man/8/fsarchiver)
* [Our Comprehensive Blog Post](https://www.lexo.ch/blog/2024/07/ultimate-linux-full-system-backup-secure-encrypted-live-image-backups-with-free-opensource-software-and-backup-monitoring/)

For more information and detailed explanations, please refer to our comprehensive blog post linked above.
