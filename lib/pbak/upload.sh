#!/bin/bash
# Upload state format (tab-separated):
# <status>\t<folder_path>\t<timestamp>\t<file_count>\t<exit_code>

_upload_usage() {
    cat <<EOF
${UI_BOLD}pbak upload${UI_RESET} — Upload photos from SSD to Immich

Uploads date-organized folders from the SSD to your Immich server using
immich-go. Tracks which folders have been uploaded to avoid re-uploading.

${UI_BOLD}Flags:${UI_RESET}
  --ssd <name>      Override SSD volume name
  --date <YY/MM/DD> Upload a specific date folder only
  --all             Upload all pending (un-uploaded) folders
  --retry-failed    Retry previously failed uploads
  --force           Re-upload all folders (immich-go skips server-side dupes)
  -h, --help        Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

upload_state_file() {
    local f="$(config_dir)/uploads.log"
    [[ -f "$f" ]] || touch "$f"
    echo "$f"
}

upload_log_dir() {
    local d="$(config_dir)/logs"
    mkdir -p "$d"
    echo "$d"
}

upload_is_uploaded() {
    local folder="$1"
    local sf
    sf="$(upload_state_file)"
    grep -qF "uploaded	${folder}	" "$sf" 2>/dev/null
}

upload_mark() {
    local folder="$1"
    local status="$2"
    local count="$3"
    local exit_code="$4"
    local sf
    sf="$(upload_state_file)"
    local ts
    ts="$(utils_timestamp)"

    # Remove-then-append to upsert the folder's state
    local tmp="${sf}.tmp"
    grep -vF "	${folder}	" "$sf" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$folder" "$ts" "$count" "$exit_code" >> "$tmp"
    mv "$tmp" "$sf"
}

upload_list_folders() {
    local ssd_root="$1"
    # YYYY/MM/DD = depth 3 under full_dump
    find "$ssd_root" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort
}

upload_list_pending() {
    local ssd_root="$1"
    while IFS= read -r folder; do
        if ! upload_is_uploaded "$folder"; then
            echo "$folder"
        fi
    done < <(upload_list_folders "$ssd_root")
}

upload_list_failed() {
    local sf
    sf="$(upload_state_file)"
    grep "^failed	" "$sf" 2>/dev/null | cut -f 2
}

upload_folder_file_count() {
    local folder="$1"
    find "$folder" -type f 2>/dev/null | wc -l | tr -d ' '
}

upload_count_by_status() {
    local status="$1"
    local sf
    sf="$(upload_state_file)"
    grep -c "^${status}	" "$sf" 2>/dev/null || echo 0
}

upload_files_by_status() {
    local status="$1"
    local sf
    sf="$(upload_state_file)"
    local total=0
    while IFS=$'\t' read -r _ _ _ count _; do
        total=$((total + count))
    done < <(grep "^${status}	" "$sf" 2>/dev/null)
    echo "$total"
}

upload_run() {
    local folder="$1"
    local log_file
    log_file="$(upload_log_dir)/upload-$(date '+%Y%m%d-%H%M%S').log"

    local cmd=(
        immich-go upload from-folder
        --server="${PBAK_IMMICH_SERVER}"
        --api-key="${PBAK_IMMICH_API_KEY}"
        --recursive
    )

    if [[ -n "${PBAK_UPLOAD_EXTENSIONS_INCLUDE:-}" ]]; then
        cmd+=(--include-extensions="${PBAK_UPLOAD_EXTENSIONS_INCLUDE}")
    fi
    if [[ -n "${PBAK_UPLOAD_EXTENSIONS_EXCLUDE:-}" ]]; then
        cmd+=(--exclude-extensions="${PBAK_UPLOAD_EXTENSIONS_EXCLUDE}")
    fi
    if [[ "${PBAK_UPLOAD_PAUSE_JOBS:-true}" == "true" ]]; then
        cmd+=(--pause-immich-jobs)
    fi
    cmd+=(--concurrent-tasks="${PBAK_CONCURRENT_TASKS:-4}")
    cmd+=(--log-file="$log_file")

    if utils_is_dry_run; then
        cmd+=(--dry-run)
    fi

    cmd+=("$folder")

    utils_log DEBUG "Running: ${cmd[*]}"

    local exit_code=0
    "${cmd[@]}" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        ui_warn "  Log file: ${log_file}"
    fi

    return "$exit_code"
}

upload_select_folders() {
    local ssd_root="$1"

    local pending=()
    while IFS= read -r folder; do
        pending+=("$folder")
    done < <(upload_list_pending "$ssd_root")

    if [[ ${#pending[@]} -eq 0 ]]; then
        return 1
    fi

    local display=()
    local i
    for ((i = 0; i < ${#pending[@]}; i++)); do
        local folder="${pending[$i]}"
        local rel_path="${folder#${ssd_root}/}"
        local count
        count=$(upload_folder_file_count "$folder")
        display+=("${rel_path} (${count} files)")
    done

    local selected
    selected=$(ui_select_multi "Select folders to upload:" "${display[@]}")

    if [[ -z "$selected" ]]; then
        return 1
    fi

    # Strip " (N files)" suffix to recover relative path
    while IFS= read -r line; do
        local rel="${line%% (*}"
        echo "${ssd_root}/${rel}"
    done <<< "$selected"
}

pbak_upload() {
    local ssd_override=""
    local date_filter=""
    local upload_all=0
    local retry_failed=0
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd)          ssd_override="$2"; shift 2 ;;
            --date)         date_filter="$2"; shift 2 ;;
            --all)          upload_all=1; shift ;;
            --retry-failed) retry_failed=1; shift ;;
            --force)        force=1; shift ;;
            -h|--help)      _upload_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _upload_usage; return 1 ;;
        esac
    done

    config_require
    if ! config_validate; then
        ui_error "Immich server details missing. Run 'pbak setup'."
        exit 1
    fi
    utils_check_deps

    ui_header "Photo Upload: SSD -> Immich"

    if utils_is_dry_run; then
        ui_warn "[DRY RUN] immich-go will run in dry-run mode."
    fi

    local ssd_name="${ssd_override:-${PBAK_SSD_VOLUME:-}}"
    if [[ -z "$ssd_name" ]]; then
        local volumes
        volumes=($(utils_list_volumes))
        if [[ ${#volumes[@]} -eq 0 ]]; then
            ui_error "No external volumes found."
            exit 1
        fi
        ssd_name=$(ui_select "Select SSD volume:" "${volumes[@]}")
    fi
    utils_require_volume "$ssd_name" || exit 1

    local ssd_root="/Volumes/${ssd_name}/full_dump"
    if [[ ! -d "$ssd_root" ]]; then
        ui_error "No full_dump directory found at ${ssd_root}"
        exit 1
    fi

    local folders=()

    if [[ $force -eq 1 ]]; then
        ui_warn "Force mode: ignoring upload state, immich-go will skip server-side dupes."
        while IFS= read -r folder; do
            folders+=("$folder")
        done < <(upload_list_folders "$ssd_root")

    elif [[ -n "$date_filter" ]]; then
        local target="${ssd_root}/${date_filter}"
        if [[ ! -d "$target" ]]; then
            ui_error "Folder not found: ${target}"
            exit 1
        fi
        folders+=("$target")

    elif [[ $retry_failed -eq 1 ]]; then
        while IFS= read -r folder; do
            if [[ -d "$folder" ]]; then
                folders+=("$folder")
            fi
        done < <(upload_list_failed)

    elif [[ $upload_all -eq 1 ]]; then
        while IFS= read -r folder; do
            folders+=("$folder")
        done < <(upload_list_pending "$ssd_root")

    else
        while IFS= read -r folder; do
            folders+=("$folder")
        done < <(upload_select_folders "$ssd_root" || true)
    fi

    if [[ ${#folders[@]} -eq 0 ]]; then
        ui_info "Nothing to upload."
        return 0
    fi

    echo
    ui_info "Uploading ${UI_BOLD}${#folders[@]}${UI_RESET} folder(s) to ${PBAK_IMMICH_SERVER}"
    echo

    local uploaded=0 failed=0

    for folder in "${folders[@]}"; do
        local rel_path="${folder#${ssd_root}/}"
        local count
        count=$(upload_folder_file_count "$folder")

        ui_info "Uploading ${UI_BOLD}${rel_path}${UI_RESET} (${count} files)..."
        upload_mark "$folder" "in_progress" "$count" ""

        local exit_code=0
        upload_run "$folder" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            upload_mark "$folder" "uploaded" "$count" "0"
            ui_success "Done: ${rel_path}"
            ((uploaded++))
        else
            upload_mark "$folder" "failed" "$count" "$exit_code"
            ui_error "Failed: ${rel_path} (exit code ${exit_code})"
            ((failed++))
        fi
    done

    echo
    ui_header "Summary"
    ui_success "Uploaded: ${uploaded} folder(s)"
    if [[ $failed -gt 0 ]]; then
        ui_error "Failed:   ${failed} folder(s)"
        ui_dim "  Retry with: pbak upload --retry-failed"
    fi
}

pbak_status() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak status${UI_RESET} — Show backup status and configuration
EOF
            return 0 ;;
    esac

    config_require

    ui_header "pbak v${PBAK_VERSION} — Status"

    printf '  %-24s %s\n' "Immich server:" "${PBAK_IMMICH_SERVER:-<not set>}"
    printf '  %-24s %s\n' "API key:" "${PBAK_IMMICH_API_KEY:+${PBAK_IMMICH_API_KEY:0:8}...}"

    local sd_status="not mounted"
    if [[ -n "${PBAK_SD_VOLUME:-}" ]] && [[ -d "/Volumes/${PBAK_SD_VOLUME}" ]]; then
        sd_status="${UI_GREEN}mounted${UI_RESET}"
    fi
    local ssd_status="not mounted"
    if [[ -n "${PBAK_SSD_VOLUME:-}" ]] && [[ -d "/Volumes/${PBAK_SSD_VOLUME}" ]]; then
        ssd_status="${UI_GREEN}mounted${UI_RESET}"
    fi
    local mirror_status="not mounted"
    if [[ -n "${PBAK_MIRROR_VOLUME:-}" ]] && [[ -d "/Volumes/${PBAK_MIRROR_VOLUME}" ]]; then
        mirror_status="${UI_GREEN}mounted${UI_RESET}"
    fi
    printf '  %-24s %s (%b)\n' "SD card:" "${PBAK_SD_VOLUME:-<not set>}" "$sd_status"
    printf '  %-24s %s (%b)\n' "SSD:" "${PBAK_SSD_VOLUME:-<not set>}" "$ssd_status"
    printf '  %-24s %s (%b)\n' "Mirror SSD:" "${PBAK_MIRROR_VOLUME:-<not set>}" "$mirror_status"
    echo

    local hcount
    hcount=$(hash_count)
    local hsize
    hsize=$(utils_human_size "$(hash_db_size)")
    printf '  %-24s %s files (%s)\n' "Backup database:" "$hcount" "$hsize"

    local up_count up_files fail_count fail_files
    up_count=$(upload_count_by_status "uploaded")
    up_files=$(upload_files_by_status "uploaded")
    fail_count=$(upload_count_by_status "failed")
    fail_files=$(upload_files_by_status "failed")

    echo
    printf '  %-24s %s folder(s), %s files\n' "Uploaded:" "$up_count" "$up_files"
    printf '  %-24s %s folder(s), %s files\n' "Failed:" "$fail_count" "$fail_files"

    if [[ -n "${PBAK_SSD_VOLUME:-}" ]] && [[ -d "/Volumes/${PBAK_SSD_VOLUME}/full_dump" ]]; then
        local pending_count=0
        while IFS= read -r _; do
            ((pending_count++))
        done < <(upload_list_pending "/Volumes/${PBAK_SSD_VOLUME}/full_dump")
        printf '  %-24s %s folder(s)\n' "Pending upload:" "$pending_count"
    fi
    echo
}

pbak_rehash() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
${UI_BOLD}pbak rehash${UI_RESET} — Rebuild hash database from SSD contents

Scans all files in the SSD full_dump directory and rebuilds the hash
database. Useful if the database was lost or corrupted.

${UI_BOLD}Flags:${UI_RESET}
  --ssd <name>    Override SSD volume name
  -h, --help      Show this help
EOF
            return 0 ;;
    esac

    config_require

    local ssd_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssd) ssd_override="$2"; shift 2 ;;
            *) ui_error "Unknown flag: $1"; return 1 ;;
        esac
    done

    local ssd_name="${ssd_override:-${PBAK_SSD_VOLUME:-}}"
    if [[ -z "$ssd_name" ]]; then
        local volumes
        volumes=($(utils_list_volumes))
        ssd_name=$(ui_select "Select SSD volume:" "${volumes[@]}")
    fi
    utils_require_volume "$ssd_name" || exit 1

    local ssd_root="/Volumes/${ssd_name}/full_dump"
    if [[ ! -d "$ssd_root" ]]; then
        ui_error "No full_dump directory at ${ssd_root}"
        exit 1
    fi

    hash_rebuild "$ssd_root"
}
