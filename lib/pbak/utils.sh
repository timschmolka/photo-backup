#!/bin/bash

utils_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        DEBUG) [[ "${VERBOSE:-0}" -eq 1 ]] && printf '%s [DEBUG] %s\n' "$ts" "$msg" >&2 ;;
        INFO)  printf '%s [INFO]  %s\n' "$ts" "$msg" >&2 ;;
        WARN)  printf '%s [WARN]  %s\n' "$ts" "$msg" >&2 ;;
        ERROR) printf '%s [ERROR] %s\n' "$ts" "$msg" >&2 ;;
    esac
}

utils_check_deps() {
    local missing=0

    # "command:brew_package" — empty brew_package means system tool, skip install offer
    local deps=(
        "immich-go:immich-go"
        "exiftool:exiftool"
        "shasum:"
    )

    for entry in "${deps[@]}"; do
        local cmd="${entry%%:*}"
        local brew_pkg="${entry#*:}"

        if ! command -v "$cmd" &>/dev/null; then
            if [[ -n "$brew_pkg" ]]; then
                ui_warn "'${cmd}' is not installed."
                if ui_confirm "  Install '${cmd}' via Homebrew?"; then
                    ui_info "Running: brew install ${brew_pkg}"
                    if brew install "$brew_pkg"; then
                        if command -v "$cmd" &>/dev/null; then
                            ui_success "'${cmd}' installed successfully."
                        else
                            ui_error "'${cmd}' still not found after install."
                            ((missing++))
                        fi
                    else
                        ui_error "Failed to install '${cmd}'."
                        ((missing++))
                    fi
                else
                    ((missing++))
                fi
            else
                ui_error "Required system tool '${cmd}' is not available."
                ((missing++))
            fi
        fi
    done

    if [[ $missing -gt 0 ]]; then
        ui_error "Cannot continue: ${missing} missing dependency(ies)."
        exit 1
    fi
}

utils_list_volumes() {
    local vol
    for vol in /Volumes/*/; do
        vol="${vol%/}"
        local name="${vol##*/}"
        [[ "$name" == "Macintosh HD" ]] && continue
        [[ "$name" == "Macintosh HD - Data" ]] && continue
        echo "$name"
    done
}

utils_require_volume() {
    local name="$1"
    local path="/Volumes/${name}"
    if [[ ! -d "$path" ]]; then
        ui_error "Volume '${name}' is not mounted (${path} not found)."
        return 1
    fi
}

utils_volume_is_writable() {
    local name="$1"
    local path="/Volumes/${name}"
    if [[ ! -w "$path" ]]; then
        ui_error "Volume '${name}' is not writable."
        return 1
    fi
}

utils_volume_available_kb() {
    local name="$1"
    df -k "/Volumes/${name}" 2>/dev/null | tail -1 | awk '{print $4}'
}

utils_ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            utils_log DEBUG "Would create directory: ${dir}"
        else
            mkdir -p "$dir"
        fi
    fi
}

utils_is_dry_run() {
    [[ "${DRY_RUN:-0}" -eq 1 ]]
}

utils_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S'
}

utils_human_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        printf '%d.%d GB' "$((bytes / 1073741824))" "$(( (bytes % 1073741824) * 10 / 1073741824 ))"
    elif [[ $bytes -ge 1048576 ]]; then
        printf '%d.%d MB' "$((bytes / 1048576))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
    elif [[ $bytes -ge 1024 ]]; then
        printf '%d.%d KB' "$((bytes / 1024))" "$(( (bytes % 1024) * 10 / 1024 ))"
    else
        printf '%d B' "$bytes"
    fi
}

utils_file_size() {
    stat -f '%z' "$1" 2>/dev/null || echo 0
}
