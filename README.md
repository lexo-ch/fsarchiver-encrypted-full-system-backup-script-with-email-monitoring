# Ultimate Linux Full System Backup Script

## Overview

This repository contains a powerful, open-source bash script for creating secure, encrypted, and live full system backups on Linux. 

Key features include:
- Live system backups without rebooting
- Full disk image creation while the system is running
- Customizable for different partitions and drives
- Email notifications for backup status
- Secure encrypted backups
- LUKS (Linux Unified Key Setup) encrypted volume support

## Main Components

- FSArchiver for efficient and secure backups
- SSMTP for email notifications
- Customizable backup parameters and exclusion paths
- Error checking and logging mechanisms

## Getting Started

1. Clone this repository
2. Configure the script parameters (backup targets, email settings, etc.)
3. Install dependencies (FSArchiver, SSMTP)
4. Run the script with root privileges

## Detailed Guide

For a comprehensive explanation of the script, including setup instructions, performance tuning, cloud integration, and best practices, please refer to our [full blog post](https://www.lexo.ch/blog/2024/07/ultimate-linux-full-system-backup-secure-encrypted-live-image-backups-with-free-opensource-software-and-backup-monitoring/).

## Disclaimer

This script is provided as-is, without any warranty. Use at your own risk and always test thoroughly in a non-production environment before deploying to critical systems.

## Contributing

Contributions, issues, and feature requests are welcome. Feel free to check [issues page](link-to-your-issues-page) if you want to contribute.

## License

None, Use it freely!
