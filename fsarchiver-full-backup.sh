#!/bin/bash

# User-defined backup configurations
# Format: BACKUP_PARAMETERS["Backup Name"]="Backup File Path:Mount Point or Device Path you want to backup"
declare -A BACKUP_PARAMETERS
BACKUP_PARAMETERS["EFI"]="/backup/taget/backup-efi.fsa:/boot/efi"
BACKUP_PARAMETERS["System"]="/backup/taget/backup-root.fsa:/"
BACKUP_PARAMETERS["DATA"]="/backup/taget/backup-DATA.fsa:/media/mfleuti/DATA"

# Backup log file location
BACKUP_LOG="/var/log/fsarchiver-bkp.log"

# Password file location
# In order to increase security, this file should be located on an encrypted volume with root-only access privileges
PASSWORD_FILE="/path/to/encrypted/volume/.bkp-password-file.sec"

# E-Mail configuration for notifications
# set the user used to send out the e-mail. The script uses ssmtp for mail sending. Ensure that ssmtp is installed (apt install ssmtp)
# Remember to edit /etc/ssmpt/ssmtp.conf and set the following options:
## mailhub=your-mailserver.tld:587
## hostname=your-desired-hostname
## FromLineOverride=YES                    ### This is important so that the script can set the proper sender name
## UseSTARTTLS=YES                         ### This is the default for mail dispatch via Port 587. SMTP/SSL via port 465 usually requires this to be disabled and UseTLS=yes to be set instead
## UseTLS=NO
## AuthUser=your-myusername@your-domain.tld
## AuthPass=your-email-account-password
MAIL_FROM="My e-mail sender name<myname@domain.tld>"
MAIL_TO="myname@domain.tld"
MAIL_SUBJECT_ERROR="[ERROR] FSARCHIVER Backup failed. Please check the logs." 		# Enter the default backup error message
MAIL_SUBJECT_SUCCESS="[SUCCESS] FSARCHIVER Backup Successful" 						# Enter the default backup success message

# Set paths to exclude from backup - specifically paths which contain other mountpoints (other volumes mounted in a directory of another volume - these should be backed up separately)
# If you are excluding paths with spaces you will need to escape those spaces. Example: "/opt/my\ exclude\ path"
EXCLUDE_PATHS=(
    "/home/username/Cryptomator-mountpoints"
    "/home/username/Steamlibrary"
    "/home/username/.steam"
    "/var/log/*"
    "/media"
    "/mnt"
    "/tmp/*"
    "/swapfile"
)

# ZSTD compression level (0-22)
# 0 = no compression, 1 = fastest/worst compression, 22 = slowest/best compression
# Default is 3. Values above 19 are considered "ultra" settings and should be used with caution.
ZSTD_COMPRESSION_VALUE=5

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "The script must be executed as root. Exiting..."
   exit 1
fi

# Function to get the device path for a given mount point
# Function to get the device path for a given mount point
get_device_path() {
    local mount_point="$1"
    
    # Check if findmnt command is available
    if ! command -v findmnt &> /dev/null
    then
        echo "Error: findmnt command not found. This script requires the findmnt command to function properly." >&2
        echo "You can install it by running: sudo apt update && sudo apt install util-linux" >&2
        return 1
    fi
    
    findmnt -no SOURCE "$mount_point"
}

ERROR=0
ERROR_MSG=""

# Process backup parameters
for name in "${!BACKUP_PARAMETERS[@]}"; do
    IFS=':' read -r backup_file source <<< "${BACKUP_PARAMETERS[$name]}"
    if [[ $source == /dev/* ]]; then
        device=$source
    else
        if [ ! -d "$source" ]; then
            ERROR=1
            ERROR_MSG+="Mount point $source does not exist or is not accessible\n"
            echo "Error: Mount point $source does not exist or is not accessible" >&2
            continue
        fi
        
        device=$(get_device_path "$source")
        if [ -z "$device" ]; then
            ERROR=1
            ERROR_MSG+="Failed to get device path for $source\n"
            echo "Error: Failed to get device path for $source" >&2
            continue
        fi
    fi
    
    BACKUP_PARAMETERS[$name]="$backup_file:$device"
    echo "Configured backup: $name - File: $backup_file, Device: $device"
done

if [ "$ERROR" -eq 1 ]; then
    echo "Errors occurred during configuration:" >&2
    echo -e "$ERROR_MSG" >&2
    exit 1
fi

# Get the archive password from an external file which can only be accessed by root. Cut eventual existing new lines.
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Error: Password file $PASSWORD_FILE not found." >&2
    ERROR=1
    ERROR_MSG+="Password file $PASSWORD_FILE not found.\n"
    exit 1
fi

if [ ! -r "$PASSWORD_FILE" ]; then
    echo "Error: Password file $PASSWORD_FILE is not readable." >&2
    ERROR=1
    ERROR_MSG+="Password file $PASSWORD_FILE is not readable.\n"
    exit 1
fi

FSPASS=$(cat "$PASSWORD_FILE" | tr -d '\n')

if [ -z "$FSPASS" ]; then
    echo "Error: Password file $PASSWORD_FILE is empty." >&2
    ERROR=1
    ERROR_MSG+="Password file $PASSWORD_FILE is empty.\n"
    exit 1
fi

export FSPASS

ERROR=0
ERROR_MSG=""

do_backup() {
    local backup_file="$1"
    local device="$2"
    
    echo "Backing up device: $device" >> $BACKUP_LOG
    ls -l "$device" >> $BACKUP_LOG
    lsblk "$device" >> $BACKUP_LOG
    
    fsarchiver ${EXCLUDE_STATEMENTS} -o -v -A -j$(nproc) -Z$ZSTD_COMPRESSION_VALUE -c "${FSPASS}" savefs "$backup_file" "$device" 2>&1 | tee -a $BACKUP_LOG
    
    check_backup_errors "$device"
}

check_backup_errors() {
    local BKP_SOURCE="$1"

    # Ensure the BACKUP_LOG variable is available - just to be 100% sure that the log was not removed in the meantime...
    if [ -z "$BACKUP_LOG" ]; then
        ERROR_MSG+="[ $BACKUP_LOG ] is empty after backing up [ $BKP_SOURCE ]. Something is not OK. Please check the logs and the backup process as a whole."
        return 1
    fi

    local LOG_OUTPUT
    LOG_OUTPUT=$(tail -n 5 "$BACKUP_LOG" | egrep -i "(files with errors)|\b(cannot|warning|error|errno|Errors detected)\b")

    if  [[ ${LOG_OUTPUT,,} =~ (^|[[:space:]])("cannot"|"warning"|"error"|"errno"|"Errors detected")([[:space:]]|$) ]]; then
        ERROR=1
        ERROR_MSG+="Errors detected in backup for [ $BKP_SOURCE ]:\n$LOG_OUTPUT\n"
    elif [[ $LOG_OUTPUT =~ regfiles=([0-9]+),\ directories=([0-9]+),\ symlinks=([0-9]+),\ hardlinks=([0-9]+),\ specials=([0-9]+) ]]; then
        for val in "${BASH_REMATCH[@]:1}"; do
            if [ "$val" -ne 0 ]; then
                ERROR=1
                ERROR_MSG+="Errors detected in backup for [ $BKP_SOURCE ]:\n$LOG_OUTPUT\n"
                break
            fi
        done
    fi
}

# Now generate fsarchiver exclude statements from the exclude paths..
EXCLUDE_STATEMENTS=""

for path in "${EXCLUDE_PATHS[@]}"; do
  EXCLUDE_STATEMENTS+="--exclude=$path "
done

TIME_START=$(date +"%s")
MAIL_BODY=""
MAIL_BODY="${MAIL_BODY}Backup start: $(date +%d.%B.%Y,%T)."

if [[ -e $BACKUP_LOG ]]; then
    rm -f $BACKUP_LOG
    touch $BACKUP_LOG
fi

# Execute the backup job by looping through the associative array
for KEY in $(echo "${!BACKUP_PARAMETERS[@]}" | tr ' ' '\n' | sort -n); do
    IFS=':' read -r BKP_IMAGE_FILE SOURCE_DEVICE <<< "${BACKUP_PARAMETERS[$KEY]}"
    do_backup "$BKP_IMAGE_FILE" "$SOURCE_DEVICE"
done

# Send E-Mail on error or success
TIME_DIFF=$(($(date +"%s")-${TIME_START}))
if [ "$ERROR" -eq 1 ]; then
    MAIL_BODY="${MAIL_BODY}\n\n"
    MAIL_BODY="${MAIL_BODY}Backup end: $(date +%d.%B.%Y,%T).\n"
    MAIL_BODY="${MAIL_BODY}Runtime: $((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds.\n\n"
    MAIL_BODY="${MAIL_BODY}ERROR REPORT:\n"
    MAIL_BODY="${MAIL_BODY}$ERROR_MSG"

    # Send E-Mail...
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_ERROR\nTo: $MAIL_TO\n\n$MAIL_BODY" | ssmtp -t
else
    #Send E-Mail...
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_SUCCESS\nTo: $MAIL_TO\n\nBackup finished on: $(date +%d.%B.%Y,%T)\nRuntime: $((${TIME_DIFF} / 60)) Minutes and $((${TIME_DIFF} % 60)) Seconds." | ssmtp -t
fi