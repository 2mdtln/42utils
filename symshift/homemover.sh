#!/bin/bash
umask 077

usage() {
    echo "Usage: $(basename "$0")"
    echo ""
    echo "Move large directories from \$HOME to sgoinfre/goinfre and replace with symlinks."
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
MIN_SIZE_MB=${1:-0}

USER_ID=$(whoami)
TOTAL_MOVED_MB=0

# Initialize log file (Append mode)
: >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null
echo "----------------------------------------------------------------" >> "$LOG_FILE"
date '+%Y-%m-%d %H:%M:%S - Homemover Script Started' >> "$LOG_FILE"

log_msg() {
    echo -e "$1"
}

log_cmd() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CMD: $*" >> "$LOG_FILE"
}

log_res() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - RESULT: $*" >> "$LOG_FILE"
}

log_hdr() {
    echo -e "\n[ FOR DIRECTORY: $1 ]" >> "$LOG_FILE"
}

format_size() {
    local mb=$1
    if [ "$mb" -ge 1024 ]; then
        echo "$((mb / 1024)) GB"
    else
        echo "$mb MB"
    fi
}

format_size_kb() {
    local kb=$1
    if [ "$kb" -ge 1048576 ]; then
        echo "$((kb / 1048576)) GB"
    elif [ "$kb" -ge 1024 ]; then
        echo "$((kb / 1024)) MB"
    else
        echo "$kb KB"
    fi
}

if [ -d "/sgoinfre" ]; then
    TARGET_DISK="sgoinfre"
    TARGET_BASE="/sgoinfre/$USER_ID/home"
elif [ -d "/goinfre" ]; then
    TARGET_DISK="goinfre"
    TARGET_BASE="/goinfre/$USER_ID/home"
else
    log_msg "${RED}[FATAL] No sgoinfre or goinfre drive found! Aborting operation.${NC}"
    exit 1
fi


clear
log_msg "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
log_msg "                      DATA LOSS WARNING"
log_msg "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
log_msg "${YELLOW}sgoinfre/goinfre drives can be wiped by the system at any time."
log_msg "This script frees up your quota by moving large directories.${NC}\n"
usage
log_msg "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

log_msg "--- Homemover Script Started ---"

get_size_mb() {
    local size_kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
    echo $((${size_kb:-0} / 1024))
}

get_size_kb() {
    du -sk "$1" 2>/dev/null | awk '{print $1}'
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
    
    # Must start with prefix and not be the prefix itself
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

move_and_link() {
    local src="$1"
    local rel="${src#$HOME/}"
    local dest="$TARGET_BASE/$rel"
    
    log_hdr "$src"
    
    if [ -d "$dest" ]; then
        log_msg "    ${RED}[ERROR]${NC} Directory already exists at destination (Operation aborted): $dest"
        return 1
    fi
    
    mkdir -p "$(dirname "$dest")"
    echo -e "    ${BLUE}Moving to target disk...${NC}"
    
    log_cmd "rsync/cp -ahXA --info=progress2 --no-inc-recursive \"$src\" \"$(dirname "$dest")/\""
    if command -v rsync >/dev/null 2>&1; then
        rsync -ahXA --info=progress2 --no-inc-recursive "$src" "$(dirname "$dest")/"
    else
        log_msg "    ${YELLOW}[INFO]${NC} rsync not found, using cp -a..."
        cp -a "$src" "$(dirname "$dest")/"
    fi
    status=$?
    echo ""
    
    if [ $status -eq 0 ]; then
        log_res "COPY SUCCESS"
        
        if ! verify_copy "$src" "$dest"; then
            log_msg "    ${YELLOW}[CLEANUP]${NC} Cleaning up unverified copy..."
            if assert_safe_path "$dest" "$TARGET_BASE"; then
                log_cmd "rm -rf -- \"$dest\" (cleanup after verify failure)"
                rm -rf -- "$dest"
            else
                log_msg "    ${RED}[SECURITY_SKIP]${NC} Cleanup skipped: path validation failed for dest: $dest"
            fi
            return 1
        fi
        
        local size_mb=$(get_size_mb "$dest")
        TOTAL_MOVED_MB=$((TOTAL_MOVED_MB + size_mb))
        
        if ! assert_safe_path "$src" "$HOME"; then
            log_msg "    ${RED}[SECURITY]${NC} Path validation failed for src: $src"
            log_res "ABORTED (unsafe src path)"
            return 1
        fi
        
        log_cmd "rm -rf -- \"$src\""
        rm -rf -- "$src"
        
        if ! assert_safe_path "$dest" "$TARGET_BASE"; then
            log_msg "    ${RED}[SECURITY_SKIP]${NC} Symlink skipped: path validation failed for dest: $dest"
            log_res "ABORTED (unsafe dest path for symlink)"
            return 1
        fi
        
        log_cmd "ln -s \"$dest\" \"$src\""
        ln -s "$dest" "$src"
        
        log_msg "    ${GREEN}[OK]${NC} ~/$rel successfully moved and linked."
    else
        log_res "FAILED (Exit Code: $status)"
        log_msg "    ${RED}[ERROR]${NC} An error occurred while moving ~/$rel!"
        log_msg "    ${YELLOW}[CLEANUP]${NC} Cleaning up partial copy..."
        if assert_safe_path "$dest" "$TARGET_BASE"; then
            log_cmd "rm -rf -- \"$dest\" (cleanup after failed rsync)"
            rm -rf -- "$dest"
        else
            log_msg "    ${RED}[SECURITY_SKIP]${NC} Cleanup skipped: path validation failed for dest: $dest"
        fi
    fi
}


log_msg "${BLUE}Target drive to use: /$TARGET_DISK${NC}"
log_msg "${BLUE}Scanning home directory...${NC}\n"

mapfile -t items < <(find "$HOME" -maxdepth 1 -mindepth 1 2>/dev/null | sort)

for item in "${items[@]}"; do
    [ -d "$item" ] || continue
    [ -L "$item" ] && continue
    
    rel="${item#$HOME/}"
    dest="$TARGET_BASE/$rel"

    if [ -e "$dest" ]; then
        continue
    fi

    if [ "$rel" = "bin" ]; then
        continue
    fi

    if [ "$rel" = ".local" ]; then
        target_sub="$HOME/.local/share"
        dest_sub="$TARGET_BASE/.local/share"
        
        if [ -d "$target_sub" ] && [ ! -L "$target_sub" ]; then
            if [ -e "$dest_sub" ]; then
                continue
            fi
            size=$(get_size_mb "$target_sub")
            if [ "$size" -ge "$MIN_SIZE_MB" ]; then
                size_kb=$(get_size_kb "$target_sub")
                log_msg "${YELLOW}[EXCEPTION]${NC} ~/.local/share directory is large ($(format_size_kb "$size_kb"))."
                read -r -p "  Do you want to move this folder? [y/N]: " res </dev/tty
                if [ "$res" = "y" ] || [ "$res" = "Y" ]; then
                    move_and_link "$target_sub"
                else
                    log_msg "  -> Skipped."
                fi
            fi
        fi
        continue
    fi

    size=$(get_size_mb "$item")
    
    if [ "$size" -ge "$MIN_SIZE_MB" ]; then
        size_kb=$(get_size_kb "$item")
        log_msg "${YELLOW}[CANDIDATE]${NC} ~/$rel ($(format_size_kb "$size_kb"))"
        read -r -p "  Do you want to move this folder? [y/N]: " res </dev/tty
        if [ "$res" = "y" ] || [ "$res" = "Y" ]; then
            move_and_link "$item"
        else
            log_msg "  -> Skipped."
        fi
    fi
done

# Final Summary
HOME_STATS=$(df -m "$HOME" | tail -n 1)
HOME_TOTAL=$(echo "$HOME_STATS" | awk '{print $2}')
HOME_FREE=$(echo "$HOME_STATS" | awk '{print $4}')

log_msg "\n${GREEN}${BOLD}Operation completed.${NC}"
log_msg "${BLUE}Total Moved in this session:${NC} $(format_size $TOTAL_MOVED_MB)"
log_msg "${BLUE}Home Partition Free Space:${NC} $(format_size $HOME_FREE) / $(format_size $HOME_TOTAL)"
log_msg "Log file: $LOG_FILE\n"