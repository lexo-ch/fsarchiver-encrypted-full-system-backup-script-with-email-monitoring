# Ultimate Linux Full System Backup Script

## Overview

This repository contains a powerful, open-source bash script for creating secure, encrypted, and live full system backups on Linux. Our solution addresses the critical need for reliable, efficient, and flexible backup strategies in Linux environments.

### Key Features

- **Live System Backups**: Create full backups without rebooting or interrupting system operations
- **Full Disk Image Creation**: Generate complete disk images while the system is running
- **Customizable Backup Targets**: Easily configure backups for different partitions and drives
- **Email Notifications**: Receive status updates about your backup processes
- **Secure Encrypted Backups**: Protect your data with strong encryption
- **LUKS Support**: Backup Linux Unified Key Setup (LUKS) encrypted volumes seamlessly
- **Flexible Restoration**: Restore backups to volumes smaller than the original source
- **Open Source**: Free to use, modify, and distribute

## Main Components

1. **FSArchiver**: The core backup utility, known for its efficiency and security features
2. **SSMTP**: Handles email notifications to keep you informed about backup status
3. **Customizable Parameters**: Easily adjust backup targets, exclusion paths, and other settings
4. **Error Checking**: Robust mechanisms to detect and report issues during the backup process
5. **Logging**: Comprehensive logging for troubleshooting and audit purposes

## Getting Started

### Prerequisites

- A Linux system with root access
- FSArchiver installed (`sudo apt install fsarchiver` on Debian-based systems)
- SSMTP installed for email notifications (`sudo apt install ssmtp`)

### Installation

1. **Clone this repository**: `git clone https://github.com/lexo-ch/fsarchiver-encrypted-full-system-backup-script-with-email-monitoring.git`
2. **Navigate to the script directory**: `cd fsarchiver-encrypted-full-system-backup-script-with-email-monitoring`
3. **Make the script executable**: `chmod +x backup_script.sh`

### Configuration

1. **Open the script in a text editor**: `nano backup_script.sh`
2. Configure the following parameters:
- `BACKUP_PARAMETERS`: Define backup sources and targets
- `BACKUP_LOG`: Set the path for log files
- `PASSWORD_FILE`: Specify the location of the encryption password file
- Email settings (`MAIL_FROM`, `MAIL_TO`, etc.)
- `EXCLUDE_PATHS`: List paths to exclude from backups
- `ZSTD_COMPRESSION_VALUE`: Adjust compression level (0-22)

3. Save and exit the editor

### Usage

1. Run the script with root privileges: `sudo ./backup_script.sh`

## Detailed Features

### Live System Backups

Our script leverages FSArchiver's capabilities to create full system backups without the need for downtime or reboots. This ensures continuous system availability, crucial for production environments.

### Encryption and Security

Backups are encrypted using a password stored in a separate, secure file. This adds an extra layer of protection for your sensitive data.

### LUKS Volume Support

The script can handle LUKS encrypted volumes, ensuring that your encrypted data remains secure throughout the backup process.

### Flexible Restoration

Unlike some backup solutions, our script allows you to restore backups to volumes smaller than the original source, providing flexibility in storage management and system migrations.

### Email Notifications

Stay informed about your backup processes with detailed email notifications. The script uses SSMTP to send alerts for both successful backups and any errors encountered.

### Customizable Exclusions

Easily specify paths to exclude from your backups, allowing you to skip temporary files, mounted volumes, or any other directories you don't need to back up.

## Performance Tuning

The script uses ZSTD compression, which you can adjust for your specific needs:

- Higher compression levels (e.g., 15-22) provide better compression but slower backup times
- Lower levels (e.g., 1-5) offer faster backups with less compression

Modify the `ZSTD_COMPRESSION_VALUE` in the script to balance between backup size and speed.

## Cloud Integration

While not built-in, you can easily extend the script to integrate with cloud storage solutions:

1. Install and configure a tool like `rclone`
2. Add a command at the end of the script to sync your backup files to your preferred cloud storage: `rclone copy /path/to/backup remote:backup-folder`

## Troubleshooting

Common issues and solutions:

1. **Permission Denied Errors**: Ensure you're running the script with sudo or as root
2. **Email Notifications Not Working**: Check your SSMTP configuration and email provider settings
3. **Backup Failing for Specific Partitions**: Verify the partition paths in `BACKUP_PARAMETERS`
4. **Out of Space Errors**: Ensure sufficient free space on the backup destination drive

For more detailed troubleshooting, check the log file specified in `BACKUP_LOG`.

## Best Practices

1. Regularly test your backups by performing test restores
2. Store backups in multiple locations (local and off-site)
3. Rotate your encryption passwords periodically
4. Keep the script and FSArchiver updated to the latest versions
5. Monitor your backup logs for any recurring issues or anomalies

## Contributing

We welcome contributions, issues, and feature requests! Feel free to check our [issues page](https://github.com/lexo-ch/fsarchiver-encrypted-full-system-backup-script-with-email-monitoring/issues) if you want to contribute.

To contribute:

1. Fork the repository
2. Create a new branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

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
