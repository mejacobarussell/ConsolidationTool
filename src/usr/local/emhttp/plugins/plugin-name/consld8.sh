#!/bin/bash
# ----------------------------------------------------------------------------------
# Script: colsold8.sh (Plugin Backend)
# Purpose: Backend handler for WebGUI plugin. Executes consolidation non-interactively.
# ----------------------------------------------------------------------------------
set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration & Constants (from consld8-1.1.0.sh) ---
# 200 GB minimum free space safety margin (in 1K blocks, as df/du output)
MIN_FREE_SPACE_KB=209715200 
ACTIVE_MIN_FREE_KB="$MIN_FREE_SPACE_KB"
# -----------------------------------------------------------

# --- ANSI Color Definitions (Included for log file readability) ---
RESET='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
# ----------------------------------------------------

# --- Arguments ---
MODE=$1 
TARGET_SHARE_COMPONENT=$2 # e.g., "TVSHOWS/ShowName"
# -------------------

# --- Helper Functions (Adapted from consld8-1.1.0.sh) ---

# Function to check if a share component is consolidated (exists on 1 or fewer disks with files)
is_consolidated() {
    local share_component="$1"
    local consolidated_disk_count=0
    
    for d_path in /mnt/{disk[1-9]{,[0-9]},cache}; do
        if [ -d "$d_path/$share_component" ] && [ -n "$(find "$d_path/$share_component" -mindepth 1 -type f 2>/dev/null | head -n 1)" ]; then
            consolidated_disk_count=$((consolidated_disk_count + 1))
        fi
    done
    
    if [ "$consolidated_disk_count" -le 1 ]; then
        return 0 # Consolidated (True)
    else
        return 1 # Not consolidated (False)
    fi
}


# Function to safely execute rsync move (Adapted from original execute_move)
execute_move_non_interactive() {
    local src_dir_name="$1" # The share component path e.g., "TVSHOWS/ShowName"
    local dest_disk="$2"

    echo "$(date): >> Preparing to move '${src_dir_name}' to disk '$dest_disk'..."
    
    local dest_path="/mnt/$dest_disk/$src_dir_name"
    
    # Ensure destination directory exists on the target disk
    mkdir -p "$dest_path" || { echo "$(date): ERROR: Could not create destination path $dest_path." 1>&2; return 1; }

    # Loop through all possible source disks (including cache)
    for d in /mnt/{disk[1-9]{,[0-9]},cache}; do
        local source_path="$d/$src_dir_name"
        
        # Check if source directory exists AND it's not the destination disk
        if [ -d "$source_path" ] && [ "/mnt/$dest_disk" != "$d" ]; then
            echo "$(date):    Merging data from $d..."

            # Use rsync to move contents (The safe move: copy and delete source)
            rsync -avh --remove-source-files "$source_path/" "$dest_path/"
            
            if [ $? -eq 0 ]; then
                # Clean up empty directories
                find "$source_path" -type d -empty -delete
                # Attempt to remove the share root on that disk if it's now empty
                rmdir "$source_path" 2>/dev/null || true
            else
                echo "$(date):    WARNING: Rsync failed from $source_path. Skipping cleanup." 1>&2
            fi
        fi
    done
    echo "$(date): Move execution complete for $src_dir_name."
    return 0
}

# --- Main Execution Case ---
if [[ $EUID -ne 0 ]]; then
   echo "$(date): Error: This script must be run as root." 1>&2
   exit 1
fi

case "$MODE" in
    # ---------------------------------------------------------
    # MODE 1: --find-splits (READ-ONLY for WebGUI display)
    # Output: ECHO folder paths (relative to /mnt/user/) to STDOUT, one per line.
    # ---------------------------------------------------------
    --find-splits)
        # Find all top-level directories under /mnt/user/ that are not system files or the root itself
        # This logic is adapted from your original script's folder selection/filtering.
        find /mnt/user -mindepth 2 -maxdepth 2 -type d \
             -not -path '*/.trash*' \
             -not -path '*/.recycle*' \
             -not -path '*/.Recycle*' \
             -print0 | while IFS= read -r -d $'\0' full_src_path; do
            
            # Extract the share component path (e.g., TVSHOWS/ShowName)
            share_component="${full_src_path#/mnt/user/}" 
            
            # Check if it is fragmented (not consolidated)
            if ! is_consolidated "$share_component"; then
                # If NOT consolidated (fragmented), print the path for the PHP script to list
                echo "$share_component"
            fi
        done
        ;;

    # ---------------------------------------------------------
    # MODE 2: --consolidate <share_component> (WRITE/EXECUTION)
    # Action: Executes the move of all fragments of one specific folder.
    # ---------------------------------------------------------
    --consolidate)
        echo "$(date): Initializing consolidation mode."

        if [ -z "$TARGET_SHARE_COMPONENT" ]; then
            echo "$(date): Error: Consolidation mode requires a target share component argument." 1>&2
            exit 1
        fi
        
        # --- 1. Determine Total Folder Size ---
        TOTAL_FOLDER_SIZE=0
        for d_path in /mnt/{disk[1-9]{,[0-9]},cache}; do
            if [ -d "$d_path/$TARGET_SHARE_COMPONENT" ]; then
                current_folder_on_disk_size=$(du -s "$d_path/$TARGET_SHARE_COMPONENT" 2>/dev/null | cut -f 1)
                TOTAL_FOLDER_SIZE=$((TOTAL_FOLDER_SIZE + current_folder_on_disk_size))
            fi
        done

        if [ "$TOTAL_FOLDER_SIZE" -eq 0 ]; then
             echo "$(date): WARNING: Target folder ${TARGET_SHARE_COMPONENT} appears empty. Exiting." 1>&2
             exit 0
        fi

        echo "$(date): Target size to move: $(numfmt --to=iec --from-unit=1K $TOTAL_FOLDER_SIZE)"
        
        # --- 2. Find the BEST Destination Disk (Using logic adapted from auto_plan_and_execute) ---
        BEST_DEST_DISK=""
        MAX_FREE_SPACE=-1
        
        for d_path in /mnt/{disk[1-9]{,[0-9]},cache}; do
            disk_name="${d_path#/mnt/}"
            
            # Calculate net space needed (REQUIRED_SPACE)
            current_folder_on_disk_size=0
            if [ -d "$d_path/$TARGET_SHARE_COMPONENT" ]; then
                current_folder_on_disk_size=$(du -s "$d_path/$TARGET_SHARE_COMPONENT" 2>/dev/null | cut -f 1)
            fi
            
            REQUIRED_SPACE=$((TOTAL_FOLDER_SIZE - current_folder_on_disk_size))
            if [ "$REQUIRED_SPACE" -lt 0 ]; then REQUIRED_SPACE=0; fi
            
            # Get current available space
            DFREE=$(df -P "$d_path" 2>/dev/null | tail -1 | awk '{ print $4 }' || echo 0)
            
            # Check if Free Space after move meets the minimum safety margin
            if [ "$((DFREE - REQUIRED_SPACE))" -lt "$ACTIVE_MIN_FREE_KB" ]; then
                echo "$(date):   Disk ${disk_name} skipped: Fails minimum free space safety check."
                continue 
            fi
            
            # Optimization Metric: Simple largest amount of *final* free space
            FINAL_FREE_SPACE=$((DFREE - REQUIRED_SPACE))

            if [ "$FINAL_FREE_SPACE" -gt "$MAX_FREE_SPACE" ]; then
                MAX_FREE_SPACE="$FINAL_FREE_SPACE"
                BEST_DEST_DISK="$disk_name"
            fi
        done
        
        # --- 3. Execute or Fail ---
        if [ -z "$BEST_DEST_DISK" ]; then
            echo "$(date): ERROR: Failed to find a suitable disk for ${TARGET_SHARE_COMPONENT}." 1>&2
            echo "$(date): No disk meets the $(numfmt --to=iec --from-unit=1K $ACTIVE_MIN_FREE_KB) safety margin requirement." 1>&2
            exit 1
        fi
        
        echo "$(date): Best destination disk found: ${BEST_DEST_DISK}"
        
        # Perform the move
        execute_move_non_interactive "$TARGET_SHARE_COMPONENT" "$BEST_DEST_DISK"
        
        if [ $? -eq 0 ]; then
            echo "$(date): Consolidation completed successfully for ${TARGET_SHARE_COMPONENT}."
        else
            echo "$(date): CRITICAL ERROR: Rsync execution failed for ${TARGET_SHARE_COMPONENT}." 1>&2
            exit 1
        fi
        ;;

    # ---------------------------------------------------------
    # DEFAULT CASE (Handles incorrect plugin call)
    # ---------------------------------------------------------
    *)
        echo "$(date): Error: Invalid mode '${MODE}' provided by plugin. Exiting." 1>&2
        exit 1
        ;;
esac

exit 0
