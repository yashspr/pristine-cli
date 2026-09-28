#!/usr/bin/env bats
# Pristine fork: clean --json / --exclude-from / --admin. See CHANGES-FORK.md.

load helpers/common

bats_require_minimum_version 1.5.0

setup_file() {
    mole_test_setup_home pristine-clean-json
    MOLE_LSREGISTER_PATH=""
    export MOLE_LSREGISTER_PATH
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
    rm -rf "$HOME/Library" "$HOME/.config"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
}

# Same seams as tests/clean_core.bats: no real brew/xcrun/lsof/ps/sudo.
make_mock_bin() {
    MOCK_BIN="$HOME/mock-bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/xcrun"
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/sudo"
    cat > "$MOCK_BIN/lsof" << 'MOCK'
#!/bin/bash
case " $* " in
    *" -p 1 "*) printf 'p1\nu0\n'; exit 0 ;;
    *) exit 1 ;;
esac
MOCK
    printf '#!/bin/bash\nprintf "  PID  PPID COMM ARGS\\n"\n' > "$MOCK_BIN/ps"
    chmod +x "$MOCK_BIN"/*
}

# Every stdout line must be one JSON object; human output belongs on stderr.
assert_ndjson_only() {
    local line
    [[ -n "$1" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "{\"type\":\""*"}" ]] || {
            printf 'non-JSON stdout line: %s\n' "$line" >&2
            return 1
        }
    done <<< "$1"
}

@test "clean --json keeps stdout to NDJSON events and ends with summary and end" {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/pristine" clean --json --dry-run

    [ "$status" -eq 0 ] || return 1
    assert_ndjson_only "$output" || return 1
    [[ "${lines[0]}" == '{"type":"start","schema_version":1,"command":"clean","dry_run":true,'* ]] || return 1
    [[ "$output" == *'"type":"summary","dry_run":true,"status":"complete","exit_code":0'* ]] || return 1
    [[ "${lines[${#lines[@]} - 1]}" == '{"type":"end","exit_code":0}' ]] || return 1
    [[ "$stderr" == *"Dry Run Mode"* ]] || return 1
}

@test "clean --json dry-run lists items and --exclude-from drops the excluded one" {
    local keep="$HOME/Library/Caches/com.example.keepme"
    local drop="$HOME/Library/Caches/com.example.dropme"
    mkdir -p "$keep" "$drop"
    dd if=/dev/zero of="$keep/a.bin" bs=1024 count=64 2> /dev/null
    dd if=/dev/zero of="$drop/b.bin" bs=1024 count=64 2> /dev/null
    printf '# comment\n\n%s\n' "$keep" > "$HOME/exclude.txt"
    make_mock_bin

    run --separate-stderr env HOME="$HOME" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 \
        PATH="$MOCK_BIN:$PATH" "$PROJECT_ROOT/mole" clean --dry-run --json --exclude-from "$HOME/exclude.txt"

    [ "$status" -eq 0 ] || return 1
    assert_ndjson_only "$output" || return 1
    [[ "${lines[0]}" == *'"excluded_paths":1}' ]] || return 1
    [[ "$output" == *"{\"type\":\"item\",\"path\":\"$drop\",\"section\":\"User essentials\",\"size_kb\":"* ]] || return 1
    [[ "$output" != *"{\"type\":\"item\",\"path\":\"$keep\""* ]] || return 1
    [[ "$output" == *"{\"type\":\"operation\",\"action\":\"SKIPPED\",\"path\":\"$keep\",\"detail\":\"whitelist\""* ]] || return 1
    [[ "$output" == *'{"type":"section","name":"User essentials"}'* ]] || return 1
    # Preview is read-only.
    [[ -f "$keep/a.bin" && -f "$drop/b.bin" ]] || return 1
}

@test "--exclude-from protects a path through the real removal guard" {
    local base="$HOME/Library/Caches/pristine-exclude"
    mkdir -p "$base/gone" "$base/kept"
    printf 'x' > "$base/gone/f"
    printf 'x' > "$base/kept/f"
    printf '%s\n' "$base/kept" > "$HOME/exclude.txt"

    # --json points stdin at /dev/null, so the script must come from a file,
    # not a heredoc on stdin.
    cat > "$HOME/run.sh" << EOF
set -euo pipefail
source "\$PROJECT_ROOT/bin/clean.sh"
pristine_clean_main_hook --json --exclude-from "$HOME/exclude.txt"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
CURRENT_SECTION="Test"
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
safe_clean "$base/gone" "$base/kept" "Test cache"
EOF
    run --separate-stderr env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc "$HOME/run.sh"

    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$base/gone" ]] || return 1
    [[ -f "$base/kept/f" ]] || return 1
    [[ "$output" == *"{\"type\":\"operation\",\"action\":\"REMOVED\",\"path\":\"$base/gone\""*'"section":"Test"}'* ]] || return 1
    [[ "$output" != *"\"action\":\"REMOVED\",\"path\":\"$base/kept\""* ]] || return 1
}

@test "clean refuses to run when the exclude file is unreadable or invalid" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" clean --json --exclude-from "$HOME/missing.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"Cannot read path list"* ]] || return 1

    printf 'relative/path\n' > "$HOME/exclude.txt"
    run env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" clean --exclude-from "$HOME/exclude.txt"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"Path must be absolute"* ]] || return 1
}

@test "pristine_json_quote escapes quotes, backslashes and control bytes" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/pristine/json.sh"
pristine_json_quote $'a"b\\c\nd\te\x01f/ü'
printf '%s\n' "$PRISTINE_JQ"
EOF
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == '"a\"b\\c\nd\te\u0001f/ü"' ]] || return 1
}

@test "clean --admin never prompts under MOLE_TEST_NO_AUTH" {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" clean --json --admin --dry-run
    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == *'"system_clean":false,'* ]] || return 1
    [[ "$stderr" == *"Admin access not granted"* ]] || return 1
}
