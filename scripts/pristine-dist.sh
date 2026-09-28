#!/bin/bash
# Pristine fork: build the self-contained CLI bundle that a Mac app
# ships inside its .app. Fork-only file; see CHANGES-FORK.md.
#
# Output (under --out, default ./dist):
#   pristine-cli/                  runnable tree: pristine, mole, mo, bin/, lib/
#     bin/analyze-go, status-go    universal (arm64 + x86_64) Go binaries
#     LICENSE, CHANGES-FORK.md     GPL-3.0 text and modification notice
#     BUILD-INFO                   version, commit, and source URL
#   pristine-cli-vX.Y.Z.tar.gz     the same tree, archived (untagged builds use
#   pristine-cli-vX.Y.Z.tar.gz.sha256  a commit-based name instead)
#
# The app bundles this tree as a separate program and runs it as a
# subprocess; nothing here is linked into the app.
#
# Usage: scripts/pristine-dist.sh [--out DIR] [--release]
#   --release  refuse to build unless HEAD is an exact tag with a clean tree,
#              so the shipped bundle always matches public corresponding source

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/dist"
RELEASE=false
SOURCE_URL="${PRISTINE_SOURCE_URL:-https://github.com/yashspr/cleaner-cli}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            [[ $# -ge 2 ]] || {
                echo "--out requires a directory" >&2
                exit 1
            }
            OUT_DIR="$2"
            shift
            ;;
        --release)
            RELEASE=true
            ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

cd "$PROJECT_ROOT"

for tool in go lipo git tar shasum; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

commit=$(git rev-parse HEAD)
# Only fork release tags (pristine-vX.Y.Z) name a bundle; upstream's V1.x
# tags describe Mole, not this fork.
ref=$(git describe --tags --match 'pristine-v*' --always --dirty)
if [[ "$RELEASE" == "true" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "--release needs a clean working tree (GPL: ship only published source)" >&2
        exit 1
    fi
    if ! ref=$(git describe --tags --match 'pristine-v*' --exact-match 2> /dev/null); then
        echo "--release needs HEAD to carry a pristine-vX.Y.Z tag; tag it and push the tag first" >&2
        exit 1
    fi
fi
upstream_version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' mole | head -1)

# Build with the toolchain go.mod names, as upstream's release workflow does
# (setup-go go-version-file). A newer local Go can raise the Mach-O minimum
# macOS above what Mole supports; check_release_minos.sh below enforces it.
if [[ -z "${GOTOOLCHAIN:-}" ]]; then
    GOTOOLCHAIN="go$(sed -n 's/^go \([0-9.]*\)$/\1/p' go.mod | head -1)"
    export GOTOOLCHAIN
fi

echo "Building Go binaries (arm64, amd64) with $GOTOOLCHAIN..."
make release-arm64 release-amd64 > /dev/null

stage="$OUT_DIR/pristine-cli"
if [[ -e "$stage" ]]; then
    rm -rf "$stage" # SAFE: build output directory recreated by this script
fi
mkdir -p "$stage/bin"

for name in analyze status; do
    lipo -create -output "$stage/bin/${name}-go" \
        "bin/${name}-darwin-arm64" "bin/${name}-darwin-amd64"
done
"$SCRIPT_DIR/check_release_minos.sh" "$stage/bin/analyze-go" "$stage/bin/status-go"

cp pristine mole mo LICENSE CHANGES-FORK.md "$stage/"
cp bin/*.sh "$stage/bin/"
cp -R lib "$stage/lib"
find "$stage" -name '.DS_Store' -type f -delete # SAFE: Finder debris inside the freshly staged build tree
chmod +x "$stage/pristine" "$stage/mole" "$stage/mo" "$stage"/bin/*.sh "$stage"/bin/*-go

cat > "$stage/BUILD-INFO" << EOF
name=pristine-cli
ref=$ref
commit=$commit
upstream=tw93/mole $upstream_version
source=$SOURCE_URL/tree/$commit
license=GPL-3.0
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Smoke test the staged tree, not the source checkout.
# Capture first: grep -q exits early, and under pipefail the writer's SIGPIPE
# would read as a failure.
smoke_json=$(MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 "$stage/pristine" clean --json --dry-run 2> /dev/null) || true
[[ "$smoke_json" == *'"type":"summary"'* ]] || {
    echo "Smoke test failed: staged clean --json produced no summary" >&2
    exit 1
}
"$stage/bin/status-go" --json > /dev/null || {
    echo "Smoke test failed: staged status-go --json" >&2
    exit 1
}

archive="$OUT_DIR/pristine-cli-${ref#pristine-}.tar.gz"
tar -C "$OUT_DIR" -czf "$archive" pristine-cli
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")

echo "Built $stage"
echo "Archive $archive"
cat "$stage/BUILD-INFO"
