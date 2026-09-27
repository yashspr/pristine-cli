#!/bin/bash
# Pristine fork: machine-readable `clean`.
#
# Fork-only file (not in upstream Mole). bin/clean.sh sources it and calls
# pristine_clean_main_hook at the top of main(); nothing else in upstream code
# is edited. Behaviour is added by wrapping upstream functions at runtime (see
# pristine_wrap_function), so upstream can rewrite their bodies freely.
#
# Flags (removed from the argument list before upstream parsing sees them):
#   --json               NDJSON events on stdout; human output moves to stderr
#   --exclude-from FILE  Protect the listed paths for this run only
#   --admin              Request admin access (native dialog without a TTY)
#
# Deselection is modelled on Mole's own whitelist: every path in the exclude
# file is appended to WHITELIST_PATTERNS for this process, so the same guards
# that honour ~/.config/mole/whitelist in preview and in real removal
# (safe_clean, safe_remove, record_dry_run_cleanup_target) honour it too.
# Like a whitelist entry, excluding a child also keeps the parent directory.

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/json.sh
source "$_PRISTINE_LIB_DIR/json.sh"

PRISTINE_CLEAN_JSON=false
PRISTINE_CLEAN_ADMIN=false
PRISTINE_CLEAN_EXCLUDED=0
PRISTINE_CLEAN_END_EMITTED=false
declare -a PRISTINE_CLEAN_ARGS=()

pristine_clean_main_hook() {
    local exclude_file=""
    PRISTINE_CLEAN_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                PRISTINE_CLEAN_JSON=true
                ;;
            --admin)
                PRISTINE_CLEAN_ADMIN=true
                ;;
            --exclude-from)
                shift
                if [[ $# -eq 0 || -z "$1" ]]; then
                    echo "Missing file for --exclude-from" >&2
                    exit 1
                fi
                exclude_file="$1"
                ;;
            --exclude-from=*)
                exclude_file="${1#--exclude-from=}"
                if [[ -z "$exclude_file" ]]; then
                    echo "Missing file for --exclude-from" >&2
                    exit 1
                fi
                ;;
            *)
                PRISTINE_CLEAN_ARGS+=("$1")
                ;;
        esac
        shift
    done

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function show_clean_help && show_clean_help() {
        _pristine_orig_show_clean_help "$@"
        echo ""
        echo "Pristine options:"
        echo "  --json               Stream NDJSON events on stdout (human output goes to stderr)"
        echo "  --exclude-from FILE  Protect the paths listed in FILE (one per line) for this run"
        echo "  --admin              Request admin access for system caches (native dialog without a TTY)"
    }

    if [[ -n "$exclude_file" ]]; then
        pristine_clean_load_excludes "$exclude_file" || exit 1
    fi

    if [[ "$PRISTINE_CLEAN_JSON" == "true" ]]; then
        pristine_json_begin
    fi
    pristine_clean_install_wrappers
}

# Append exclude-file paths to the in-memory whitelist. Validation mirrors
# load_mole_whitelist; a file that cannot be read aborts the run rather than
# cleaning something the caller meant to keep.
pristine_clean_load_excludes() {
    local file="$1"
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "Cannot read exclude file: $file" >&2
        return 1
    fi

    local line existing duplicate
    local home="${MOLE_USER_HOME:-$HOME}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == \~ || "$line" == \~/* ]] && line="$home${line#\~}"

        if [[ "$line" != /* ]]; then
            echo "Exclude path must be absolute: $line" >&2
            return 1
        fi
        if [[ "$line" =~ [[:cntrl:]] ]]; then
            echo "Exclude path contains control characters" >&2
            return 1
        fi
        [[ "$line" == "$FINDER_METADATA_SENTINEL" ]] && continue

        duplicate=false
        if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
            for existing in "${WHITELIST_PATTERNS[@]}"; do
                if [[ "$existing" == "$line" ]]; then
                    duplicate=true
                    break
                fi
            done
        fi
        [[ "$duplicate" == "true" ]] && continue

        WHITELIST_PATTERNS+=("$line")
        PRISTINE_CLEAN_EXCLUDED=$((PRISTINE_CLEAN_EXCLUDED + 1))
    done < "$file"
    return 0
}

# Each upstream function is wrapped at most once: a second wrap would rename
# the first wrapper over _pristine_orig_<name> and recurse.
pristine_clean_install_wrappers() {
    if [[ "$PRISTINE_CLEAN_ADMIN" == "true" || "$PRISTINE_CLEAN_JSON" == "true" ]]; then
        # shellcheck disable=SC2329  # Called by upstream code under its original name.
        pristine_wrap_function start_cleanup && start_cleanup() {
            local rc=0
            _pristine_orig_start_cleanup "$@" || rc=$?
            if [[ $rc -eq 0 && "$PRISTINE_CLEAN_ADMIN" == "true" ]]; then
                pristine_clean_acquire_admin
            fi
            [[ "$PRISTINE_CLEAN_JSON" == "true" ]] && pristine_clean_emit_start
            return "$rc"
        }
    fi

    [[ "$PRISTINE_CLEAN_JSON" == "true" ]] || return 0

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function start_section && start_section() {
        pristine_json_quote "${1:-}"
        pristine_json_emit "{\"type\":\"section\",\"name\":$PRISTINE_JQ}"
        _pristine_orig_start_section "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function log_operation && log_operation() {
        local action path detail section
        pristine_json_quote "${2:-UNKNOWN}"
        action="$PRISTINE_JQ"
        pristine_json_quote "${3:-}"
        path="$PRISTINE_JQ"
        pristine_json_quote "${4:-}"
        detail="$PRISTINE_JQ"
        pristine_json_quote "${CURRENT_SECTION:-}"
        section="$PRISTINE_JQ"
        [[ -n "${3:-}" ]] && pristine_json_emit "{\"type\":\"operation\",\"action\":$action,\"path\":$path,\"detail\":$detail,\"section\":$section}"
        _pristine_orig_log_operation "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function perform_cleanup && perform_cleanup() {
        local rc=0
        _pristine_orig_perform_cleanup "$@" || rc=$?
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            pristine_clean_emit_preview_items
        fi
        pristine_clean_emit_summary "$rc"
        return "$rc"
    }

    # The EXIT/INT/TERM traps call cleanup by name, so the wrapper sees every
    # way the process ends, including an early `exit 1`.
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function cleanup && cleanup() {
        local signal="${1:-EXIT}"
        local exit_code="${2:-$?}"
        _pristine_orig_cleanup "$@"
        if [[ "$PRISTINE_CLEAN_END_EMITTED" != "true" ]]; then
            PRISTINE_CLEAN_END_EMITTED=true
            pristine_json_quote "$signal"
            pristine_json_emit "{\"type\":\"end\",\"exit_code\":$(pristine_json_int "$exit_code"),\"signal\":$PRISTINE_JQ}"
        fi
    }
}

# Upstream only adopts an existing sudo session when stdin is not a TTY.
# ensure_sudo_session prompts itself: a native dialog when there is no
# terminal, and never under MOLE_TEST_MODE / MOLE_TEST_NO_AUTH.
pristine_clean_acquire_admin() {
    [[ -z "${EXTERNAL_VOLUME_TARGET:-}" && "${SYSTEM_CLEAN:-false}" != "true" ]] || return 0
    if ensure_sudo_session "System cleanup requires admin access"; then
        SYSTEM_CLEAN=true
        echo "Admin access granted"
    else
        echo "Admin access not granted, continuing with user-level cleanup"
    fi
}

pristine_clean_emit_start() {
    local external="null"
    if [[ -n "${EXTERNAL_VOLUME_TARGET:-}" ]]; then
        external=$(pristine_json_str "$EXTERNAL_VOLUME_TARGET")
    fi
    pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"clean\",\"dry_run\":$(pristine_json_bool "${DRY_RUN:-false}"),\"system_clean\":$(pristine_json_bool "${SYSTEM_CLEAN:-false}"),\"external_volume\":$external,\"excluded_paths\":$PRISTINE_CLEAN_EXCLUDED}"
}

# One "item" event per deduplicated preview row, from the same ledger that
# renders ~/.config/mole/clean-list.txt. A row with covered_by is inside
# another listed row: show it (it can be excluded on its own) but do not add
# its size to a total, the covering row already counts those bytes.
pristine_clean_emit_preview_items() {
    declare -f emit_deduplicated_dry_run_ledger > /dev/null 2>&1 || return 0
    [[ -n "${CLEAN_PREVIEW_LEDGER_FILE:-}" && -f "$CLEAN_PREVIEW_LEDGER_FILE" ]] || return 0

    local identity size_kb count size_known section path covered_by
    local j_path j_section j_covered j_size
    while IFS= read -r -d '' identity &&
        IFS= read -r -d '' size_kb &&
        IFS= read -r -d '' count &&
        IFS= read -r -d '' size_known &&
        IFS= read -r -d '' section &&
        IFS= read -r -d '' path &&
        IFS= read -r -d '' covered_by; do
        [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
        if [[ "$size_known" == "true" && "$size_kb" =~ ^[0-9]+$ ]]; then
            j_size="$size_kb"
        else
            j_size="null"
            size_known=false
        fi
        pristine_json_quote "$path"
        j_path="$PRISTINE_JQ"
        pristine_json_quote "$section"
        j_section="$PRISTINE_JQ"
        if [[ -n "$covered_by" ]]; then
            pristine_json_quote "$covered_by"
            j_covered="$PRISTINE_JQ"
        else
            j_covered="null"
        fi
        pristine_json_emit "{\"type\":\"item\",\"path\":$j_path,\"section\":$j_section,\"size_kb\":$j_size,\"size_known\":$size_known,\"item_count\":$count,\"covered_by\":$j_covered}"
    done < <(emit_deduplicated_dry_run_ledger)
}

pristine_clean_emit_summary() {
    local rc="${1:-0}"
    local status="complete"
    if [[ "$rc" -ne 0 ]]; then
        if mole_rc_timeout "$rc"; then
            status="cancelled"
        elif [[ "$rc" -ge 128 ]]; then
            status="interrupted"
        else
            status="incomplete"
        fi
    fi

    local partial=false
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        [[ "${DRY_RUN_TOTAL_PARTIAL:-false}" == "true" ]] && partial=true
    else
        [[ "${MOLE_CLEAN_SIZING_TIMEOUTS:-0}" -gt 0 ]] && partial=true
    fi

    local free_kb=""
    if [[ -z "${EXTERNAL_VOLUME_TARGET:-}" ]]; then
        free_kb=$(get_free_space_kb 2> /dev/null) || free_kb=""
    fi

    local preview_file="null"
    if [[ "${DRY_RUN:-false}" == "true" && -n "${CLEAN_PREVIEW_FINAL_FILE:-}" ]]; then
        preview_file=$(pristine_json_str "$CLEAN_PREVIEW_FINAL_FILE")
    fi

    pristine_json_emit "{\"type\":\"summary\",\"dry_run\":$(pristine_json_bool "${DRY_RUN:-false}"),\"status\":\"$status\",\"exit_code\":$(pristine_json_int "$rc"),\"size_kb\":$(pristine_json_int "${total_size_cleaned:-0}"),\"size_partial\":$partial,\"items\":$(pristine_json_int "${files_cleaned:-0}"),\"categories\":$(pristine_json_int "${total_items:-0}"),\"system_clean\":$(pristine_json_bool "${SYSTEM_CLEAN:-false}"),\"permission_denied\":$(pristine_json_int "${MOLE_PERMISSION_DENIED_COUNT:-0}"),\"removal_timeouts\":$(pristine_json_int "${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0}"),\"free_space_kb\":$(pristine_json_int "$free_kb"),\"preview_file\":$preview_file}"
}
