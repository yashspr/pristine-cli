#!/bin/bash
# Pristine fork: machine-readable `clean`.
#
# Fork-only file (not in upstream Mole). bin/clean.sh sources it and calls
# pristine_clean_main_hook at the top of main(); nothing else in upstream code
# is edited. Behaviour is added by wrapping upstream functions at runtime (see
# pristine_wrap_function), so upstream can rewrite their bodies freely.
#
# Flags: --json, --exclude-from FILE, --admin (see lib/pristine/common.sh).
# Deselection is modelled on Mole's own whitelist (pristine_exclude_via_whitelist):
# the same guards that honour ~/.config/mole/whitelist in preview and in real
# removal (safe_clean, safe_remove, record_dry_run_cleanup_target) honour it.

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/common.sh
source "$_PRISTINE_LIB_DIR/common.sh"

declare -a PRISTINE_CLEAN_ARGS=()

pristine_clean_main_hook() {
    pristine_parse_flags clean "--json --admin --exclude-from" "$@"
    PRISTINE_CLEAN_ARGS=(${PRISTINE_ARGS[@]+"${PRISTINE_ARGS[@]}"})
    pristine_extend_help show_clean_help "--json --admin --exclude-from"

    pristine_exclude_via_whitelist

    [[ "$PRISTINE_JSON" == "true" ]] && pristine_json_begin
    pristine_clean_install_wrappers
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

# Each upstream function is wrapped at most once: a second wrap would rename
# the first wrapper over _pristine_orig_<name> and recurse.
pristine_clean_install_wrappers() {
    if [[ "$PRISTINE_ADMIN" == "true" || "$PRISTINE_JSON" == "true" ]]; then
        # shellcheck disable=SC2329  # Called by upstream code under its original name.
        pristine_wrap_function start_cleanup && start_cleanup() {
            local rc=0
            _pristine_orig_start_cleanup "$@" || rc=$?
            if [[ $rc -eq 0 && "$PRISTINE_ADMIN" == "true" ]]; then
                pristine_clean_acquire_admin
            fi
            [[ "$PRISTINE_JSON" == "true" ]] && pristine_clean_emit_start
            return "$rc"
        }
    fi

    [[ "$PRISTINE_JSON" == "true" ]] || return 0

    pristine_install_operation_events CURRENT_SECTION

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function start_section && start_section() {
        pristine_json_quote "${1:-}"
        pristine_json_emit "{\"type\":\"section\",\"name\":$PRISTINE_JQ}"
        _pristine_orig_start_section "$@"
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
}

pristine_clean_emit_start() {
    local external="null"
    if [[ -n "${EXTERNAL_VOLUME_TARGET:-}" ]]; then
        external=$(pristine_json_str "$EXTERNAL_VOLUME_TARGET")
    fi
    pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"clean\",\"dry_run\":$(pristine_json_bool "${DRY_RUN:-false}"),\"system_clean\":$(pristine_json_bool "${SYSTEM_CLEAN:-false}"),\"external_volume\":$external,\"excluded_paths\":${#PRISTINE_EXCLUDE_PATHS[@]}}"
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
