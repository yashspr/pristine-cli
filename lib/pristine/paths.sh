#!/bin/bash
# Pristine fork: relocatable data directories.
# Fork-only file; see CHANGES-FORK.md.
#
# Upstream keeps its state in ~/.config/mole, ~/.cache/mole and
# ~/Library/Logs/mole. A program that embeds this CLI can move each one, so
# nothing is written to (or read from) those folders:
#   PRISTINE_CONFIG_DIR     whitelists, purge_paths, clean-list.txt, status prefs
#   PRISTINE_CACHE_DIR      scan and analyze caches, fallback temp directory
#   PRISTINE_LOG_DIR        mole.log, operations.log, deletions.log (history)
#   PRISTINE_PROTECT_PATHS  colon-separated folders cleanup must never touch
# Each path must be absolute; an invalid value is ignored with a warning and
# the upstream default applies. Unset, behaviour is exactly upstream's.
#
# The three data directories and the protected folders, with everything in
# them, are never removed by cleanup (upstream protects ~/Library/Logs/mole the
# same way). A data directory inside a folder that cleanup sweeps, such as
# ~/Library/Logs/<app>/engine, needs its parent listed in
# PRISTINE_PROTECT_PATHS as well.

if [[ -n "${PRISTINE_PATHS_LOADED:-}" ]]; then
    return 0
fi
readonly PRISTINE_PATHS_LOADED=1

_pristine_valid_dir() {
    local value="$1"
    [[ "$value" == /* && "$value" != "/" && ! "$value" =~ [[:cntrl:]] ]] || return 1
    case "$value" in
        *'/../'* | */.. | *'/./'* | */.) return 1 ;;
    esac
    return 0
}

PRISTINE_PROTECTED_ROOTS=()

_pristine_init_paths() {
    local name value
    for name in PRISTINE_CONFIG_DIR PRISTINE_CACHE_DIR PRISTINE_LOG_DIR; do
        value="${!name:-}"
        [[ -n "$value" ]] || continue
        if _pristine_valid_dir "$value"; then
            [[ "$value" == */ ]] && export "$name=${value%/}"
            PRISTINE_PROTECTED_ROOTS+=("${value%/}")
        else
            echo "Ignoring $name: not an absolute path" >&2
            unset "$name"
        fi
    done

    [[ -n "${PRISTINE_PROTECT_PATHS:-}" ]] || return 0
    local -a extra=()
    IFS=: read -r -a extra <<< "$PRISTINE_PROTECT_PATHS"
    for value in ${extra[@]+"${extra[@]}"}; do
        [[ -n "$value" ]] || continue
        if _pristine_valid_dir "$value"; then
            PRISTINE_PROTECTED_ROOTS+=("${value%/}")
        else
            echo "Ignoring protected path: $value" >&2
        fi
    done
}
_pristine_init_paths

# pristine_path_protected PATH → 0 when PATH is a data directory or protected
# folder, or inside one. Called from should_protect_path.
pristine_path_protected() {
    local path="${1%/}" root
    [[ -n "$path" && ${#PRISTINE_PROTECTED_ROOTS[@]} -gt 0 ]] || return 1
    for root in "${PRISTINE_PROTECTED_ROOTS[@]}"; do
        [[ "$path" == "$root" || "$path" == "$root"/* ]] && return 0
    done
    return 1
}
