#!/bin/bash

_dump_usage() {
    cat <<EOF
${UI_BOLD}pbak dump${UI_RESET} — Copy photos from SD card to SSD

Scans the SD card DCIM folder, extracts dates from EXIF data, and copies
files into a YYYY/MM/DD folder structure on the SSD. Uses SHA-256 hashes
to skip files that have already been backed up.

${UI_BOLD}Flags:${UI_RESET}
  --sd <name>     Override SD card volume name
  --ssd <name>    Override SSD volume name
  -h, --help      Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

dump_extract_date() {
    local filepath="$1"
    local date

    date=$(exiftool -DateTimeOriginal -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(exiftool -CreateDate -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(exiftool -FileModifyDate -d '%Y/%m/%d' -s3 -f "$filepath" 2>/dev/null)
    if [[ "$date" != "-" && -n "$date" && "$date" != *"0000"* ]]; then
        echo "$date"; return 0
    fi

    date=$(stat -f '%Sm' -t '%Y/%m/%d' "$filepath" 2>/dev/null)
    if [[ -n "$date" ]]; then
        echo "$date"; return 0
    fi

    date -u '+%Y/%m/%d'
}

dump_scan_files() {
    local dcim_path="$1"
    local include_exts="$2"
    local exclude_exts="$3"

    local find_args=()
    find_args+=("$dcim_path" "-type" "f")

    if [[ -n "$include_exts" ]]; then
        find_args+=("(")
        local first=1
        local IFS=','
        for ext in $include_exts; do
            ext="${ext# }"
            [[ "$ext" != .* ]] && ext=".${ext}"
            if [[ $first -eq 1 ]]; then
                first=0
            else
                find_args+=("-o")
            fi
            find_args+=("-iname" "*${ext}")
        done
        find_args+=(")")
    fi

    # Exclude filter runs as a second pass — simpler than nested find predicates
    if [[ -n "$exclude_exts" ]]; then
        find "${find_args[@]}" 2>/dev/null | while IFS= read -r f; do
            local fname fext
            fname="$(basename "$f")"
            fext=".${fname##*.}"
            fext="$(echo "$fext" | tr '[:upper:]' '[:lower:]')"

            local skip=0
            local IFS=','
            for eext in $exclude_exts; do
                eext="${eext# }"
                [[ "$eext" != .* ]] && eext=".${eext}"
                eext="$(echo "$eext" | tr '[:upper:]' '[:lower:]')"
                if [[ "$fext" == "$eext" ]]; then
                    skip=1
                    break
                fi
            done
            [[ $skip -eq 0 ]] && echo "$f"
        done
    else
        find "${find_args[@]}" 2>/dev/null
    fi
}

dump_select_sd() {
    local override="$1"

    if [[ -n "$override" ]]; then
        utils_require_volume "$override" || exit 1
        echo "$override"
        return 0
    fi

    if [[ -n "${PBAK_SD_VOLUME:-}" ]]; then
        if utils_require_volume "$PBAK_SD_VOLUME" 2>/dev/null; then
            if ui_confirm "  Use SD card '${PBAK_SD_VOLUME}'?"; then
                echo "$PBAK_SD_VOLUME"
                return 0
            fi
        else
            ui_warn "Default SD card '${PBAK_SD_VOLUME}' is not mounted."
        fi
    fi

    local volumes
    volumes=($(utils_list_volumes))
    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_error "No external volumes found."
        exit 1
    fi

    local choice
    choice=$(ui_select "Select SD card volume:" "${volumes[@]}")
    utils_require_volume "$choice" || exit 1
    echo "$choice"
}

dump_select_ssd() {
    local override="$1"

    if [[ -n "$override" ]]; then
        utils_require_volume "$override" || exit 1
        echo "$override"
        return 0
    fi

    if [[ -n "${PBAK_SSD_VOLUME:-}" ]]; then
        if utils_require_volume "$PBAK_SSD_VOLUME" 2>/dev/null; then
            if ui_confirm "  Use SSD '${PBAK_SSD_VOLUME}'?"; then
                echo "$PBAK_SSD_VOLUME"
                return 0
            fi
        else
            ui_warn "Default SSD '${PBAK_SSD_VOLUME}' is not mounted."
        fi
    fi

    local volumes
    volumes=($(utils_list_volumes))
    if [[ ${#volumes[@]} -eq 0 ]]; then
        ui_error "No external volumes found."
        exit 1
    fi

    local choice
    choice=$(ui_select "Select SSD volume:" "${volumes[@]}")
    utils_require_volume "$choice" || exit 1
    echo "$choice"
}

# Returns: 0=copied, 1=skipped (dup), 2=error
dump_process_file() {
    local src_file="$1"
    local ssd_dump_root="$2"
    local precomputed_hashes="${3:-}"

    local hash
    if [[ -n "$precomputed_hashes" ]]; then
        hash=$(hash_lookup_precomputed "$src_file" "$precomputed_hashes")
    fi
    if [[ -z "${hash:-}" ]]; then
        hash=$(hash_compute "$src_file") || return 2
    fi

    if hash_exists "$hash"; then
        utils_log DEBUG "Skipping (duplicate): ${src_file}"
        return 1
    fi

    local date_path
    date_path=$(dump_extract_date "$src_file")

    local dest_dir="${ssd_dump_root}/${date_path}"
    local filename
    filename="$(basename "$src_file")"
    local name_no_ext="${filename%.*}"
    local ext=".${filename##*.}"

    local dest_file
    dest_file=$(hash_resolve_collision "$dest_dir" "$name_no_ext" "$ext") || return 2

    if utils_is_dry_run; then
        local size
        size=$(utils_file_size "$src_file")
        ui_info "[dry-run] Would copy: ${src_file} -> ${dest_file} ($(utils_human_size "$size"))"
        return 0
    fi

    utils_ensure_dir "$dest_dir"

    if ! cp -p "$src_file" "$dest_file" 2>/dev/null; then
        ui_error "Failed to copy: ${src_file}"
        return 2
    fi

    local dest_hash
    dest_hash=$(hash_compute "$dest_file")
    if [[ "$hash" != "$dest_hash" ]]; then
        ui_error "Hash mismatch after copy! ${src_file}"
        rm -f "$dest_file"
        return 2
    fi

    local size
    size=$(utils_file_size "$src_file")
    hash_add "$hash" "$src_file" "$dest_file" "$size"

    utils_log DEBUG "Copied: ${src_file} -> ${dest_file}"
    return 0
}

pbak_dump() {
    local sd_override=""
    local ssd_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sd)  sd_override="$2"; shift 2 ;;
            --ssd) ssd_override="$2"; shift 2 ;;
            -h|--help) _dump_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _dump_usage; return 1 ;;
        esac
    done

    config_require
    utils_check_deps

    ui_header "Photo Dump: SD -> SSD"

    local db
    db="$(hash_db_file)"
    if [[ ! -s "$db" ]]; then
        if [[ -n "${PBAK_SSD_VOLUME:-}" ]] || [[ -n "$ssd_override" ]]; then
            local check_vol="${ssd_override:-$PBAK_SSD_VOLUME}"
            local check_root="/Volumes/${check_vol}/full_dump"
            if [[ -d "$check_root" ]]; then
                local existing
                existing=$(find "$check_root" -type f 2>/dev/null | head -1)
                if [[ -n "$existing" ]]; then
                    ui_warn "Hash database is empty but SSD has existing files."
                    if ui_confirm "  Rebuild hash database from SSD first?"; then
                        hash_rebuild "$check_root"
                        echo
                    fi
                fi
            fi
        fi
    fi

    local sd_name ssd_name
    sd_name=$(dump_select_sd "$sd_override")
    ssd_name=$(dump_select_ssd "$ssd_override")

    local sd_dcim="/Volumes/${sd_name}/DCIM"
    local ssd_dump_root="/Volumes/${ssd_name}/full_dump"

    if [[ ! -d "$sd_dcim" ]]; then
        ui_error "DCIM directory not found at ${sd_dcim}"
        exit 1
    fi

    utils_ensure_dir "$ssd_dump_root"
    utils_volume_is_writable "$ssd_name" || exit 1

    echo
    ui_info "Source: ${sd_dcim}"
    ui_info "Target: ${ssd_dump_root}"

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] No files will be copied."
    fi

    echo
    ui_info "Scanning files..."

    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN

    dump_scan_files "$sd_dcim" \
        "${PBAK_DUMP_EXTENSIONS_INCLUDE:-}" \
        "${PBAK_DUMP_EXTENSIONS_EXCLUDE:-}" > "$tmpfile"

    local total=0
    while IFS= read -r _; do
        ((total++))
    done < "$tmpfile"

    if [[ $total -eq 0 ]]; then
        ui_info "No matching files found on SD card."
        return 0
    fi

    local total_bytes=0
    while IFS= read -r f; do
        local sz
        sz=$(utils_file_size "$f")
        total_bytes=$((total_bytes + sz))
    done < "$tmpfile"

    ui_info "Found ${UI_BOLD}${total}${UI_RESET} files ($(utils_human_size "$total_bytes"))"

    local avail_kb
    avail_kb=$(utils_volume_available_kb "$ssd_name")
    local avail_bytes=$((avail_kb * 1024))
    if [[ $total_bytes -gt $avail_bytes ]]; then
        ui_warn "Files require $(utils_human_size "$total_bytes") but SSD has $(utils_human_size "$avail_bytes") free."
        if ! ui_confirm "  Continue anyway?"; then
            return 1
        fi
    fi

    echo

    ui_info "Pre-hashing source files (${HASH_WORKERS} workers)..."
    local hash_cache
    hash_cache=$(mktemp)
    ui_spinner_start "Hashing..."
    hash_compute_batch "$tmpfile" "$hash_cache"
    ui_spinner_stop
    ui_success "Hashing complete."
    echo

    local copied=0 skipped=0 errors=0
    local count=0
    local copied_bytes=0

    while IFS= read -r filepath; do
        ((count++))
        ui_progress "$count" "$total" "$(basename "$filepath")"

        local status=0
        dump_process_file "$filepath" "$ssd_dump_root" "$hash_cache" || status=$?

        case $status in
            0) ((copied++))
               copied_bytes=$((copied_bytes + $(utils_file_size "$filepath")))
               ;;
            1) ((skipped++)) ;;
            *) ((errors++)) ;;
        esac
    done < "$tmpfile"

    ui_progress_done
    echo

    ui_header "Summary"
    ui_success "Copied:  ${copied} files ($(utils_human_size "$copied_bytes"))"
    if [[ $skipped -gt 0 ]]; then
        ui_dim "  Skipped: ${skipped} (already backed up)"
    fi
    if [[ $errors -gt 0 ]]; then
        ui_error "Errors:  ${errors}"
    fi
    echo
    rm -f "$hash_cache"
    ui_info "Hash DB: $(hash_count) total files tracked"

    if [[ -n "${PBAK_MIRROR_VOLUME:-}" ]] && \
       utils_require_volume "$PBAK_MIRROR_VOLUME" 2>/dev/null; then
        echo
        ui_info "Mirror SSD '${PBAK_MIRROR_VOLUME}' detected — syncing..."
        pbak_sync --from "$ssd_name" --to "$PBAK_MIRROR_VOLUME"
    elif [[ -n "${PBAK_MIRROR_VOLUME:-}" ]]; then
        echo
        ui_dim "Mirror SSD '${PBAK_MIRROR_VOLUME}' not mounted — skipping sync."
    fi
}
