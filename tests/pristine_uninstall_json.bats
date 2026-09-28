#!/usr/bin/env bats
# Pristine fork: uninstall --json. Removal tests target only a fixture app in
# the test HOME (~/Applications), selected by its exact bundle id.

load helpers/common

bats_require_minimum_version 1.5.0

readonly FIXTURE_BUNDLE_ID="io.pristine.fixture.TestApp"

setup_file() {
    mole_test_setup_home pristine-uninstall-json
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/* "$HOME/Library" "$HOME/.config" "$HOME/.cache"
    APP="$HOME/Applications/PristineFixture.app"
    mkdir -p "$APP/Contents/MacOS" "$HOME/Library/Caches/$FIXTURE_BUNDLE_ID"
    cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$FIXTURE_BUNDLE_ID</string>
  <key>CFBundleName</key><string>PristineFixture</string>
  <key>CFBundleExecutable</key><string>PristineFixture</string>
</dict>
</plist>
PLIST
    printf '#!/bin/sh\n' > "$APP/Contents/MacOS/PristineFixture"
    chmod +x "$APP/Contents/MacOS/PristineFixture"
    printf 'cache' > "$HOME/Library/Caches/$FIXTURE_BUNDLE_ID/data"

    # Harmless doubles for the host tools the uninstall path consults; the
    # shared helpers otherwise make them fail loudly (exit 97).
    mole_test_fake_command mdfind 'exit 0'
    mole_test_fake_command osascript 'exit 0'
    mole_test_fake_command launchctl 'exit 0'
    mole_test_fake_command brew 'exit 0' # an empty Homebrew: no casks own the fixture
    mole_test_fake_command sudo 'exit 1'
}

run_uninstall() {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/pristine" uninstall "$@"
    # Surface the human log when an assertion below fails.
    printf '%s\n' "$stderr" | tail -15 >&2
}

@test "uninstall --json --list includes the fixture app" {
    run_uninstall --json --list
    [ "$status" -eq 0 ] || return 1
    [[ "${lines[0]}" == *'"command":"uninstall","mode":"list"'* ]] || return 1
    [[ "$output" == *"{\"type\":\"app\",\"path\":\"$APP\",\"name\":\"PristineFixture\",\"bundle_id\":\"$FIXTURE_BUNDLE_ID\""* ]] || return 1
    [[ "${lines[${#lines[@]} - 1]}" == '{"type":"end","exit_code":0}' ]] || return 1
}

@test "uninstall --json --dry-run emits a plan and changes nothing" {
    run_uninstall --json --dry-run "$FIXTURE_BUNDLE_ID"
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"{\"type\":\"plan\",\"name\":\"PristineFixture\",\"path\":\"$APP\",\"bundle_id\":\"$FIXTURE_BUNDLE_ID\""* ]] || return 1
    [[ "$output" == *"\"$HOME/Library/Caches/$FIXTURE_BUNDLE_ID\""* ]] || return 1
    [[ "$output" == *'"type":"summary","mode":"apps","dry_run":true,"removed":1,"failed":0'* ]] || return 1
    [[ -d "$APP" && -d "$HOME/Library/Caches/$FIXTURE_BUNDLE_ID" ]] || return 1
}

@test "uninstall --json --yes --permanent removes the app selected by path" {
    run_uninstall --json --yes --permanent "$APP"
    [ "$status" -eq 0 ] || return 1
    [[ ! -e "$APP" ]] || return 1
    [[ ! -e "$HOME/Library/Caches/$FIXTURE_BUNDLE_ID" ]] || return 1
    [[ "$output" == *'"type":"summary","mode":"apps","dry_run":false,"removed":1,"failed":0'* ]] || return 1
}

@test "uninstall --json refuses removal without --yes and selects nothing on an unknown app" {
    run_uninstall --json "$FIXTURE_BUNDLE_ID"
    [ "$status" -eq 1 ] || return 1
    [[ "$stderr" == *"only with --yes"* ]] || return 1

    run_uninstall --json --yes "$FIXTURE_BUNDLE_ID" "io.pristine.fixture.Missing"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *'{"type":"error","code":"unmatched","query":"io.pristine.fixture.Missing","matches":0}'* ]] || return 1
    [[ "$output" != *'"type":"plan"'* ]] || return 1
    [[ -d "$APP" ]] || return 1
}
