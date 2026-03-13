#!/bin/bash
umask 077

usage() {
    echo "Usage: $(basename "$0")"
    echo ""
    echo "Restore symlinked directories from sgoinfre/goinfre back to \$HOME."
    echo ""
    echo "Log file: \$HOME/homemover_script.log"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Trap Ctrl+C (SIGINT) to allow clean exit
trap 'echo -e "\n${RED}Interrupted by user. Exiting...${NC}"; exit 130' SIGINT

LOG_FILE="$HOME/homemover_script.log"
TOTAL_RESTORED_MB=0

log_msg() {
    echo -e "$1"
}

log_cmd() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [BRINGBACK] CMD: $*" >> "$LOG_FILE"
}

log_res() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [BRINGBACK] RESULT: $*" >> "$LOG_FILE"
}

log_hdr() {
    echo -e "\n[ BRINGING BACK DIRECTORY: $1 ]" >> "$LOG_FILE"
}

format_size() {
    local mb=$1
    if [ "$mb" -ge 1024 ]; then
        echo "$((mb / 1024)) GB"
    else
        echo "$mb MB"
    fi
}

get_size_mb() {
    local size_kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
    echo $((${size_kb:-0} / 1024))
}

resolve_path() {
    if command -v realpath >/dev/null 2>&1; then
        realpath -e -- "$1" 2>/dev/null
    elif readlink -f -- "$1" >/dev/null 2>&1; then
        readlink -f -- "$1" 2>/dev/null
    else
        log_msg "    ${RED}[FATAL]${NC} Neither realpath nor readlink -f available. Cannot validate paths."
        return 1
    fi
}

assert_safe_path() {
    local path="$1"
    local allowed_prefix="$2"
    
    # Reject pathological inputs
    case "$path" in
        ""|/|.|..) return 1 ;;
    esac
    case "$allowed_prefix" in
        ""|/|.|..) return 1 ;;
    esac
    
    local real_path real_prefix
    real_path=$(resolve_path "$path") || return 1
    real_prefix=$(resolve_path "$allowed_prefix") || return 1
    
    if [[ "$real_path" == "$real_prefix"/* ]]; then
        return 0
    fi
    return 1
}

verify_copy() {
    local src="$1"
    local dest="$2"
    local mode="${VERIFY_MODE:-full}"
    local src_size dest_size
    # Use --apparent-size to ignore block size differences between filesystems
    src_size=$(du -sk --apparent-size "$src" 2>/dev/null | awk '{print $1}')
    dest_size=$(du -sk --apparent-size "$dest" 2>/dev/null | awk '{print $1}')
    
    if [ "${src_size:-0}" -ne "${dest_size:-0}" ]; then
        log_msg "    ${RED}[VERIFY FAILED]${NC} Size mismatch: src=${src_size}K dest=${dest_size}K"
        log_res "VERIFY FAILED (size: src=${src_size}K dest=${dest_size}K)"
        return 1
    fi
    
    if [ "$mode" = "full" ]; then
        local src_count dest_count
        src_count=$(find "$src" -type f 2>/dev/null | wc -l)
        dest_count=$(find "$dest" -type f 2>/dev/null | wc -l)
        if [ "${src_count:-0}" -ne "${dest_count:-0}" ]; then
            log_msg "    ${RED}[VERIFY FAILED]${NC} File count mismatch: src=$src_count dest=$dest_count"
            log_res "VERIFY FAILED (file count: src=$src_count dest=$dest_count)"
            return 1
        fi
    fi
    return 0
}

bring_back() {
    local symlink_path="$1"
    local target_path="$2"
    local rel="${symlink_path#$HOME/}"
    
    log_hdr "$symlink_path"
    
    # Quota check
    local size_mb=$(get_size_mb "$target_path")
    local home_free=$(df -m "$HOME" | tail -n 1 | awk '{print $4}')
    
    if [ "$size_mb" -gt "$home_free" ]; then
        log_msg "    ${RED}[ERROR]${NC} Not enough space in Home to bring back ~/$rel!"
        log_msg "    Size: $size_mb MB | Free: $home_free MB"
        log_res "FAILED (Insufficient space)"
        return 1
    fi

    log_msg "    ${BLUE}Restoring to home directory...${NC}"
    
    # Use mktemp for crash-safe unique temp dir on the same filesystem
    local tmp_dest
    tmp_dest=$(mktemp -d "$(dirname "$symlink_path")/.bring_back_tmp.${rel##*/}.XXXXXX") || {
        log_msg "    ${RED}[ERROR]${NC} Failed to create temp directory!"
        log_res "FAILED (mktemp)"
        return 1
    }
    
    log_cmd "rsync/cp \"$target_path/\" \"$tmp_dest\""
    if command -v rsync >/dev/null 2>&1; then
        rsync -ahXA --info=progress2 --no-inc-recursive "$target_path/" "$tmp_dest"
    else
        log_msg "    ${YELLOW}[INFO]${NC} rsync not found, using cp -a..."
        cp -a "$target_path/" "$tmp_dest"
    fi
    status=$?
    echo ""
    
    if [ $status -eq 0 ]; then
        log_res "COPY SUCCESS"
        
        if ! verify_copy "$target_path" "$tmp_dest"; then
            log_msg "    ${YELLOW}[CLEANUP]${NC} Cleaning up unverified copy..."
            log_cmd "rm -rf -- \"$tmp_dest\" (cleanup after verify failure)"
            rm -rf -- "$tmp_dest"
            return 1
        fi
        
        TOTAL_RESTORED_MB=$((TOTAL_RESTORED_MB + size_mb))
        
        # Re-check: is symlink_path still a symlink? (race condition guard)
        if [ ! -L "$symlink_path" ]; then
            log_msg "    ${RED}[SECURITY_SKIP]${NC} $symlink_path is no longer a symlink! Aborting."
            log_res "ABORTED (symlink changed during operation)"
            log_cmd "rm -rf -- \"$tmp_dest\" (cleanup after race detect)"
            rm -rf -- "$tmp_dest"
            return 1
        fi
        
        # Only now it's safe to remove the symlink and rename tmp
        log_cmd "rm -- \"$symlink_path\""
        rm -- "$symlink_path"
        
        log_cmd "mv -- \"$tmp_dest\" \"$symlink_path\""
        mv -- "$tmp_dest" "$symlink_path"
        
        if ! assert_safe_path "$target_path" "/sgoinfre" && ! assert_safe_path "$target_path" "/goinfre"; then
            log_msg "    ${RED}[SECURITY_SKIP]${NC} Path validation failed for target: $target_path"
            log_res "ABORTED (unsafe target path, data restored but external not cleaned)"
            return 1
        fi
        
        log_cmd "rm -rf -- \"$target_path\""
        rm -rf -- "$target_path"
        
        # Cleanup parent directory if empty (e.g., .local if it's now empty)
        local parent_dir
        parent_dir=$(dirname "$target_path")
        if rmdir "$parent_dir" 2>/dev/null; then
             log_msg "    ${YELLOW}[CLEANUP]${NC} Removed empty parent directory on target: $parent_dir"
             log_cmd "rmdir \"$parent_dir\""
        fi

        log_msg "    ${GREEN}[OK]${NC} ~/$rel restored successfully."
    else
        log_res "FAILED (Exit Code: $status)"
        log_msg "    ${RED}[ERROR]${NC} Failed to restore ~/$rel! (symlink untouched)"
        log_cmd "rm -rf -- \"$tmp_dest\" (cleanup after failed copy)"
        rm -rf -- "$tmp_dest"
    fi
}

clear
log_msg "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
log_msg "                      HOMEBRINGER (UNDO)"
log_msg "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
usage
log_msg "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\\n"

log_msg "--- Homebringer Script Started ---"

# Start scanning
log_msg "${BLUE}Scanning home directory for symlinks to sgoinfre/goinfre...${NC}\n"

FOUND=0
while IFS= read -r -u 3 item; do
    rel="${item#$HOME/}"

    # Special handling for .local/share
    if [ "$rel" = ".local" ]; then
        sub="$HOME/.local/share"
        if [ -L "$sub" ]; then
            target=$(readlink "$sub")
            if [[ "$target" == /sgoinfre/* ]] || [[ "$target" == /goinfre/* ]]; then
                FOUND=1
                size=$(get_size_mb "$target")
                log_msg "${YELLOW}[EXCEPTION]${NC} ~/.local/share points to external drive ($size MB)"
                read -r -p "  Do you want to bring this folder back to Home? [y/N]: " res </dev/tty
                if [ "$res" = "y" ] || [ "$res" = "Y" ]; then
                    bring_back "$sub" "$target"
                else
                    log_msg "  -> Skipped."
                fi
            fi
        fi
        continue
    fi

    # Only check symlinks for other items
    [ -L "$item" ] || continue
    
    # Read symlink destination
    target=$(readlink "$item")
    
    # Check if it points to sgoinfre or goinfre
    if [[ "$target" == /sgoinfre/* ]] || [[ "$target" == /goinfre/* ]]; then
        FOUND=1
        size=$(get_size_mb "$target")
        
        log_msg "${YELLOW}[LINKED]${NC} ~/$rel points to external drive ($size MB)"
        read -r -p "  Do you want to bring this folder back to Home? [y/N]: " res </dev/tty
        if [ "$res" = "y" ] || [ "$res" = "Y" ]; then
            bring_back "$item" "$target"
        else
            log_msg "  -> Skipped."
        fi
    fi
done 3< <(find "$HOME" -maxdepth 1 -mindepth 1 | sort)

if [ $FOUND -eq 0 ]; then
    log_msg "${YELLOW}No linked directories found to bring back.${NC}"
fi

# Final Summary
HOME_STATS=$(df -m "$HOME" | tail -n 1)
HOME_TOTAL=$(echo "$HOME_STATS" | awk '{print $2}')
HOME_FREE=$(echo "$HOME_STATS" | awk '{print $4}')

log_msg "\n${GREEN}${BOLD}Operation completed.${NC}"
log_msg "${BLUE}Total Restored in this session:${NC} $(format_size $TOTAL_RESTORED_MB)"
log_msg "${BLUE}Home Partition Free Space:${NC} $(format_size $HOME_FREE) / $(format_size $HOME_TOTAL)"
log_msg "Log file: $LOG_FILE\n"
