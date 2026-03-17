#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

check_device() {
    local dev
    dev="$(lsusb | grep -i '2207:' || true)"

    if [ -z "$dev" ]; then
        echo
        echo "Rockchip device not found."
        echo "Make sure the tablet is in Loader / Maskrom mode."
        echo
        lsusb || true
        exit 1
    fi

    echo
    echo "Rockchip device detected:"
    echo "$dev"
    echo
}

sanitize_dir_name() {
    local input="$1"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    printf '%s' "$input"
}

get_partitions_from_parameter_file() {
    local parameter_file="$1"

    [ -f "$parameter_file" ] || die "parameter file not found: $parameter_file"

    grep -oE '\([^)]+\)' "$parameter_file" \
        | tr -d '()' \
        | awk 'NF && !seen[$0]++'
}

load_parts_array() {
    local parameter_file="$1"
    parts=()

    while IFS= read -r part; do
        [ -n "$part" ] && parts+=("$part")
    done < <(get_partitions_from_parameter_file "$parameter_file")
}

save_checksums() {
    local backup_dir="$1"

    log "Calculating SHA256 checksums..."

    if command -v sha256sum >/dev/null 2>&1; then
        (
            cd "$backup_dir"
            sha256sum ./*.img > SHA256SUMS.txt
        )
    else
        (
            cd "$backup_dir"
            shasum -a 256 ./*.img > SHA256SUMS.txt
        )
    fi

    log "Checksums saved to $backup_dir/SHA256SUMS.txt"
}

verify_checksums() {
    local backup_dir="$1"
    local checksum_file="$backup_dir/SHA256SUMS.txt"

    [ -f "$checksum_file" ] || die "Checksum file not found: $checksum_file"

    log "Verifying SHA256 checksums..."
    (
        cd "$backup_dir"
        sha256sum -c "$(basename "$checksum_file")"
    )
}

backup_partition() {
    local part="$1"
    local backup_dir="$2"
    local out_file="$backup_dir/$part.img"

    log "Backing up partition: $part"
    rkflashtool r "$part" > "$out_file"

    if [ ! -s "$out_file" ]; then
        die "Backup failed or empty image created for partition: $part"
    fi

    local size
    size="$(wc -c < "$out_file" | awk '{print $1}')"
    log "Saved $part -> $out_file (${size} bytes)"
}

restore_partition() {
    local part="$1"
    local backup_dir="$2"
    local img_file="$backup_dir/$part.img"

    if [ ! -f "$img_file" ]; then
        log "Skipping $part: image file not found"
        return
    fi

    if [ ! -s "$img_file" ]; then
        die "Image file is empty: $img_file"
    fi

    local size
    size="$(wc -c < "$img_file" | awk '{print $1}')"

    log "Restoring partition: $part from $img_file (${size} bytes)"
    rkflashtool w "$part" < "$img_file"
}

do_backup() {
    check_device

    echo "Enter backup folder name:"
    read -r backup_dir
    backup_dir="$(sanitize_dir_name "$backup_dir")"

    [ -n "$backup_dir" ] || die "Folder name cannot be empty"

    if [ -e "$backup_dir" ]; then
        [ -d "$backup_dir" ] || die "Path exists and is not a directory: $backup_dir"
        if [ "$(find "$backup_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | awk '{print $1}')" -gt 0 ]; then
            echo
            echo "Directory '$backup_dir' already exists and is not empty."
            read -r -p "Continue and overwrite same filenames if needed? (yes/no): " answer
            [ "$answer" = "yes" ] || die "Aborted by user"
        fi
    else
        mkdir -p "$backup_dir"
    fi

    log "Saving partition table..."
    rkflashtool p > "$backup_dir/parameter.txt"

    [ -s "$backup_dir/parameter.txt" ] || die "Failed to save parameter.txt"

    load_parts_array "$backup_dir/parameter.txt"

    [ "${#parts[@]}" -gt 0 ] || die "No partitions found in parameter.txt"

    echo
    echo "Found partitions:"
    printf ' - %s\n' "${parts[@]}"
    echo

    read -r -p "Start backup of all listed partitions? (yes/no): " answer
    [ "$answer" = "yes" ] || die "Aborted by user"

    for part in "${parts[@]}"; do
        backup_partition "$part" "$backup_dir"
    done

    save_checksums "$backup_dir"

    log "Backup completed successfully"
    echo "Backup folder: $backup_dir"
}

do_restore() {
    check_device

    echo "Enter backup folder name to restore from:"
    read -r backup_dir
    backup_dir="$(sanitize_dir_name "$backup_dir")"

    [ -n "$backup_dir" ] || die "Folder name cannot be empty"
    [ -d "$backup_dir" ] || die "Directory does not exist: $backup_dir"
    [ -f "$backup_dir/parameter.txt" ] || die "parameter.txt not found in: $backup_dir"

    load_parts_array "$backup_dir/parameter.txt"

    [ "${#parts[@]}" -gt 0 ] || die "No partitions found in parameter.txt"

    echo
    echo "Partitions to restore:"
    printf ' - %s\n' "${parts[@]}"
    echo

    if [ -f "$backup_dir/SHA256SUMS.txt" ]; then
        read -r -p "Verify checksums before restore? (yes/no): " verify_answer
        if [ "$verify_answer" = "yes" ]; then
            verify_checksums "$backup_dir"
        fi
    else
        echo "Checksum file not found, skipping verification."
    fi

    echo
    echo "WARNING: restore will overwrite partitions on the connected tablet."
    read -r -p "Type YES to continue: " answer
    [ "$answer" = "YES" ] || die "Aborted by user"

    for part in "${parts[@]}"; do
        restore_partition "$part" "$backup_dir"
    done

    log "Restore completed successfully"
}

show_menu() {
    echo "Select mode:"
    echo "1) backup"
    echo "2) restore"
    read -r -p "Enter 1 or 2: " choice

    case "$choice" in
        1) do_backup ;;
        2) do_restore ;;
        *) die "Invalid choice" ;;
    esac
}

main() {
    require_cmd rkflashtool
    require_cmd lsusb
    require_cmd grep
    require_cmd awk
    require_cmd wc

    case "${1:-}" in
        backup)
            do_backup
            ;;
        restore)
            do_restore
            ;;
        "")
            show_menu
            ;;
        *)
            echo "Usage:"
            echo "  $SCRIPT_NAME"
            echo "  $SCRIPT_NAME backup"
            echo "  $SCRIPT_NAME restore"
            exit 1
            ;;
    esac
}

main "$@"