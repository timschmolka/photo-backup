#compdef pbak

_pbak_volumes() {
    local -a vols
    for v in /Volumes/*/; do
        v="${v%/}"
        v="${v##*/}"
        [[ "$v" == "Macintosh HD" ]] && continue
        [[ "$v" == "Macintosh HD - Data" ]] && continue
        vols+=("$v")
    done
    _describe 'volume' vols
}

_pbak_date_folders() {
    local ssd="${PBAK_SSD_VOLUME:-}"
    [[ -z "$ssd" ]] && return
    local root="/Volumes/${ssd}/full_dump"
    [[ -d "$root" ]] || return
    local -a dates
    for d in "$root"/*/*/; do
        d="${d%/}"
        d="${d#${root}/}"
        dates+=("$d")
    done
    _describe 'date folder' dates
}

_pbak() {
    local -a commands=(
        'setup:Configure Immich server, volumes, and extensions'
        'dump:Copy photos from SD card to SSD'
        'upload:Upload photos from SSD to Immich'
        'status:Show backup status and configuration'
        'rehash:Rebuild hash database from SSD'
    )

    local -a global_flags=(
        '--dry-run[Show what would be done without changes]'
        '--verbose[Enable verbose output]'
        '--version[Print version]'
        '(-h --help)'{-h,--help}'[Show help]'
    )

    _arguments -C \
        $global_flags \
        '1:command:->command' \
        '*::arg:->args'

    case $state in
        command)
            _describe 'command' commands
            ;;
        args)
            case ${words[1]} in
                dump)
                    _arguments \
                        '--sd[SD card volume name]:volume:_pbak_volumes' \
                        '--ssd[SSD volume name]:volume:_pbak_volumes' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                upload)
                    _arguments \
                        '--ssd[SSD volume name]:volume:_pbak_volumes' \
                        '--date[Specific date folder]:date:_pbak_date_folders' \
                        '--all[Upload all pending folders]' \
                        '--retry-failed[Retry failed uploads]' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                rehash)
                    _arguments \
                        '--ssd[SSD volume name]:volume:_pbak_volumes' \
                        '(-h --help)'{-h,--help}'[Show help]'
                    ;;
                setup|status)
                    _arguments '(-h --help)'{-h,--help}'[Show help]'
                    ;;
            esac
            ;;
    esac
}

_pbak "$@"
