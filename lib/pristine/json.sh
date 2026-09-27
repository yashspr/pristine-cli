#!/bin/bash
# Pristine fork: machine-readable event stream helpers.
#
# Fork-only file (not in upstream Mole). All JSON logic lives under
# lib/pristine/ so upstream merges only ever meet a handful of hook lines in
# shared files. See CHANGES-FORK.md for the hook inventory and event schema.
#
# Model: when a command runs with --json, the original stdout is kept on
# PRISTINE_JSON_FD and fd 1 is pointed at stderr. Every existing echo/printf in
# Mole keeps working unchanged (it lands on stderr as a human log), and stdout
# carries only NDJSON events, one object per line.

if [[ -n "${PRISTINE_JSON_LOADED:-}" ]]; then
    return 0
fi
readonly PRISTINE_JSON_LOADED=1

readonly PRISTINE_JSON_SCHEMA_VERSION=1
# Fixed descriptor: bash 3.2 has no {var}> allocation. Mole itself opens no
# numbered descriptors, so 8 is free.
readonly PRISTINE_JSON_EVENT_FD=8

PRISTINE_JSON_FD=""
# Output slot for pristine_json_quote, so hot loops avoid a subshell per value.
PRISTINE_JQ=""

pristine_json_enabled() {
    [[ -n "${PRISTINE_JSON_FD:-}" ]]
}

# Move stdout to the event descriptor and send fd 1 to stderr.
pristine_json_begin() {
    pristine_json_enabled && return 0
    # stdin from /dev/null: a JSON run never waits on a keypress. Admin
    # prompts still work; lib/core/sudo.sh falls back to a native dialog
    # when there is no terminal.
    exec 8>&1 1>&2 0< /dev/null
    PRISTINE_JSON_FD="$PRISTINE_JSON_EVENT_FD"
}

# Quote a string as a JSON string literal into PRISTINE_JQ.
# Bash 3.2 mangles backslashes written inline in ${var//pat/rep}, so both the
# pattern and the replacement are held in variables.
pristine_json_quote() {
    local s="$1"
    # shellcheck disable=SC1003  # Literal backslashes, not quote escapes.
    local bs='\' bsbs='\\' q='"' bsq='\"'
    local nl=$'\n' cr=$'\r' tab=$'\t'
    local esc_nl='\n' esc_cr='\r' esc_tab='\t'

    s="${s//"$bs"/$bsbs}"
    s="${s//"$q"/$bsq}"
    s="${s//"$nl"/$esc_nl}"
    s="${s//"$cr"/$esc_cr}"
    s="${s//"$tab"/$esc_tab}"

    # Remaining control bytes are rare in paths; encode them one by one.
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        local out="" ch code i
        for ((i = 0; i < ${#s}; i++)); do
            ch="${s:i:1}"
            if [[ "$ch" == [[:cntrl:]] ]]; then
                printf -v code '\\u%04x' "'$ch"
                out+="$code"
            else
                out+="$ch"
            fi
        done
        s="$out"
    fi

    PRISTINE_JQ="\"$s\""
}

# Echo-style variant for non-hot paths.
pristine_json_str() {
    pristine_json_quote "$1"
    printf '%s' "$PRISTINE_JQ"
}

pristine_json_bool() {
    if [[ "${1:-}" == "true" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# Non-negative integer or null.
pristine_json_int() {
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

# Write one pre-built JSON object as an NDJSON line.
pristine_json_emit() {
    pristine_json_enabled || return 0
    printf '%s\n' "$1" >&8
}

# Rename an existing function to _pristine_orig_<name> so a fork wrapper can
# take its name and call through. Lets the fork observe upstream functions
# without editing their bodies.
pristine_wrap_function() {
    local name="$1"
    local body
    body=$(declare -f "$name") || return 1
    eval "_pristine_orig_${name}${body#"$name"}"
}
