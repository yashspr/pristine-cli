#!/bin/bash
# Pristine fork: helpers shared by every machine-readable command.
# Fork-only file; see CHANGES-FORK.md.
#
# Common flags (stripped before upstream argument parsing sees them):
#   --json               NDJSON events on stdout, human output on stderr
#   --admin              allow an admin prompt (native dialog without a TTY);
#                        without it a --json run only adopts a cached sudo session
#   --exclude-from FILE  never touch the listed paths
#   --only-from FILE     touch only the listed paths (commands that support it)
#
# The final {"type":"end"} event is written by the `pristine` entrypoint after
# the command exits, so it survives upstream trap changes and signals.

if [[ -n "${PRISTINE_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly PRISTINE_COMMON_LOADED=1

_PRISTINE_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/json.sh
source "$_PRISTINE_COMMON_DIR/json.sh"

PRISTINE_JSON=false
PRISTINE_ADMIN=false
PRISTINE_EXCLUDE_FILE=""
PRISTINE_ONLY_FILE=""
declare -a PRISTINE_ARGS=()
declare -a PRISTINE_EXCLUDE_PATHS=()
declare -a PRISTINE_ONLY_PATHS=()
declare -a PRISTINE_PATH_LIST=()

# Split fork flags from upstream ones. Upstream args land in PRISTINE_ARGS.
# $1 is the command name for messages; $2 lists the flags it supports.
pristine_parse_flags() {
    local command="$1" supported="$2"
    shift 2
    PRISTINE_ARGS=()

    local flag value
    while [[ $# -gt 0 ]]; do
        flag="$1"
        value=""
        case "$flag" in
            --exclude-from=* | --only-from=*)
                value="${flag#*=}"
                flag="${flag%%=*}"
                ;;
            --exclude-from | --only-from)
                shift
                value="${1:-}"
                ;;
            --json | --admin) ;;
            *)
                PRISTINE_ARGS+=("$1")
                shift
                continue
                ;;
        esac

        if [[ " $supported " != *" $flag "* ]]; then
            echo "Option $flag is not supported by $command" >&2
            exit 1
        fi
        case "$flag" in
            --json) PRISTINE_JSON=true ;;
            --admin) PRISTINE_ADMIN=true ;;
            --exclude-from | --only-from)
                if [[ -z "$value" ]]; then
                    echo "Missing file for $flag" >&2
                    exit 1
                fi
                pristine_read_path_file "$value" || exit 1
                if [[ "$flag" == "--exclude-from" ]]; then
                    PRISTINE_EXCLUDE_FILE="$value"
                    PRISTINE_EXCLUDE_PATHS=(${PRISTINE_PATH_LIST[@]+"${PRISTINE_PATH_LIST[@]}"})
                else
                    PRISTINE_ONLY_FILE="$value"
                    PRISTINE_ONLY_PATHS=(${PRISTINE_PATH_LIST[@]+"${PRISTINE_PATH_LIST[@]}"})
                fi
                ;;
        esac
        shift
    done

    if [[ -n "$PRISTINE_EXCLUDE_FILE" && -n "$PRISTINE_ONLY_FILE" ]]; then
        echo "Use either --exclude-from or --only-from, not both" >&2
        exit 1
    fi
}

# Read newline-separated absolute paths (`~/` allowed, `#` comments) into
# PRISTINE_PATH_LIST. A file that cannot be read or holds an invalid line
# fails the run before anything is scanned.
pristine_read_path_file() {
    local file="$1"
    PRISTINE_PATH_LIST=()
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "Cannot read path list: $file" >&2
        return 1
    fi

    local line
    local home="${MOLE_USER_HOME:-$HOME}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == \~ || "$line" == \~/* ]] && line="$home${line#\~}"
        if [[ "$line" != /* ]]; then
            echo "Path must be absolute: $line" >&2
            return 1
        fi
        if [[ "$line" =~ [[:cntrl:]] ]]; then
            echo "Path contains control characters: $file" >&2
            return 1
        fi
        # Compare without a trailing slash, as the upstream matchers do.
        [[ ${#line} -gt 1 ]] && line="${line%/}"
        PRISTINE_PATH_LIST+=("$line")
    done < "$file"
    return 0
}

# pristine_path_listed PATH ELEMENTS... → 0 when PATH equals one element.
pristine_path_listed() {
    local needle="${1%/}" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Append the exclude list to Mole's in-memory whitelist, so every guard that
# honours ~/.config/mole/whitelist in preview and in removal honours it too.
# Like a whitelist entry, excluding a path also keeps its parent directories.
pristine_exclude_via_whitelist() {
    local path existing duplicate
    [[ ${#PRISTINE_EXCLUDE_PATHS[@]} -gt 0 ]] || return 0
    for path in "${PRISTINE_EXCLUDE_PATHS[@]}"; do
        [[ "$path" == "${FINDER_METADATA_SENTINEL:-}" ]] && continue
        duplicate=false
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$existing" == "$path" ]]; then
                    duplicate=true
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] || WHITELIST_PATTERNS+=("$path")
    done
}

# Without --admin, a --json run must never raise a password prompt: the
# caller asked for a non-interactive run. Adopt a cached sudo session only.
pristine_install_admin_policy() {
    [[ "$PRISTINE_JSON" == "true" && "$PRISTINE_ADMIN" != "true" ]] || return 0
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function ensure_sudo_session && ensure_sudo_session() {
        adopt_sudo_session
    }
}

# One "operation" event per REMOVED / TRASHED / SKIPPED / FAILED log line.
# $1 names a variable holding the current section or app (may be empty).
pristine_install_operation_events() {
    PRISTINE_OPERATION_CONTEXT_VAR="${1:-}"
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function log_operation && log_operation() {
        if [[ -n "${3:-}" ]]; then
            local action path detail context=""
            pristine_json_quote "${2:-UNKNOWN}"
            action="$PRISTINE_JQ"
            pristine_json_quote "$3"
            path="$PRISTINE_JQ"
            pristine_json_quote "${4:-}"
            detail="$PRISTINE_JQ"
            if [[ -n "$PRISTINE_OPERATION_CONTEXT_VAR" ]]; then
                pristine_json_quote "${!PRISTINE_OPERATION_CONTEXT_VAR:-}"
                context=",\"section\":$PRISTINE_JQ"
            fi
            pristine_json_emit "{\"type\":\"operation\",\"action\":$action,\"path\":$path,\"detail\":$detail$context}"
        fi
        _pristine_orig_log_operation "$@"
    }
}

# Replace `show_<cmd>_help` output with upstream help plus the fork flags.
pristine_extend_help() {
    local help_fn="$1" flags="$2"
    PRISTINE_HELP_FLAGS="$flags"
    pristine_wrap_function "$help_fn" || return 0
    eval "$help_fn() {
        _pristine_orig_$help_fn \"\$@\"
        pristine_print_flag_help
    }"
}

pristine_print_flag_help() {
    echo ""
    echo "Pristine options:"
    local flag
    for flag in $PRISTINE_HELP_FLAGS; do
        case "$flag" in
            --json) echo "  --json               Stream NDJSON events on stdout (human output goes to stderr)" ;;
            --admin) echo "  --admin              Allow an admin prompt (native dialog without a TTY)" ;;
            --exclude-from) echo "  --exclude-from FILE  Never touch the paths listed in FILE (one per line)" ;;
            --only-from) echo "  --only-from FILE     Touch only the paths listed in FILE (one per line)" ;;
            --yes) echo "  --yes                Confirm removal in a non-interactive --json run" ;;
            --skip-from) echo "  --skip-from FILE     Record the task ids listed in FILE as skipped instead of running them" ;;
        esac
    done
}

pristine_json_size_kb_from_bytes() {
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' $((($1 + 1023) / 1024))
    else
        printf 'null'
    fi
}

# MOLE_DRY_RUN=1 (set by upstream --dry-run parsing) as a JSON boolean.
pristine_mole_dry_run_json() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && printf true || printf false
}
