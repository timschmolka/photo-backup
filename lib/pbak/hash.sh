#!/bin/bash
# DB format: tab-separated, one line per file
# <sha256>\t<source_path>\t<dest_path>\t<timestamp>\t<file_size_bytes>

hash_db_file() {
    local f="$(config_dir)/hashes.db"
    [[ -f "$f" ]] || touch "$f"
    echo "$f"
}

hash_compute() {
    local filepath="$1"
    shasum -a 256 "$filepath" 2>/dev/null | cut -d ' ' -f 1
}

hash_exists() {
    local hash="$1"
    local db
    db="$(hash_db_file)"
    # Tab after hash prevents prefix matches
    grep -qF "${hash}	" "$db" 2>/dev/null
}

hash_add() {
    local hash="$1"
    local src_path="$2"
    local dest_path="$3"
    local size="$4"
    local ts
    ts="$(utils_timestamp)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$hash" "$src_path" "$dest_path" "$ts" "$size" >> "$(hash_db_file)"
}

hash_get_dest() {
    local hash="$1"
    local db
    db="$(hash_db_file)"
    grep -F "${hash}	" "$db" 2>/dev/null | head -1 | cut -f 3
}

hash_count() {
    local db
    db="$(hash_db_file)"
    local count
    count=$(wc -l < "$db" 2>/dev/null)
    # macOS wc adds leading spaces
    echo "${count// /}"
}

hash_db_size() {
    utils_file_size "$(hash_db_file)"
}

hash_dest_exists() {
    local dest_path="$1"
    local db
    db="$(hash_db_file)"
    grep -qF "	${dest_path}	" "$db" 2>/dev/null
}

hash_resolve_collision() {
    local dest_dir="$1"
    local basename="$2"
    local ext="$3"

    local candidate="${dest_dir}/${basename}${ext}"

    if ! hash_dest_exists "$candidate" && [[ ! -f "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    local counter=2
    while true; do
        candidate="${dest_dir}/${basename}_${counter}${ext}"
        if ! hash_dest_exists "$candidate" && [[ ! -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
        ((counter++))
        if [[ $counter -gt 9999 ]]; then
            ui_error "Too many filename collisions for ${basename}${ext}"
            return 1
        fi
    done
}

hash_rebuild() {
    local ssd_root="$1"
    local db
    db="$(hash_db_file)"

    ui_header "Rebuilding hash database"
    ui_info "Scanning: ${ssd_root}"

    local total=0
    while IFS= read -r -d '' _; do
        ((total++))
    done < <(find "$ssd_root" -type f -print0 2>/dev/null)

    if [[ $total -eq 0 ]]; then
        ui_warn "No files found in ${ssd_root}"
        return 0
    fi

    ui_info "Found ${total} files to hash"

    if [[ -s "$db" ]]; then
        cp "$db" "${db}.bak"
        ui_dim "  Existing DB backed up to ${db}.bak"
    fi

    : > "$db"

    local count=0
    while IFS= read -r -d '' filepath; do
        ((count++))
        ui_progress "$count" "$total" "$(basename "$filepath")"

        local hash size ts
        hash=$(hash_compute "$filepath")
        size=$(utils_file_size "$filepath")
        ts=$(utils_timestamp)

        # Original source path is unknown when rebuilding from SSD
        printf '%s\t%s\t%s\t%s\t%s\n' "$hash" "(rebuilt)" "$filepath" "$ts" "$size" >> "$db"
    done < <(find "$ssd_root" -type f -print0 2>/dev/null)

    ui_progress_done
    ui_success "Hash database rebuilt: ${count} files indexed."
}
