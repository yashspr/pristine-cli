#!/usr/bin/env bats
# Pristine fork: installer --json / --exclude-from / --only-from.
# The scan also covers /Users/Shared, so real (non-dry) runs in these tests
# always use --only-from with fixture paths: nothing outside HOME is selected.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-installer-json
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/Downloads"
    dd if=/dev/zero of="$HOME/Downloads/Tool.dmg" bs=1024 count=8 2> /dev/null
    dd if=/dev/zero of="$HOME/Downloads/Setup.pkg" bs=1024 count=4 2> /dev/null
}

@test "installer --json --dry-run lists candidates and honours --exclude-from" {
    printf '%s\n' "$HOME/Downloads/Setup.pkg" > "$HOME/exclude.txt"

    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/pristine" installer --json --dry-run --exclude-from "$HOME/exclude.txt"

    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == '{"type":"start","schema_version":1,"command":"installer","dry_run":true,"excluded_paths":1,"only_paths":0}' ]] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/Downloads/Tool.dmg\",\"kind\":\"dmg\","*'"size_bytes":8192,"size_kb":8,"selected":true}'* ]] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$HOME/Downloads/Setup.pkg\",\"kind\":\"pkg\","*'"selected":false}'* ]] || return 1
    [[ "$output" == *'"type":"summary","dry_run":true,"status":"complete"'* ]] || return 1
    [[ "${lines[${#lines[@]} - 1]}" == '{"type":"end","exit_code":0}' ]] || return 1
    [[ -f "$HOME/Downloads/Tool.dmg" && -f "$HOME/Downloads/Setup.pkg" ]] || return 1
}

@test "installer --json --only-from removes only the listed file" {
    printf '%s\n' "$HOME/Downloads/Tool.dmg" > "$HOME/only.txt"

    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/pristine" installer --json --only-from "$HOME/only.txt"

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$HOME/Downloads/Tool.dmg" ]] || return 1
    [[ -f "$HOME/Downloads/Setup.pkg" ]] || return 1
    [[ "$output" == *'"type":"summary","dry_run":false,"status":"complete","exit_code":0,'*'"selected":1,"removed":1,"size_kb":8,"failed":0'* ]] || return 1
}

@test "installer --json with nothing selected removes nothing" {
    printf '%s\n' "$HOME/Downloads/not-a-candidate.dmg" > "$HOME/only.txt"

    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/pristine" installer --json --only-from "$HOME/only.txt"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'"status":"nothing_selected"'* ]] || return 1
    [[ -f "$HOME/Downloads/Tool.dmg" && -f "$HOME/Downloads/Setup.pkg" ]] || return 1
}

@test "installer rejects selection files without --json and conflicting lists" {
    printf '%s\n' "$HOME/Downloads/Tool.dmg" > "$HOME/list.txt"

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" installer --only-from "$HOME/list.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"need --json"* ]] || return 1

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" installer --json \
        --only-from "$HOME/list.txt" --exclude-from "$HOME/list.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"not both"* ]] || return 1
    [[ -f "$HOME/Downloads/Tool.dmg" ]] || return 1
}
