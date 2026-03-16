#!/bin/bash

# Default directory is the current working directory
DIR="."
MODE="none"

# --- Function to display usage information ---
usage() {
    echo "Usage: sudo $0 [OPTION]..."
    echo "K3s image backup and restore utility. Saves each image as a separate .tar file."
    echo ""
    echo "🚨 IMPORTANT: This script MUST be run with 'sudo' or as root."
    echo ""
    echo "Modes (one must be selected):"
    echo "  -b        Run in Backup mode (Export all images to a directory)."
    echo "  -r        Run in Restore mode (Import all images from a directory)."
    echo ""
    echo "Options:"
    echo "  -d DIR    Specify the target directory for backup, or the source for restore."
    echo "            Default is the current directory ('.'). The directory will be created if it doesn't exist."
    echo "  -h        Display this help message and exit."
    echo ""
    echo "Example (Backup to /mnt/k3s-images):"
    echo "  sudo $0 -b -d /mnt/k3s-images"
    echo ""
    echo "Example (Restore from /mnt/k3s-images):"
    echo "  sudo $0 -r -d /mnt/k3s-images"
    exit 1
}

# --- Function to perform the image backup ---
backup_images() {
    local BACKUP_DIR="$DIR"

    # Ensure the target directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Creating destination directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR" || { echo "❌ Error: Could not create directory $BACKUP_DIR"; exit 1; }
    fi

    echo "Starting K3s image backup to directory: $BACKUP_DIR"
    
    local IMAGE_LIST
    IMAGE_LIST=$(k3s ctr images list -q)

    if [ -z "$IMAGE_LIST" ]; then
        echo "⚠️ Warning: No images found in Containerd runtime to export."
        exit 0
    fi
    
    local total_images=$(echo "$IMAGE_LIST" | wc -l | tr -d ' ')
    local success_count=0
    local fail_count=0
    local current_num=0
    local failed_images=""

    echo "Found ${total_images} images to process..."

    while read -r image; do
        ((current_num++))
        
        # Create a safe filename by replacing '/', ':', and '@' with underscores or dashes
        local safe_filename
        safe_filename=$(echo "$image" | sed -e 's|/|_|g' -e 's|:|--|g' -e 's|@|---|g')
        local archive_file="${BACKUP_DIR}/${safe_filename}.tar"

        echo -ne "  [${current_num}/${total_images}] Exporting to ${safe_filename}.tar...                                 \r"

        if k3s ctr images export "$archive_file" "$image" >/dev/null 2>&1; then
            ((success_count++))
        else
            ((fail_count++))
            failed_images+="${image}\n"
            # Clean up the failed (likely 0-byte) file
            rm -f "$archive_file"
            echo -e "\n  └── ⚠️  Failed to export: $image"
        fi
    done <<< "$IMAGE_LIST"

    echo -e "\n\n--- Backup Summary ---"
    echo "✅ Successful: ${success_count}"
    echo "❌ Failed:     ${fail_count}"
    echo "----------------------"

    if [ $fail_count -gt 0 ]; then
        echo -e "The following images could not be exported:\n${failed_images}"
    fi

    if [ $success_count -eq 0 ]; then
        echo "❌ Error: No images were successfully exported."
        exit 1
    else
        echo "✅ Backup process complete."
        echo "Total size of backup directory:"
        du -sh "$BACKUP_DIR"
    fi
}

# --- Function to perform the image restore ---
restore_images() {
    local RESTORE_DIR="$DIR"

    echo "Starting K3s image restore from directory: $RESTORE_DIR"

    if [ ! -d "$RESTORE_DIR" ]; then
        echo "❌ Error: Restore directory not found at $RESTORE_DIR"
        exit 1
    fi

    local archive_list
    archive_list=$(find "$RESTORE_DIR" -name "*.tar")

    if [ -z "$archive_list" ]; then
        echo "⚠️ Warning: No .tar files found in $RESTORE_DIR to restore."
        exit 0
    fi

    local total_files=$(echo "$archive_list" | wc -l | tr -d ' ')
    local success_count=0
    local fail_count=0
    local current_num=0
    
    echo "Found ${total_files} image archives to import..."

    while read -r file; do
        ((current_num++))
        local filename
        filename=$(basename "$file")
        echo -ne "  [${current_num}/${total_files}] Importing ${filename}...                                 \r"

        if k3s ctr images import "$file" >/dev/null 2>&1; then
            ((success_count++))
        else
            ((fail_count++))
            echo -e "\n  └── ⚠️  Failed to import: $filename"
        fi
    done <<< "$archive_list"

    echo -e "\n\n--- Restore Summary ---"
    echo "✅ Successful: ${success_count}"
    echo "❌ Failed:     ${fail_count}"
    echo "-----------------------"
    
    if [ $fail_count -gt 0 ]; then
        echo "Please check the logs for details on failed imports."
    fi
    
    echo "✅ Restore process complete."
}

# --- Main Logic ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run with root privileges (e.g., using 'sudo')."
    usage
fi

if ! command -v k3s > /dev/null; then
    echo "❌ Error: 'k3s' command not found."
    exit 1
fi

while getopts "brd:h" opt; do
    case "$opt" in
        b) MODE="backup";;
        r) MODE="restore";;
        d) DIR=$(echo "$OPTARG" | sed 's/\/$//');;
        h|?) usage;;
    esac
done

case "$MODE" in
    backup) backup_images;;
    restore) restore_images;;
    none) echo "❌ Error: No operation mode specified."; usage;;
esac

echo "Operation complete."