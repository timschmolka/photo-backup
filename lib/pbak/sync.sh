#!/bin/bash

_sync_usage() {
    cat <<EOF
${UI_BOLD}pbak sync${UI_RESET} — Sync primary SSD to a mirror SSD

One-way additive sync using rsync. New files on the primary are copied
to the mirror. Nothing is ever deleted from the mirror.

${UI_BOLD}Flags:${UI_RESET}
  --from <name>     Primary SSD volume name (source)
  --to <name>       Mirror SSD volume name (destination)
  -h, --help        Show this help

${UI_BOLD}Global flags also apply:${UI_RESET}  --dry-run, --verbose
EOF
}

pbak_sync() {
    local from_override=""
    local to_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)    from_override="$2"; shift 2 ;;
            --to)      to_override="$2"; shift 2 ;;
            -h|--help) _sync_usage; return 0 ;;
            *) ui_error "Unknown flag: $1"; _sync_usage; return 1 ;;
        esac
    done

    config_require

    ui_header "SSD Sync: Primary -> Mirror"

    local from_name="${from_override:-${PBAK_SSD_VOLUME:-}}"
    local to_name="${to_override:-${PBAK_MIRROR_VOLUME:-}}"

    if [[ -z "$from_name" ]]; then
        local volumes
        volumes=($(utils_list_volumes))
        if [[ ${#volumes[@]} -eq 0 ]]; then
            ui_error "No external volumes found."
            exit 1
        fi
        from_name=$(ui_select "Select PRIMARY SSD (source):" "${volumes[@]}")
    fi
    utils_require_volume "$from_name" || exit 1

    if [[ -z "$to_name" ]]; then
        local volumes
        volumes=($(utils_list_volumes))
        # Filter out the primary so you can't sync to yourself
        local filtered=()
        local v
        for v in "${volumes[@]}"; do
            [[ "$v" != "$from_name" ]] && filtered+=("$v")
        done
        if [[ ${#filtered[@]} -eq 0 ]]; then
            ui_error "No other volumes found for mirror."
            exit 1
        fi
        to_name=$(ui_select "Select MIRROR SSD (destination):" "${filtered[@]}")
    fi
    utils_require_volume "$to_name" || exit 1
    utils_volume_is_writable "$to_name" || exit 1

    local src="/Volumes/${from_name}/full_dump/"
    local dst="/Volumes/${to_name}/full_dump/"

    if [[ ! -d "$src" ]]; then
        ui_error "No full_dump directory on primary (${src})"
        exit 1
    fi

    utils_ensure_dir "$dst"

    ui_info "Source: ${src}"
    ui_info "Mirror: ${dst}"
    echo

    # Trailing slash on src is critical — rsync copies contents, not the directory itself
    local rsync_args=(
        -av
        --ignore-existing
        --progress
    )

    if utils_is_dry_run; then
        rsync_args+=(--dry-run)
        ui_warn "[DRY RUN] No files will be copied."
        echo
    fi

    rsync "${rsync_args[@]}" "$src" "$dst"
    local exit_code=$?

    echo
    if [[ $exit_code -eq 0 ]]; then
        ui_success "Sync complete."
    else
        ui_error "rsync exited with code ${exit_code}"
        return "$exit_code"
    fi
}
