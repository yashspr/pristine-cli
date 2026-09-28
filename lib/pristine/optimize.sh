#!/bin/bash
# Pristine fork: machine-readable `optimize`.
# Fork-only file; bin/optimize.sh sources it and calls
# pristine_optimize_main_hook at the top of main(). See CHANGES-FORK.md.
#
#   optimize --json [--dry-run] [--admin] [--skip-from FILE]
#
# Every task passes through execute_optimization, which the fork wraps to emit
# one "task" event with the recorded outcome (applied / unchanged / skipped /
# unavailable / attention / failed) and the task's own messages as detail.
# --skip-from lists task ids (one per line) to record as skipped without
# running them; ids come from the "start" event's task list.

_PRISTINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pristine/common.sh
source "$_PRISTINE_LIB_DIR/common.sh"

declare -a PRISTINE_OPTIMIZE_ARGS=()
declare -a PRISTINE_OPTIMIZE_SKIP=()

pristine_optimize_main_hook() {
    local -a rest=()
    local skip_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-from)
                shift
                skip_file="${1:-}"
                [[ -n "$skip_file" ]] || {
                    echo "Missing file for --skip-from" >&2
                    exit 1
                }
                ;;
            --skip-from=*) skip_file="${1#--skip-from=}" ;;
            *) rest+=("$1") ;;
        esac
        shift
    done

    pristine_parse_flags optimize "--json --admin" ${rest[@]+"${rest[@]}"}
    PRISTINE_OPTIMIZE_ARGS=(${PRISTINE_ARGS[@]+"${PRISTINE_ARGS[@]}"})
    pristine_extend_help show_optimize_help "--json --admin --skip-from"

    if [[ -n "$skip_file" ]]; then
        pristine_optimize_read_skip_file "$skip_file" || exit 1
    fi
    if [[ "$PRISTINE_JSON" == "true" ]]; then
        local arg
        for arg in ${PRISTINE_OPTIMIZE_ARGS[@]+"${PRISTINE_OPTIMIZE_ARGS[@]}"}; do
            if [[ "$arg" == "--whitelist" ]]; then
                echo "--whitelist is interactive and cannot be combined with --json" >&2
                exit 1
            fi
        done
    fi

    pristine_optimize_install_wrappers
}

pristine_optimize_read_skip_file() {
    local file="$1" line
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "Cannot read task list: $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        if ! pristine_path_listed "$line" "${MOLE_OPTIMIZE_ACTIONS[@]}"; then
            echo "Unknown optimize task id: $line" >&2
            return 1
        fi
        PRISTINE_OPTIMIZE_SKIP+=("$line")
    done < "$file"
}

# execute_optimization is wrapped once for both --skip-from and --json: a
# second wrap would rename the first wrapper over the original and recurse.
pristine_optimize_install_wrappers() {
    if [[ ${#PRISTINE_OPTIMIZE_SKIP[@]} -gt 0 || "$PRISTINE_JSON" == "true" ]]; then
        # shellcheck disable=SC2329  # Called by upstream code under its original name.
        pristine_wrap_function execute_optimization && execute_optimization() {
            if [[ "$PRISTINE_JSON" == "true" ]]; then
                pristine_optimize_run_task_json "$@"
            else
                pristine_optimize_run_task "$@"
            fi
        }
    fi

    [[ "$PRISTINE_JSON" == "true" ]] || return 0
    pristine_json_begin
    pristine_install_admin_policy
    pristine_install_operation_events PRISTINE_OPTIMIZE_CURRENT_TASK

    # Called once, just before the task loop: the right moment for "start".
    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function optimize_outcomes_reset && optimize_outcomes_reset() {
        _pristine_orig_optimize_outcomes_reset
        pristine_optimize_emit_start
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function show_system_health && show_system_health() {
        local health="${1:-}"
        if [[ "$health" == \{* ]]; then
            # Health JSON is validated upstream; JSON strings cannot hold raw
            # newlines, so folding them keeps it one NDJSON line.
            health="${health//$'\n'/ }"
            pristine_json_emit "{\"type\":\"health\",\"data\":$health}"
        fi
        _pristine_orig_show_system_health "$@"
    }

    # shellcheck disable=SC2329  # Called by upstream code under its original name.
    pristine_wrap_function show_optimization_summary && show_optimization_summary() {
        _pristine_orig_show_optimization_summary
        pristine_optimize_emit_summary
    }
}

pristine_optimize_run_task() {
    if [[ ${#PRISTINE_OPTIMIZE_SKIP[@]} -gt 0 ]] && pristine_path_listed "$1" "${PRISTINE_OPTIMIZE_SKIP[@]}"; then
        # Record an outcome: main() refuses a run with a task missing.
        optimize_task_start
        opt_msg "Skipped (deselected): $(optimize_catalog_health_name_for "$1")"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        optimize_task_finish "$1"
        return 0
    fi
    _pristine_orig_execute_optimization "$@"
}

# A redirect on a function call keeps it in this shell, so the outcome arrays
# survive; the captured text becomes the event detail. The call is deliberately
# bare (no `|| rc=`): that would disable errexit inside the handler and change
# how upstream aborts.
pristine_optimize_run_task_json() {
    local action="$1" label capture
    label=$(optimize_catalog_health_name_for "$action" 2> /dev/null || printf '%s' "$action")
    PRISTINE_OPTIMIZE_CURRENT_TASK="$action"
    capture=$(create_temp_file)
    pristine_optimize_run_task "$@" > "$capture"
    cat "$capture"
    pristine_optimize_emit_task "$action" "$label" "$capture"
    PRISTINE_OPTIMIZE_CURRENT_TASK=""
}

pristine_optimize_emit_start() {
    local tasks="" i id label
    for ((i = 0; i < ${#MOLE_OPTIMIZE_ACTIONS[@]}; i++)); do
        id="${MOLE_OPTIMIZE_ACTIONS[$i]}"
        pristine_json_quote "${MOLE_OPTIMIZE_HEALTH_NAMES[$i]:-$id}"
        label="$PRISTINE_JQ"
        [[ -n "$tasks" ]] && tasks+=","
        tasks+="{\"id\":\"$id\",\"label\":$label,\"skip\":$(pristine_path_listed "$id" ${PRISTINE_OPTIMIZE_SKIP[@]+"${PRISTINE_OPTIMIZE_SKIP[@]}"} && printf true || printf false)}"
    done
    local dry_run=false
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && dry_run=true
    pristine_json_emit "{\"type\":\"start\",\"schema_version\":$PRISTINE_JSON_SCHEMA_VERSION,\"command\":\"optimize\",\"dry_run\":$dry_run,\"admin\":$(pristine_json_bool "${MOLE_OPTIMIZE_SUDO_AVAILABLE:-false}"),\"tasks\":[$tasks]}"
}

pristine_optimize_emit_task() {
    local action="$1" label="$2" capture="$3"
    local outcome="" n=${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]}
    if [[ $n -gt 0 && "${MOLE_OPTIMIZE_RESULT_ACTIONS[$((n - 1))]}" == "$action" ]]; then
        outcome="${MOLE_OPTIMIZE_RESULT_OUTCOMES[$((n - 1))]}"
    fi

    # Task messages without colour codes, one line each, joined with "; ".
    local esc detail="" line
    esc=$(printf '\033')
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed "s/${esc}\[[0-9;]*m//g; s/^[[:space:]]*//; s/[[:space:]]*$//")
        [[ -n "$line" ]] || continue
        [[ -n "$detail" ]] && detail+="; "
        detail+="$line"
    done < "$capture"

    local j_label j_detail j_outcome="null"
    pristine_json_quote "$label"
    j_label="$PRISTINE_JQ"
    pristine_json_quote "$detail"
    j_detail="$PRISTINE_JQ"
    [[ -n "$outcome" ]] && j_outcome="\"$outcome\""
    pristine_json_emit "{\"type\":\"task\",\"id\":\"$action\",\"label\":$j_label,\"status\":$j_outcome,\"detail\":$j_detail}"
}

pristine_optimize_emit_summary() {
    local counts="" outcome
    for outcome in "${MOLE_OPTIMIZE_OUTCOME_VALUES[@]}"; do
        [[ -n "$counts" ]] && counts+=","
        counts+="\"$outcome\":$(optimize_outcome_count "$outcome")"
    done
    local dry_run=false
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && dry_run=true
    pristine_json_emit "{\"type\":\"summary\",\"dry_run\":$dry_run,\"outcomes\":{$counts},\"cache_cleaned_kb\":$(pristine_json_int "${OPTIMIZE_CACHE_CLEANED_KB:-0}"),\"databases_optimized\":$(pristine_json_int "${OPTIMIZE_DATABASES_COUNT:-0}"),\"configs_repaired\":$(pristine_json_int "${OPTIMIZE_CONFIGS_REPAIRED:-0}")}"
}
