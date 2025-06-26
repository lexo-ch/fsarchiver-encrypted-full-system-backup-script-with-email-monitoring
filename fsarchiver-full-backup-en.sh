#!/bin/bash

#####################################################################
# AUTOMATED BACKUP SCRIPT WITH FSARCHIVER AND VERSIONING
#####################################################################
# This script creates automated backups of filesystems
# with fsarchiver and supports:
# - UUID-based detection of local backup drives
# - Network drives (SMB/CIFS, NFS) via network path detection
# - Intelligent selection of optimal backup drive
# - Automatic versioning with configurable number of versions to keep
# - Encrypted archives (optional)
# - Email notifications with configurable messages
# - Exclusion of specific paths from backup
# - ZSTD compression with configurable level
# - Backup validation (file size and existence)
# - Protection against backing up to same drive as source
# - Handling of temporary fsarchiver mount points
# - SSMTP configuration checking
# - Proper handling of interruptions (CTRL+C, SIGTERM, etc.)
#####################################################################

#####################################################################
# USER CONFIGURATION
#####################################################################

# Backup Parameters Configuration
# Format: BACKUP_PARAMETERS["Backup Name"]="Backup-File-Base-Name:Mount-Point or Device-Path for Backup"
# IMPORTANT: The backup file name is only the base name. The script automatically adds
# a timestamp for versioning (e.g. backup-efi-20250625-123456.fsa)
declare -A BACKUP_PARAMETERS
BACKUP_PARAMETERS["EFI"]="backup-efi:/boot/efi"
BACKUP_PARAMETERS["System"]="backup-root:/"

# BACKUP_PARAMETERS["DATA"]="backup-data:/media/username/DATA"  # Example - commented out

# UUID array for local backup drives and network paths for network drives
# 
# LOCAL DRIVES:
# Add the UUIDs of your local backup drives here
# To find the UUID of a drive, use the command:
# lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT
#
# NETWORK DRIVES:
# Add the network paths of your mounted network drives here
# Format for SMB/CIFS: "//server/share" or "//ip-address/share"
# Format for NFS: "server:/path" or "ip-address:/path"
# 
# The script automatically detects whether it's a local drive (UUID) or
# network drive (contains slashes).
#
# IMPORTANT FOR NETWORK DRIVES:
# - The network drive must already be mounted before the script is executed
# - The script checks if the network drive is available and writable
# - Use the exact path as shown by findmnt
BACKUP_DRIVE_UUIDS=(
    "12345678-1234-1234-1234-123456789abc"     # Local USB drive (UUID) - REPLACE WITH YOUR UUID
    "//your-server.local/backup"               # SMB network drive - REPLACE WITH YOUR PATH
    # "192.168.1.100:/mnt/backup"              # NFS network drive example - UNCOMMENT AND EDIT
)

# Versioning Configuration
# Number of backup versions to keep per backup type
# The script creates timestamped backups (e.g. backup-efi-20250625-123456.fsa)
# and keeps the latest X versions. Older versions are automatically deleted.
# 
# BACKUP DRIVE SELECTION WITH MULTIPLE AVAILABLE DRIVES:
# The script compares the newest backup of each type on all available
# drives (local and network) and selects the drive whose newest backup 
# is oldest. This ensures that the drive that most urgently needs an update is used.
VERSIONS_TO_KEEP=1

# Backup Log File Location
BACKUP_LOG="/var/log/fsarchiver-bkp.log"

# Password File Location (OPTIONAL)
# For increased security, this file should be stored on an encrypted volume 
# with root-only access
# Comment out this line to create backups without encryption
# PASSWORD_FILE="/root/backup-password.txt"

# Email Configuration for Notifications
# Set the user for email sending. The script uses ssmtp.
# Remember to edit /etc/ssmtp/ssmtp.conf and set the following options:
## mailhub=your-mailserver.tld:587
## hostname=your-desired-hostname
## FromLineOverride=YES                    ### Important so the script can set the correct sender name
## UseSTARTTLS=YES                         ### Standard for mail sending via port 587
## UseTLS=NO
## AuthUser=your-username@your-domain.tld
## AuthPass=your-email-account-password
MAIL_FROM="backup-system <backup@your-domain.tld>"
MAIL_TO="admin@your-domain.tld"
MAIL_SUBJECT_ERROR="[ERROR] Backup Error on $(hostname)"
MAIL_SUBJECT_SUCCESS="[SUCCESS] Backup on $(hostname) completed successfully"
MAIL_SUBJECT_INTERRUPTED="[INTERRUPTED] Backup on $(hostname) was interrupted"

# Email Content Configuration
# Available placeholders: {BACKUP_DATE}, {RUNTIME_MIN}, {RUNTIME_SEC}, {ERROR_DETAILS}
MAIL_BODY_SUCCESS="Backup completed successfully on: {BACKUP_DATE}\nRuntime: {RUNTIME_MIN} minutes and {RUNTIME_SEC} seconds."
MAIL_BODY_ERROR="Backup failed!\n\nBackup start: {BACKUP_DATE}\nRuntime: {RUNTIME_MIN} minutes and {RUNTIME_SEC} seconds.\n\nERROR REPORT:\n{ERROR_DETAILS}"
MAIL_BODY_INTERRUPTED="Backup was interrupted!\n\nBackup start: {BACKUP_DATE}\nInterrupted after: {RUNTIME_MIN} minutes and {RUNTIME_SEC} seconds.\n\nThe backup was terminated by user intervention (CTRL+C) or system signal.\nIncomplete backup files have been removed."

# Paths to exclude from backup
# 
# IMPORTANT: HOW FSARCHIVER EXCLUSIONS WORK:
# =====================================================
# 
# fsarchiver uses shell wildcards (glob patterns) for exclusions.
# The patterns are matched against the FULL PATH from the ROOT of the backed up filesystem.
# 
# CASE-SENSITIVITY:
# ==========================================
# The patterns are CASE-SENSITIVE!
# - "*/cache/*" does NOT match "*/Cache/*" or "*/CACHE/*"
# - For both variants: "*/[Cc]ache/*" or use separate patterns
# - Common variants: cache/Cache, temp/Temp, tmp/Tmp, log/Log
# 
# EXAMPLES:
# ---------
# For a path like: /home/user/.var/app/com.adobe.Reader/cache/fontconfig/file.txt
# 
# ✗ WRONG: "/cache/*"           - Does NOT match, as /cache is not at root
# ✗ WRONG: "cache/*"            - Does NOT match, as it doesn't cover the full path  
# ✓ CORRECT: "*/cache/*"        - Matches ANY cache directory at any level
# ✓ CORRECT: "/home/*/cache/*"  - Matches cache directories in any user directory
# ✓ CORRECT: "*/.var/*/cache/*" - Matches special .var application caches
# ✓ CORRECT: "*[Cc]ache*"       - Matches both "cache" and "Cache"
# 
# MORE PATTERN EXAMPLES:
# -------------------------
# "*.tmp"              - All .tmp files
# "/tmp/*"             - Everything in /tmp directory
# "*/logs/*"           - All logs directories at any level
# "/var/log/*"         - Everything in /var/log
# "*/.cache/*"         - All .cache directories (common in user directories)
# "*/Trash/*"          - Trash directories
# "*~"                 - Backup files (ending with ~)
# "*/tmp/*"            - All tmp directories
# "*/.thumbnails/*"    - Thumbnail caches
# 
# PERFORMANCE TIP:
# -----------------
# Specific patterns are more efficient than very general patterns.
# Use "*/cache/*" instead of "*cache*" when possible.
# Use general patterns before specific patterns.
#
# CONSOLIDATED LINUX EXCLUSION LIST:
# =====================================
EXCLUDE_PATHS=(
    # ===========================================
    # CACHE DIRECTORIES (ALL VARIANTS)
    # ===========================================
    
    # General cache directories (covers most browsers and apps)
    "*/cache/*"                     # All cache directories (lowercase)
    "*/Cache/*"                     # All Cache directories (uppercase)  
    "*/.cache/*"                    # Hidden cache directories (Linux standard)
    "*/.Cache/*"                    # Hidden Cache directories (uppercase)
    "*/caches/*"                    # Plural form cache directories
    "*/Caches/*"                    # Plural form Cache directories (uppercase)
    "*/cache2/*"                    # Browser Cache2 directories (Firefox, etc.)
    
    # Specific cache directories (more robust patterns)
    "/root/.cache/*"                # Root user cache (specific)
    "/home/*/.cache/*"              # All user cache directories (specific)
    "*/mesa_shader_cache/*"         # Mesa GPU shader cache
    
    # Special cache types
    "*/.thumbnails/*"               # Thumbnail caches
    "*/thumbnails/*"                # Thumbnail caches (without dot)
    "*/GrShaderCache/*"             # Graphics shader cache (browser/games)
    "*/GPUCache/*"                  # GPU cache (browser)
    "*/ShaderCache/*"               # Shader cache (games/graphics)
    "*/Code\ Cache/*"               # Code cache (Chrome/Chromium/Electron apps)
    
    # ===========================================
    # TEMPORARY DIRECTORIES AND FILES
    # ===========================================
    
    # Standard temporary directories
    "/tmp/*"                        # Temporary files
    "/var/tmp/*"                    # Variable temporary files
    "*/tmp/*"                       # All tmp directories
    "*/Tmp/*"                       # All Tmp directories (uppercase)
    "*/temp/*"                      # All temp directories
    "*/Temp/*"                      # All Temp directories (uppercase)
    "*/TEMP/*"                      # All TEMP directories (uppercase)
    "*/.temp/*"                     # Hidden temp directories
    "*/.Temp/*"                     # Hidden Temp directories (uppercase)
    
    # Browser-specific temporary directories
    "*/Greaselion/Temp/*"           # Brave browser Greaselion temp directories
    "*/BraveSoftware/*/Cache/*"     # Brave browser cache
    "*/BraveSoftware/*/cache/*"     # Brave browser cache (lowercase)
    
    # Temporary files
    "*.tmp"                         # Temporary files
    "*.temp"                        # Temporary files
    "*.TMP"                         # Temporary files (uppercase)
    "*.TEMP"                        # Temporary files (uppercase)
    
    # ===========================================
    # LOG DIRECTORIES AND FILES
    # ===========================================
    
    # System logs
    "/var/log/*"                    # System log files (general)
    "/var/log/journal/*"            # SystemD journal logs (can become very large)
    "*/logs/*"                      # All log directories
    "*/Logs/*"                      # All Log directories (uppercase)
    
    # Log files
    "*.log"                         # Log files
    "*.log.*"                       # Rotated log files
    "*.LOG"                         # Log files (uppercase)
    "*/.xsession-errors*"           # X-session logs
    "*/.wayland-errors*"            # Wayland session logs
    
    # ===========================================
    # SYSTEM CACHE AND SPOOL
    # ===========================================
    
    # NOTE: All /var/cache/* patterns are covered by */cache/*
    "/var/spool/*"                  # Spool directories (print jobs, etc.)
    
    # ===========================================
    # MOUNT POINTS AND VIRTUAL FILESYSTEMS
    # ===========================================
    
    # External drives and mount points
    "/media/*"                      # External drives
    "/mnt/*"                        # Mount points
    "/run/media/*"                  # Modern mount points
    
    # Virtual filesystems (should not be in backups)
    "/proc/*"                       # Process information
    "/sys/*"                        # System information  
    "/dev/*"                        # Device files
    "/run/*"                        # Runtime information
    "/var/run/*"                    # Runtime variable files (usually symlink to /run)
    "/var/lock/*"                   # Lock files (usually symlink to /run/lock)
    
    # ===========================================
    # DEVELOPMENT AND BUILD DIRECTORIES
    # ===========================================
    
    # Node.js and JavaScript
    "*/node_modules/*"              # Node.js packages
    "*/.npm/*"                      # NPM cache
    "*/.yarn/*"                     # Yarn cache
    
    # Rust
    "*/target/debug/*"              # Rust debug builds
    "*/target/release/*"            # Rust release builds
    "*/.cargo/registry/*"           # Rust cargo registry cache
    
    # Go
    "*/.go/pkg/*"                   # Go package cache
    
    # Build directories (general)
    "*/target/*"                    # Rust/Java build directories (general)
    "*/build/*"                     # Build directories
    "*/Build/*"                     # Build directories (uppercase)
    "*/.gradle/*"                   # Gradle cache
    "*/.m2/repository/*"            # Maven repository
    
    # Python
    "*/__pycache__/*"               # Python cache
    "*/.pytest_cache/*"             # Pytest cache
    "*.pyc"                         # Python compiled files
    
    # ===========================================
    # CONTAINERS AND VIRTUALIZATION
    # ===========================================
    
    "/var/lib/docker/*"             # Docker data
    "/var/lib/containers/*"         # Podman/container data
    
    # ===========================================
    # FLATPAK AND SNAP CACHE DIRECTORIES
    # ===========================================
    
    # Flatpak repository and cache (safe to exclude - can be re-downloaded)
    "/var/lib/flatpak/repo/*"       # OSTree repository objects (like Git objects)
    "/var/lib/flatpak/.refs/*"      # OSTree references
    "/var/lib/flatpak/system-cache/*" # System cache
    "/var/lib/flatpak/user-cache/*" # User cache
    
    # Flatpak app-specific caches (user directories)
    "/home/*/.var/app/*/cache/*"    # App-specific caches
    "/home/*/.var/app/*/Cache/*"    # App-specific caches (uppercase)
    "/home/*/.var/app/*/.cache/*"   # Hidden caches in apps
    "*/.var/app/*/cache/*"          # All Flatpak app caches
    "*/.var/app/*/Cache/*"          # All Flatpak app caches (uppercase)
    
    # Snap cache directories
    "/var/lib/snapd/cache/*"        # Snap cache
    "/home/*/snap/*/common/.cache/*" # Snap app caches
    
    # OPTIONAL - If you don't want to reinstall Flatpak apps, 
    # comment out these lines:
    # "/var/lib/flatpak/runtime/*"  # Runtime environments (can be reinstalled)
    # "/var/lib/flatpak/app/*"      # Installed apps (can be reinstalled)
    
    # ===========================================
    # BACKUP AND OLD FILES
    # ===========================================
    
    # Backup files
    "*~"                            # Backup files (editor backups - always exclude)
    
    # Backup files (OPTIONAL - uncomment if backup files should be kept)
    # "*.bak"                       # Backup files
    # "*.BAK"                       # Backup files (uppercase)
    # "*.backup"                    # Backup files
    # "*.BACKUP"                    # Backup files (uppercase)
    # "*.old"                       # Old files
    # "*.OLD"                       # Old files (uppercase)
    
    # ===========================================
    # TRASH (OPTIONAL - commented out, as trash should be backed up by default)
    # ===========================================
    
    # NOTE: Trash directories are NOT excluded by default,
    # as they may contain important deleted files that need to be restored.
    # Uncomment these lines only if you're sure the trash
    # should not be backed up:
    
    # "*/.Trash/*"                  # Trash
    # "*/Trash/*"                   # Trash (without dot)
    # "*/.local/share/Trash/*"      # Trash (modern Linux location)
    # "*/RecycleBin/*"              # Windows-style trash (if present)
    
    # ===========================================
    # SWAP FILES
    # ===========================================
    
    "/swapfile"                     # Standard swap file
    "/swap.img"                     # Alternative swap file
    "*.swap"                        # Swap files
    "*.SWAP"                        # Swap files (uppercase)
    
    # ===========================================
    # OTHER COMMON EXCLUSIONS
    # ===========================================
    
    # Other common exclusions
    # NOTE: Specific Flatpak/Snap cache patterns are redundant, as already covered by 
    # */cache/* and */.cache/*
    
    # Lock and socket files
    "*/.X11-unix/*"                 # X11 sockets
    "*/lost+found/*"                # Lost+found directories
    "*/.gvfs/*"                     # GVFS mount points
    
    # Multimedia caches
    "*/.dvdcss/*"                   # DVD CSS cache
    "*/.mplayer/*"                  # MPlayer cache
    "*/.adobe/Flash_Player/*"       # Flash Player cache
    
    # Encrypted directories when unmounted
    "*/.ecryptfs/*"                 # eCryptFS
    
    # ===========================================
    # LARGE IMAGE FILES (OPTIONAL - commented out as they can be very large)
    # ===========================================
    
    # NOTE: These patterns are commented out, as image files often
    # contain important data. Uncomment these only if you're sure
    # these files should not be backed up:
    
    # "*.iso"                       # ISO image files 
    # "*.img"                       # Disk image files
    # "*.vdi"                       # VirtualBox images (can be very large)
    # "*.vmdk"                      # VMware images (can be very large)
    
    # Games and Steam (specific caches/logs not covered by */cache/*)
    "*/.steam/steam/logs/*"         # Steam logs
    "*/.steam/steam/dumps/*"        # Steam crash dumps
    "*/.local/share/Steam/logs/*"   # Steam logs (alternative location)
)

# ZSTD compression level (0-22)
# 0 = no compression, 1 = fastest/worst compression, 22 = slowest/best compression
# Default is 3. Values above 19 are considered "ultra" settings and should be used carefully.
ZSTD_COMPRESSION_VALUE=5

#####################################################################
# SYSTEM FUNCTIONS AND HELPER FUNCTIONS
#####################################################################

# Color codes for formatted output
RED='\033[1;31;43m'     # Bold red text on yellow background for maximum visibility of errors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables for error handling and signal handling
ERROR=0
ERROR_MSG=""
SCRIPT_INTERRUPTED=false
CURRENT_BACKUP_FILE=""
CURRENT_FSARCHIVER_PID=""

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Script must be run as root. Exiting...${NC}"
   exit 1
fi

#####################################################################
# SIGNAL HANDLING AND CLEANUP FUNCTIONS
#####################################################################

# Function to clean up on interruption
cleanup_on_interrupt() {
    echo -e "\n${YELLOW}Backup interruption detected...${NC}"
    SCRIPT_INTERRUPTED=true
    ERROR=1
    ERROR_MSG+="Backup was interrupted by user intervention or system signal.\n"
    
    # Try to terminate fsarchiver process if still active
    if [[ -n "$CURRENT_FSARCHIVER_PID" ]]; then
        echo -e "${YELLOW}Terminating fsarchiver process (PID: $CURRENT_FSARCHIVER_PID)...${NC}"
        kill -TERM "$CURRENT_FSARCHIVER_PID" 2>/dev/null
        sleep 2
        # If process is still running, force kill
        if kill -0 "$CURRENT_FSARCHIVER_PID" 2>/dev/null; then
            echo -e "${YELLOW}Force terminating fsarchiver process...${NC}"
            kill -KILL "$CURRENT_FSARCHIVER_PID" 2>/dev/null
        fi
        CURRENT_FSARCHIVER_PID=""
    fi
    
    # Remove incomplete backup file
    if [[ -n "$CURRENT_BACKUP_FILE" && -f "$CURRENT_BACKUP_FILE" ]]; then
        echo -e "${YELLOW}Removing incomplete backup file: $(basename "$CURRENT_BACKUP_FILE")${NC}"
        rm -f "$CURRENT_BACKUP_FILE"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Incomplete backup file removed${NC}"
        else
            echo -e "${RED}✗ Error removing incomplete backup file${NC}"
            ERROR_MSG+="Error removing incomplete backup file: $CURRENT_BACKUP_FILE\n"
        fi
        CURRENT_BACKUP_FILE=""
    fi
    
    # Clean up fsarchiver mount points on interruption
    echo -e "${YELLOW}Cleaning up fsarchiver mount points after interruption...${NC}"
    cleanup_fsarchiver_mounts true
    
    # Log entry for interruption
    if [[ -n "$BACKUP_LOG" ]]; then
        echo "Backup interrupted: $(date +%d.%B.%Y,%T)" >> "$BACKUP_LOG"
    fi
    
    echo -e "${YELLOW}Cleanup completed. Script will exit.${NC}"
}

# Function to send interruption email and exit
send_interrupted_mail_and_exit() {
    # Calculate runtime
    if [[ -n "$TIME_START" ]]; then
        TIME_DIFF=$(($(date +"%s")-${TIME_START}))
        RUNTIME_MINUTES=$((${TIME_DIFF} / 60))
        RUNTIME_SECONDS=$((${TIME_DIFF} % 60))
    else
        RUNTIME_MINUTES=0
        RUNTIME_SECONDS=0
    fi
    
    # Send interruption email
    local mail_body="${MAIL_BODY_INTERRUPTED}"
    mail_body="${mail_body//\{BACKUP_DATE\}/${BACKUP_START_DATE:-$(date +%d.%B.%Y,%T)}}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_INTERRUPTED\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t 2>/dev/null
    echo -e "${YELLOW}Interruption email sent${NC}"
    
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}BACKUP WAS INTERRUPTED${NC}"
    echo -e "${RED}Runtime: $RUNTIME_MINUTES minutes and $RUNTIME_SECONDS seconds${NC}"
    echo -e "${RED}========================================${NC}"
    
    exit 130  # Standard exit code for SIGINT
}

# Set up signal handlers
# Handles SIGINT (Ctrl+C), SIGTERM (termination), and SIGHUP (terminal closed)
trap 'cleanup_on_interrupt; send_interrupted_mail_and_exit' SIGINT SIGTERM SIGHUP

# Function to check SSMTP configuration
check_ssmtp_configuration() {
    echo -e "${BLUE}Checking SSMTP configuration...${NC}"
    
    # Check if ssmtp is installed
    if ! command -v ssmtp &> /dev/null; then
        echo -e "${RED}ERROR: ssmtp is not installed!${NC}"
        echo -e "${RED}Install ssmtp with the following command:${NC}"
        echo -e "${YELLOW}sudo apt update && sudo apt install ssmtp${NC}"
        echo ""
        return 1
    fi
    
    # Check if configuration file exists
    local config_file="/etc/ssmtp/ssmtp.conf"
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}ERROR: SSMTP configuration file not found: $config_file${NC}"
        echo -e "${RED}Create the configuration file and add the following settings:${NC}"
        show_ssmtp_configuration_help
        return 1
    fi
    
    # Check if important configuration parameters are set
    local required_params=("mailhub" "AuthUser" "AuthPass")
    local missing_params=()
    
    for param in "${required_params[@]}"; do
        if ! grep -q "^$param=" "$config_file" 2>/dev/null; then
            missing_params+=("$param")
        fi
    done
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        echo -e "${RED}ERROR: Missing SSMTP configuration parameters in $config_file:${NC}"
        for param in "${missing_params[@]}"; do
            echo -e "${RED}  - $param${NC}"
        done
        echo ""
        echo -e "${RED}Add the missing parameters:${NC}"
        show_ssmtp_configuration_help
        return 1
    fi
    
    # Check if configuration file is readable
    if [[ ! -r "$config_file" ]]; then
        echo -e "${RED}ERROR: SSMTP configuration file is not readable: $config_file${NC}"
        echo -e "${YELLOW}Make sure the file has the correct permissions:${NC}"
        echo -e "${YELLOW}sudo chmod 644 $config_file${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ SSMTP is installed and configured${NC}"
    return 0
}

# Function to show SSMTP configuration help
show_ssmtp_configuration_help() {
    echo -e "${YELLOW}Edit /etc/ssmtp/ssmtp.conf and set the following options:${NC}"
    echo -e "${YELLOW}mailhub=your-mailserver.tld:587${NC}"
    echo -e "${YELLOW}hostname=your-desired-hostname${NC}"
    echo -e "${YELLOW}FromLineOverride=YES${NC}"
    echo -e "${YELLOW}UseSTARTTLS=YES${NC}"
    echo -e "${YELLOW}UseTLS=NO${NC}"
    echo -e "${YELLOW}AuthUser=your-username@your-domain.tld${NC}"
    echo -e "${YELLOW}AuthPass=your-email-account-password${NC}"
    echo ""
    echo -e "${YELLOW}Example command to edit:${NC}"
    echo -e "${YELLOW}sudo nano /etc/ssmtp/ssmtp.conf${NC}"
}

# Check SSMTP configuration (Critical - script exits on errors)
if ! check_ssmtp_configuration; then
    echo -e "${RED}Critical error: SSMTP is not properly installed or configured.${NC}"
    echo -e "${RED}Email notifications are required for this backup script.${NC}"
    echo -e "${RED}Script will exit.${NC}"
    exit 1
fi

#####################################################################
# FSARCHIVER MOUNT POINT CLEANUP FUNCTIONS
#####################################################################

# Function to find all fsarchiver mount points
find_fsarchiver_mounts() {
    # Find all mount points under /tmp/fsa/ (with -r for raw output without tree formatting)
    findmnt -n -r -o TARGET | grep "^/tmp/fsa/" 2>/dev/null | sort -r || true
}

# Function to cleanly unmount fsarchiver mount points
cleanup_fsarchiver_mounts() {
    local force_cleanup="${1:-false}"
    
    echo -e "${BLUE}Searching for fsarchiver mount points...${NC}"
    
    local temp_mounts
    temp_mounts=$(find_fsarchiver_mounts)
    
    if [[ -z "$temp_mounts" ]]; then
        echo -e "${GREEN}✓ No fsarchiver mount points found${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Found fsarchiver mount points:${NC}"
    echo "$temp_mounts" | while read -r mount; do
        if [[ -n "$mount" ]]; then
            echo -e "${YELLOW}  - $mount${NC}"
        fi
    done
    
    if [[ "$force_cleanup" == "true" ]]; then
        echo -e "${BLUE}Automatic cleanup of mount points...${NC}"
        local cleanup_success=true
        
        # Unmount mount points in reverse order (deepest first)
        while IFS= read -r mount; do
            if [[ -n "$mount" ]]; then
                echo -e "${YELLOW}Unmounting: $mount${NC}"
                
                # Try normal umount
                if umount "$mount" 2>/dev/null; then
                    echo -e "${GREEN}  ✓ Successfully unmounted${NC}"
                else
                    # On failure: try lazy umount
                    echo -e "${YELLOW}  - Normal umount failed, trying lazy umount...${NC}"
                    if umount -l "$mount" 2>/dev/null; then
                        echo -e "${GREEN}  ✓ Lazy umount successful${NC}"
                    else
                        # On further failure: force umount
                        echo -e "${YELLOW}  - Lazy umount failed, trying force umount...${NC}"
                        if umount -f "$mount" 2>/dev/null; then
                            echo -e "${GREEN}  ✓ Force umount successful${NC}"
                        else
                            echo -e "${RED}  ✗ All umount attempts failed for: $mount${NC}"
                            cleanup_success=false
                        fi
                    fi
                fi
            fi
        done <<< "$temp_mounts"
        
        # Check if all mount points were removed
        sleep 1
        local remaining_mounts
        remaining_mounts=$(find_fsarchiver_mounts)
        
        if [[ -z "$remaining_mounts" ]]; then
            echo -e "${GREEN}✓ All fsarchiver mount points successfully removed${NC}"
            
            # Try to remove empty /tmp/fsa directories
            if [[ -d "/tmp/fsa" ]]; then
                echo -e "${BLUE}Cleaning up empty /tmp/fsa directories...${NC}"
                find /tmp/fsa -type d -empty -delete 2>/dev/null || true
                if [[ ! -d "/tmp/fsa" || -z "$(ls -A /tmp/fsa 2>/dev/null)" ]]; then
                    rmdir /tmp/fsa 2>/dev/null || true
                    echo -e "${GREEN}✓ /tmp/fsa directory cleaned up${NC}"
                fi
            fi
            
            return 0
        else
            echo -e "${RED}✗ Some mount points could not be removed:${NC}"
            echo "$remaining_mounts" | while read -r mount; do
                if [[ -n "$mount" ]]; then
                    echo -e "${RED}  - $mount${NC}"
                fi
            done
            return 1
        fi
    else
        echo -e "${YELLOW}Automatic cleanup not activated.${NC}"
        echo -e "${YELLOW}For manual cleanup, run:${NC}"
        echo -e "${YELLOW}sudo umount /tmp/fsa/*/media/* 2>/dev/null || true${NC}"
        echo -e "${YELLOW}sudo umount /tmp/fsa/* 2>/dev/null || true${NC}"
        return 1
    fi
}

# Check for temporary fsarchiver mount points and automatic cleanup
echo -e "${BLUE}Checking temporary fsarchiver mount points...${NC}"
if ! cleanup_fsarchiver_mounts true; then
    echo -e "${YELLOW}Warning: Some fsarchiver mount points could not be automatically removed.${NC}"
    echo -e "${YELLOW}This may cause problems. Please check manually with:${NC}"
    echo -e "${YELLOW}findmnt | grep /tmp/fsa${NC}"
    echo ""
    
    # Optional: Ask user if they want to continue anyway
    # echo -e "${YELLOW}Do you want to continue anyway? (y/N): ${NC}"
    # read -r response
    # if [[ ! "$response" =~ ^[Yy]$ ]]; then
    #     echo -e "${RED}Backup aborted.${NC}"
    #     exit 1
    # fi
fi

# Function to create timestamped backup filenames
create_timestamped_filename() {
    local base_name="$1"
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    echo "${base_name}-${timestamp}.fsa"
}

# Function to find all versions of a backup file
find_backup_versions() {
    local backup_drive="$1"
    local base_name="$2"
    
    # Search for files with pattern: base_name-YYYYMMDD-HHMMSS.fsa
    find "$backup_drive" -maxdepth 1 -name "${base_name}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].fsa" -type f 2>/dev/null | sort -r
}

# Function to find the latest version of a backup file
find_latest_backup_version() {
    local backup_drive="$1"
    local base_name="$2"
    
    find_backup_versions "$backup_drive" "$base_name" | head -n1
}

# Function to clean up old backup versions
cleanup_old_backups() {
    local backup_drive="$1"
    local base_name="$2"
    local keep_versions="$3"
    
    echo -e "${BLUE}Cleaning up old backup versions for $base_name (keeping $keep_versions versions)...${NC}"
    
    local versions
    versions=$(find_backup_versions "$backup_drive" "$base_name")
    
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}No existing backup versions found for $base_name${NC}"
        return 0
    fi
    
    local version_count
    version_count=$(echo "$versions" | wc -l)
    
    if [[ $version_count -le $keep_versions ]]; then
        echo -e "${GREEN}✓ All $version_count versions will be kept${NC}"
        return 0
    fi
    
    local versions_to_delete
    versions_to_delete=$(echo "$versions" | tail -n +$((keep_versions + 1)))
    
    echo -e "${YELLOW}Deleting $(echo "$versions_to_delete" | wc -l) old versions:${NC}"
    
    while IFS= read -r old_version; do
        if [[ -n "$old_version" ]]; then
            echo -e "${YELLOW}  - Deleting: $(basename "$old_version")${NC}"
            rm -f "$old_version"
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}    ✓ Successfully deleted${NC}"
            else
                echo -e "${RED}    ✗ Error deleting${NC}"
                ERROR=1
                ERROR_MSG+="Error deleting old backup version: $old_version\n"
            fi
        fi
    done <<< "$versions_to_delete"
}

show_available_drives() {
    echo -e "${YELLOW}Available drives for backup configuration:${NC}"
    echo -e "${BLUE}Use the following command to display all local drives:${NC}"
    echo "lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT"
    echo ""
    echo -e "${BLUE}Use the following command to display all network drives:${NC}"
    echo "findmnt -t nfs,nfs4,cifs -o TARGET,SOURCE,FSTYPE,OPTIONS"
    echo ""
    echo -e "${BLUE}Formatted output of available local drives:${NC}"
    
    # Header
    printf "%-36s | %-12s | %-8s | %-8s | %-12s | %-20s | %s\n" "UUID" "LABEL" "NAME" "SIZE GB" "VENDOR" "MODEL" "MOUNTPOINT"
    printf "%s\n" "$(printf '=%.0s' {1..120})"
    
    # List drives with formatted output
    while IFS= read -r line; do
        if [[ $line =~ ^[├└│]?─?([a-zA-Z0-9]+)[[:space:]]+([a-f0-9-]*)[[:space:]]*([^[:space:]]*)[[:space:]]*([0-9.,]+[KMGT]?)[[:space:]]*([^[:space:]]*)[[:space:]]*([^[:space:]]*)[[:space:]]*(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            uuid="${BASH_REMATCH[2]}"
            label="${BASH_REMATCH[3]}"
            size="${BASH_REMATCH[4]}"
            vendor="${BASH_REMATCH[5]}"
            model="${BASH_REMATCH[6]}"
            mountpoint="${BASH_REMATCH[7]}"
            
            # Convert size to GB if possible
            if [[ $size =~ ^([0-9.,]+)([KMGT])$ ]]; then
                num="${BASH_REMATCH[1]//,/.}"
                unit="${BASH_REMATCH[2]}"
                case $unit in
                    K) size_gb=$(echo "scale=1; $num / 1024 / 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    M) size_gb=$(echo "scale=1; $num / 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    G) size_gb="$num" ;;
                    T) size_gb=$(echo "scale=1; $num * 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    *) size_gb="$size" ;;
                esac
            else
                size_gb="$size"
            fi
            
            # Only show lines with UUID (real partitions)
            if [[ -n "$uuid" && "$uuid" != "-" ]]; then
                printf "%-36s | %-12s | %-8s | %-8s | %-12s | %-20s | %s\n" \
                    "$uuid" "$label" "$name" "$size_gb" "$vendor" "$model" "$mountpoint"
            fi
        fi
    done < <(lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT 2>/dev/null)
    
    echo ""
    echo -e "${BLUE}Available network drives:${NC}"
    findmnt -t nfs,nfs4,cifs -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || echo "No network drives mounted"
}

# Function to determine device path for a mount point
get_device_path() {
    local mount_point="$1"
    
    # Check if findmnt command is available
    if ! command -v findmnt &> /dev/null; then
        echo "Error: findmnt command not found. This script requires findmnt to function properly." >&2
        echo "You can install it with: 'sudo apt update && sudo apt install util-linux'" >&2
        return 1
    fi
    
    findmnt -no SOURCE "$mount_point"
}

# Function to find backup drive by UUID or network path
find_backup_drive_by_uuid() {
    local identifier="$1"
    
    # Check if it's a network path (contains slashes)
    if [[ "$identifier" == *"/"* ]]; then
        # Network drive: search for mount point for the network path
        local mount_point
        mount_point=$(findmnt -n -o TARGET -S "$identifier" 2>/dev/null)
        
        if [[ -n "$mount_point" && -d "$mount_point" ]]; then
            echo "$mount_point"
            return 0
        else
            return 1
        fi
    else
        # Local drive: UUID-based search (original logic)
        local device_path=""
        local mount_points=""
        local best_mount_point=""
        
        # Search for device with specified UUID
        device_path=$(blkid -U "$identifier" 2>/dev/null)
        
        if [[ -z "$device_path" ]]; then
            return 1
        fi
        
        # Find all mount points for the device
        mount_points=$(findmnt -n -o TARGET "$device_path" 2>/dev/null | tr '\n' ' ')
        
        if [[ -z "$mount_points" ]]; then
            return 1
        fi
        
        # Select the best mount point (prefer real mount points over temporary ones)
        for mount_point in $mount_points; do
            # Skip fsarchiver temporary mount points
            if [[ "$mount_point" =~ ^/tmp/fsa/ ]]; then
                continue
            fi
            
            # Prefer mount points under /media/, /mnt/, or /run/media/
            if [[ "$mount_point" =~ ^(/media/|/mnt/|/run/media/) ]]; then
                best_mount_point="$mount_point"
                break
            fi
            
            # If no preferred mount point found, use the first non-temporary one
            if [[ -z "$best_mount_point" ]]; then
                best_mount_point="$mount_point"
            fi
        done
        
        if [[ -n "$best_mount_point" ]]; then
            echo "$best_mount_point"
            return 0
        else
            return 1
        fi
    fi
}

# Function to find the best available backup drive
find_best_backup_drive() {
    local available_drives=()
    local best_drive=""
    local oldest_newest_backup=999999999999
    
    echo -e "${BLUE}Searching for configured backup drives (local and network)...${NC}" >&2
    
    # Check if UUID array is configured
    if [[ ${#BACKUP_DRIVE_UUIDS[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: No backup drive UUIDs/network paths configured!${NC}" >&2
        echo -e "${YELLOW}Please add UUIDs or network paths to BACKUP_DRIVE_UUIDS array.${NC}" >&2
        echo "" >&2
        show_available_drives >&2
        return 1
    fi
    
    # Search through all configured identifiers (UUIDs and network paths)
    for identifier in "${BACKUP_DRIVE_UUIDS[@]}"; do
        if [[ -n "$identifier" && "$identifier" != "#"* ]]; then  # Ignore empty and commented lines
            local mount_path
            mount_path=$(find_backup_drive_by_uuid "$identifier")
            if [[ $? -eq 0 && -n "$mount_path" ]]; then
                available_drives+=("$mount_path")
                if [[ "$identifier" == *"/"* ]]; then
                    echo -e "${GREEN}✓ Network backup drive found: $mount_path (Network path: $identifier)${NC}" >&2
                else
                    echo -e "${GREEN}✓ Local backup drive found: $mount_path (UUID: $identifier)${NC}" >&2
                fi
            fi
        fi
    done
    
    # Check if drives were found
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: None of the configured backup drives are available!${NC}" >&2
        echo -e "${YELLOW}Configured identifiers:${NC}" >&2
        for identifier in "${BACKUP_DRIVE_UUIDS[@]}"; do
            if [[ -n "$identifier" && "$identifier" != "#"* ]]; then
                if [[ "$identifier" == *"/"* ]]; then
                    echo "  - $identifier (Network path)" >&2
                else
                    echo "  - $identifier (UUID)" >&2
                fi
            fi
        done
        echo "" >&2
        show_available_drives >&2
        return 1
    fi
    
    # If only one drive is available, use it
    if [[ ${#available_drives[@]} -eq 1 ]]; then
        printf "%s" "${available_drives[0]}"
        return 0
    fi
    
    # If multiple drives are available, find the one with the oldest "newest" backup
    echo -e "${YELLOW}Multiple backup drives available. Analyzing backup versions...${NC}" >&2
    
    for drive in "${available_drives[@]}"; do
        local newest_backup_on_drive=0
        
        echo -e "${BLUE}Analyzing drive: $drive${NC}" >&2
        
        # Check all configured backup types on this drive
        for backup_name in "${!BACKUP_PARAMETERS[@]}"; do
            IFS=':' read -r backup_base_name source <<< "${BACKUP_PARAMETERS[$backup_name]}"
            
            local latest_version
            latest_version=$(find_latest_backup_version "$drive" "$backup_base_name")
            
            if [[ -n "$latest_version" && -f "$latest_version" ]]; then
                local file_time
                file_time=$(stat -c %Y "$latest_version" 2>/dev/null)
                if [[ $? -eq 0 && $file_time -gt $newest_backup_on_drive ]]; then
                    newest_backup_on_drive=$file_time
                fi
                echo -e "${GREEN}  ✓ $backup_name: $(basename "$latest_version") ($(date -d @$file_time '+%d.%m.%Y %H:%M:%S' 2>/dev/null))${NC}" >&2
            else
                echo -e "${YELLOW}  - $backup_name: No backups found${NC}" >&2
            fi
        done
        
        # Check if this drive has the oldest "newest" backup
        if [[ $newest_backup_on_drive -lt $oldest_newest_backup ]]; then
            oldest_newest_backup=$newest_backup_on_drive
            best_drive="$drive"
        fi
        
        if [[ $newest_backup_on_drive -eq 0 ]]; then
            echo -e "${YELLOW}  → Drive has no backups (will be preferred)${NC}" >&2
        else
            echo -e "${BLUE}  → Newest backup from: $(date -d @$newest_backup_on_drive '+%d.%m.%Y %H:%M:%S' 2>/dev/null)${NC}" >&2
        fi
    done
    
    if [[ -n "$best_drive" ]]; then
        if [[ $oldest_newest_backup -eq 0 ]]; then
            echo -e "${GREEN}Using backup drive: $best_drive (no previous backups)${NC}" >&2
        else
            echo -e "${GREEN}Using backup drive: $best_drive (oldest newest backup from $(date -d @$oldest_newest_backup '+%d.%m.%Y %H:%M:%S' 2>/dev/null))${NC}" >&2
        fi
        printf "%s" "$best_drive"
        return 0
    else
        echo -e "${RED}Error selecting backup drive${NC}" >&2
        return 1
    fi
}

# Function to check if backup drive is not the same as source drives
validate_backup_drive() {
    local backup_drive_path="$1"
    
    echo -e "${BLUE}Validating backup drive...${NC}"
    
    # Check if path exists and is mounted
    if [[ ! -d "$backup_drive_path" ]]; then
        echo -e "${RED}ERROR: Backup drive path does not exist: $backup_drive_path${NC}"
        return 1
    fi
    
    # Check if it's a network drive
    local fstype
    fstype=$(findmnt -n -o FSTYPE "$backup_drive_path" 2>/dev/null)
    
    case "$fstype" in
        "nfs"|"nfs4")
            echo -e "${GREEN}✓ NFS network drive detected${NC}"
            
            # Test access to NFS drive
            if ! timeout 10 ls "$backup_drive_path" >/dev/null 2>&1; then
                echo -e "${RED}ERROR: NFS drive not accessible or timeout${NC}"
                return 1
            fi
            
            # Test write permission
            local test_file="$backup_drive_path/.backup-test-$$"
            if timeout 10 touch "$test_file" 2>/dev/null; then
                rm -f "$test_file" 2>/dev/null
                echo -e "${GREEN}✓ NFS drive is writable${NC}"
            else
                echo -e "${RED}ERROR: No write permission on NFS drive${NC}"
                return 1
            fi
            
            echo -e "${GREEN}✓ NFS backup drive validation successful${NC}"
            return 0
            ;;
        "cifs")
            echo -e "${GREEN}✓ CIFS/SMB network drive detected${NC}"
            
            # Test access to CIFS drive
            if ! timeout 10 ls "$backup_drive_path" >/dev/null 2>&1; then
                echo -e "${RED}ERROR: CIFS drive not accessible or timeout${NC}"
                return 1
            fi
            
            # Test write permission
            local test_file="$backup_drive_path/.backup-test-$$"
            if timeout 10 touch "$test_file" 2>/dev/null; then
                rm -f "$test_file" 2>/dev/null
                echo -e "${GREEN}✓ CIFS drive is writable${NC}"
            else
                echo -e "${RED}ERROR: No write permission on CIFS drive${NC}"
                return 1
            fi
            
            echo -e "${GREEN}✓ CIFS backup drive validation successful${NC}"
            return 0
            ;;
        *)
            # Local drive - original validation
            echo -e "${GREEN}✓ Local backup drive detected${NC}"
            
            # Determine UUID of backup drive
            local backup_drive_uuid
            backup_drive_uuid=$(findmnt -n -o UUID "$backup_drive_path" 2>/dev/null)
            
            if [[ -z "$backup_drive_uuid" ]]; then
                echo -e "${RED}ERROR: Could not determine UUID of backup drive: $backup_drive_path${NC}"
                echo -e "${YELLOW}Trying alternative methods...${NC}"
                
                # Alternative: determine UUID via mounted device
                local device_path
                device_path=$(findmnt -n -o SOURCE "$backup_drive_path" 2>/dev/null)
                if [[ -n "$device_path" ]]; then
                    backup_drive_uuid=$(blkid -s UUID -o value "$device_path" 2>/dev/null)
                fi
                
                if [[ -z "$backup_drive_uuid" ]]; then
                    echo -e "${RED}ERROR: UUID could not be determined even with alternative methods${NC}"
                    echo -e "${YELLOW}Backup drive path: $backup_drive_path${NC}"
                    echo -e "${YELLOW}Device path: ${device_path:-'not found'}${NC}"
                    return 1
                fi
            fi
            
            echo -e "${GREEN}✓ Backup drive UUID: $backup_drive_uuid${NC}"
            
            # Check if any of the sources is on the same drive
            for name in "${!BACKUP_PARAMETERS[@]}"; do
                IFS=':' read -r backup_file source <<< "${BACKUP_PARAMETERS[$name]}"
                
                if [[ $source != /dev/* ]]; then
                    local source_uuid
                    source_uuid=$(findmnt -n -o UUID "$source" 2>/dev/null)
                    
                    if [[ -n "$source_uuid" && "$source_uuid" == "$backup_drive_uuid" ]]; then
                        echo -e "${RED}ERROR: Backup drive is the same as source drive!${NC}"
                        echo -e "${RED}Source '$source' (UUID: $source_uuid) is on the same drive as backup target '$backup_drive_path'${NC}"
                        echo -e "${YELLOW}You cannot backup to the same drive you're backing up from!${NC}"
                        echo ""
                        show_available_drives
                        return 1
                    fi
                fi
            done
            
            echo -e "${GREEN}✓ Local backup drive validation successful${NC}"
            return 0
            ;;
    esac
}

# Function to send critical error email
send_critical_error_mail() {
    local error_message="$1"
    local runtime_min="${2:-0}"
    local runtime_sec="${3:-0}"
    
    error_body="${MAIL_BODY_ERROR}"
    error_body="${error_body//\{BACKUP_DATE\}/${BACKUP_START_DATE:-$(date +%d.%B.%Y,%T)}}"
    error_body="${error_body//\{RUNTIME_MIN\}/$runtime_min}"
    error_body="${error_body//\{RUNTIME_SEC\}/$runtime_sec}"
    error_body="${error_body//\{ERROR_DETAILS\}/$error_message}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_ERROR\nTo: $MAIL_TO\n\n$error_body" | ssmtp -t 2>/dev/null
}

# Find and set backup drive
BACKUP_DRIVE_PATH=$(find_best_backup_drive)
if [[ $? -ne 0 || -z "$BACKUP_DRIVE_PATH" ]]; then
    ERROR=1
    ERROR_MSG+="No suitable backup drive (local or network) found.\n"
    echo -e "${RED}Critical error: No backup drive available. Script will exit.${NC}"
    
    # Send error email
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

echo -e "${GREEN}Backup drive successfully found: $BACKUP_DRIVE_PATH${NC}"

# Validate backup drive (not the same as source drives for local drives)
if ! validate_backup_drive "$BACKUP_DRIVE_PATH"; then
    ERROR=1
    ERROR_MSG+="Backup drive validation failed.\n"
    echo -e "${RED}Critical error: Backup drive validation failed. Script will exit.${NC}"
    
    # Send error email
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

#####################################################################
# BACKUP PARAMETER PROCESSING
#####################################################################

# Process backup parameters and update paths
echo -e "${BLUE}Configuring backup parameters...${NC}"
for name in "${!BACKUP_PARAMETERS[@]}"; do
    IFS=':' read -r backup_base_name source <<< "${BACKUP_PARAMETERS[$name]}"
    
    # Create timestamped backup filename
    timestamped_filename=$(create_timestamped_filename "$backup_base_name")
    full_backup_path="$BACKUP_DRIVE_PATH/$timestamped_filename"
    
    if [[ $source == /dev/* ]]; then
        device=$source
    else
        if [ ! -d "$source" ]; then
            ERROR=1
            ERROR_MSG+="Mount point $source does not exist or is not accessible\n"
            echo -e "${RED}Error: Mount point $source does not exist or is not accessible${NC}" >&2
            continue
        fi
        
        device=$(get_device_path "$source")
        if [ -z "$device" ]; then
            ERROR=1
            ERROR_MSG+="Could not determine device path for $source\n"
            echo -e "${RED}Error: Could not determine device path for $source${NC}" >&2
            continue
        fi
    fi
    
    # Format for backup parameters: "full_path:device:base_name"
    BACKUP_PARAMETERS[$name]="$full_backup_path:$device:$backup_base_name"
    echo -e "${GREEN}Configured backup: $name${NC}"
    echo -e "${GREEN}  - File: $timestamped_filename${NC}"
    echo -e "${GREEN}  - Device: $device${NC}"
    echo -e "${GREEN}  - Base name: $backup_base_name${NC}"
done

# Check if configuration errors occurred
if [ "$ERROR" -eq 1 ]; then
    echo -e "${RED}Configuration errors occurred:${NC}" >&2
    echo -e "$ERROR_MSG" >&2
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

#####################################################################
# PASSWORD CONFIGURATION (OPTIONAL)
#####################################################################

# Load archive password from external file (if configured)
FSPASS=""
USE_ENCRYPTION=false

if [[ -n "${PASSWORD_FILE:-}" ]]; then
    echo -e "${BLUE}Checking encryption configuration...${NC}"
    
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo -e "${RED}Error: Password file $PASSWORD_FILE not found.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Password file $PASSWORD_FILE not found.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    if [ ! -r "$PASSWORD_FILE" ]; then
        echo -e "${RED}Error: Password file $PASSWORD_FILE is not readable.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Password file $PASSWORD_FILE is not readable.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    FSPASS=$(cat "$PASSWORD_FILE" | tr -d '\n')

    if [ -z "$FSPASS" ]; then
        echo -e "${RED}Error: Password file $PASSWORD_FILE is empty.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Password file $PASSWORD_FILE is empty.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    export FSPASS
    USE_ENCRYPTION=true
    echo -e "${GREEN}✓ Encryption enabled${NC}"
else
    echo -e "${YELLOW}ℹ Encryption disabled (PASSWORD_FILE not configured)${NC}"
fi

#####################################################################
# BACKUP FUNCTIONS
#####################################################################

# Main function for performing a backup
do_backup() {
    local backup_file="$1"
    local device="$2"
    
    # Set current backup file for signal handler
    CURRENT_BACKUP_FILE="$backup_file"
    
    echo -e "${BLUE}Backing up device: $device${NC}" | tee -a $BACKUP_LOG
    ls -l "$device" >> $BACKUP_LOG 2>&1
    lsblk "$device" >> $BACKUP_LOG 2>&1
    
    # fsarchiver command depending on encryption configuration
    if [[ "$USE_ENCRYPTION" == true ]]; then
        fsarchiver "${EXCLUDE_STATEMENTS[@]}" -o -v -A -j$(nproc) -Z$ZSTD_COMPRESSION_VALUE -c "${FSPASS}" savefs "$backup_file" "$device" 2>&1 | tee -a $BACKUP_LOG &
    else
        fsarchiver "${EXCLUDE_STATEMENTS[@]}" -o -v -A -j$(nproc) -Z$ZSTD_COMPRESSION_VALUE savefs "$backup_file" "$device" 2>&1 | tee -a $BACKUP_LOG &
    fi
    
    # Store PID of fsarchiver process for signal handler
    CURRENT_FSARCHIVER_PID=$!
    
    # Wait for fsarchiver process
    wait $CURRENT_FSARCHIVER_PID
    local fsarchiver_exit_code=$?
    
    # Reset fsarchiver PID (finished)
    CURRENT_FSARCHIVER_PID=""
    
    # Check if script was interrupted
    if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
        echo -e "${YELLOW}Backup was interrupted while processing $device${NC}"
        return 1
    fi
    
    # Check fsarchiver exit code
    if [[ $fsarchiver_exit_code -ne 0 ]]; then
        echo -e "${RED}fsarchiver exited with code: $fsarchiver_exit_code${NC}"
        ERROR=1
        ERROR_MSG+="fsarchiver exit code $fsarchiver_exit_code for device $device\n"
    fi
    
    check_backup_errors "$device" "$backup_file"
    
    # After backup: check for new fsarchiver mount points and clean them up
    echo -e "${BLUE}Checking for fsarchiver mount points after backup...${NC}"
    local post_backup_mounts
    post_backup_mounts=$(find_fsarchiver_mounts)
    
    if [[ -n "$post_backup_mounts" ]]; then
        echo -e "${YELLOW}New fsarchiver mount points detected after backup - cleaning up...${NC}"
        if ! cleanup_fsarchiver_mounts true; then
            echo -e "${YELLOW}Warning: Some mount points could not be automatically removed${NC}"
            ERROR_MSG+="Warning: fsarchiver mount points after backup of $device could not be completely removed\n"
        fi
    else
        echo -e "${GREEN}✓ No fsarchiver mount points present after backup${NC}"
    fi
    
    # Reset backup file (finished)
    CURRENT_BACKUP_FILE=""
    
    return $fsarchiver_exit_code
}

# Function to check backup errors
check_backup_errors() {
    local BKP_SOURCE="$1"
    local BKP_FILE="$2"

    # Ensure BACKUP_LOG variable is available
    if [ -z "$BACKUP_LOG" ]; then
        ERROR_MSG+="[ $BACKUP_LOG ] is empty after backup of [ $BKP_SOURCE ]. Something is wrong. Please check the logs and the entire backup process."
        return 1
    fi

    local LOG_OUTPUT
    LOG_OUTPUT=$(tail -n 5 "$BACKUP_LOG" | egrep -i "(files with errors)|\b(cannot|warning|error|errno|Errors detected)\b")

    # Check for errors in log output
    local has_errors=false
    if  [[ ${LOG_OUTPUT,,} =~ (^|[[:space:]])("cannot"|"warning"|"error"|"errno"|"errors detected")([[:space:]]|$) ]]; then
        has_errors=true
        ERROR=1
        ERROR_MSG+="Errors detected in backup of [ $BKP_SOURCE ]:\n$LOG_OUTPUT\n"
    elif [[ $LOG_OUTPUT =~ regfiles=([0-9]+),\ directories=([0-9]+),\ symlinks=([0-9]+),\ hardlinks=([0-9]+),\ specials=([0-9]+) ]]; then
        for val in "${BASH_REMATCH[@]:1}"; do
            if [ "$val" -ne 0 ]; then
                has_errors=true
                ERROR=1
                ERROR_MSG+="Errors detected in backup of [ $BKP_SOURCE ]:\n$LOG_OUTPUT\n"
                break
            fi
        done
    fi
    
    # Check if backup file was actually created
    if [[ ! -f "$BKP_FILE" ]]; then
        has_errors=true
        ERROR=1
        ERROR_MSG+="Backup file was not created: $BKP_FILE\n"
        echo -e "${RED}✗ Backup file not found: $BKP_FILE${NC}"
    else
        # Check size of backup file (at least 1 MB)
        local file_size
        file_size=$(stat -c%s "$BKP_FILE" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            if [[ $file_size -lt 1048576 ]]; then  # 1 MB = 1048576 Bytes
                has_errors=true
                ERROR=1
                ERROR_MSG+="Backup file is too small ($(( file_size / 1024 )) KB): $BKP_FILE\n"
                echo -e "${RED}✗ Backup file too small: $BKP_FILE ($(( file_size / 1024 )) KB)${NC}"
            else
                echo -e "${GREEN}✓ Backup file created: $(basename "$BKP_FILE") ($(( file_size / 1024 / 1024 )) MB)${NC}"
            fi
        else
            has_errors=true
            ERROR=1
            ERROR_MSG+="Could not determine backup file size: $BKP_FILE\n"
            echo -e "${RED}✗ Could not determine backup file size: $BKP_FILE${NC}"
        fi
    fi
    
    # Output overall result
    if [[ "$has_errors" == true ]]; then
        echo -e "${RED}✗ Backup of $BKP_SOURCE failed${NC}"
    else
        echo -e "${GREEN}✓ Backup of $BKP_SOURCE successful${NC}"
    fi
}

#####################################################################
# MAIN PROGRAM - PERFORM BACKUP
#####################################################################

# Generate exclusion statements for fsarchiver as array
EXCLUDE_STATEMENTS=()
for path in "${EXCLUDE_PATHS[@]}"; do
  EXCLUDE_STATEMENTS+=("--exclude=$path")
done

# Record backup start time
TIME_START=$(date +"%s")
BACKUP_START_DATE=$(date +%d.%B.%Y,%T)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}BACKUP PROCESS STARTED${NC}"
echo -e "${GREEN}Start: $BACKUP_START_DATE${NC}"
echo -e "${GREEN}========================================${NC}"

# Initialize log file
if [[ -e $BACKUP_LOG ]]; then
    rm -f $BACKUP_LOG
fi
touch $BACKUP_LOG

echo "Backup started: $BACKUP_START_DATE" >> $BACKUP_LOG

# Execute backup jobs by iterating over the associative array
for KEY in $(echo "${!BACKUP_PARAMETERS[@]}" | tr ' ' '\n' | sort -n); do
    # Check if script was interrupted
    if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
        echo -e "${YELLOW}Script interruption detected. Stopping further backups.${NC}"
        break
    fi
    
    IFS=':' read -r BKP_IMAGE_FILE SOURCE_DEVICE BKP_BASE_NAME <<< "${BACKUP_PARAMETERS[$KEY]}"
    echo -e "${BLUE}Starting backup: $KEY${NC}"
    
    if do_backup "$BKP_IMAGE_FILE" "$SOURCE_DEVICE"; then
        # After successful backup: clean up old versions (only if not interrupted)
        if [[ "$SCRIPT_INTERRUPTED" == false && $ERROR -eq 0 ]]; then
            cleanup_old_backups "$BACKUP_DRIVE_PATH" "$BKP_BASE_NAME" "$VERSIONS_TO_KEEP"
        fi
    else
        echo -e "${RED}Backup of $KEY failed or was interrupted${NC}"
        if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
            break
        fi
    fi
done

#####################################################################
# COMPLETION AND EMAIL NOTIFICATION
#####################################################################

# Calculate runtime
TIME_DIFF=$(($(date +"%s")-${TIME_START}))
RUNTIME_MINUTES=$((${TIME_DIFF} / 60))
RUNTIME_SECONDS=$((${TIME_DIFF} % 60))

echo -e "${GREEN}========================================${NC}"

# Check if script was interrupted
if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
    echo -e "${RED}BACKUP WAS INTERRUPTED${NC}"
    echo -e "${RED}Runtime: $RUNTIME_MINUTES minutes and $RUNTIME_SECONDS seconds${NC}"
    echo -e "${RED}========================================${NC}"
    
    # Interruption email
    mail_body="${MAIL_BODY_INTERRUPTED}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_INTERRUPTED\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${YELLOW}Interruption email sent${NC}"
    
    exit 130  # Standard exit code for SIGINT
elif [ "$ERROR" -eq 1 ]; then
    echo -e "${RED}BACKUP COMPLETED WITH ERRORS${NC}"
    echo -e "${GREEN}End: $(date +%d.%B.%Y,%T)${NC}"
    echo -e "${GREEN}Runtime: $RUNTIME_MINUTES minutes and $RUNTIME_SECONDS seconds${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Error email
    mail_body="${MAIL_BODY_ERROR}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    mail_body="${mail_body//\{ERROR_DETAILS\}/$ERROR_MSG}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_ERROR\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${YELLOW}Error email sent${NC}"
else
    echo -e "${GREEN}BACKUP COMPLETED SUCCESSFULLY${NC}"
    echo -e "${GREEN}End: $(date +%d.%B.%Y,%T)${NC}"
    echo -e "${GREEN}Runtime: $RUNTIME_MINUTES minutes and $RUNTIME_SECONDS seconds${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Success email
    mail_body="${MAIL_BODY_SUCCESS}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"   
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_SUCCESS\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${GREEN}Success email sent${NC}"
fi

# Exit script with appropriate exit code
if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
    exit 130  # Standard exit code for SIGINT
elif [ "$ERROR" -eq 1 ]; then
    exit 1
else
    exit 0
fi