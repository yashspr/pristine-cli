# pristine-cli

The command-line engine behind **Pristine**, a Mac cleanup app. It cleans caches and logs,
uninstalls apps with their leftovers, analyzes disk usage, removes project build artifacts and
old installers, runs maintenance tasks, and reports live system status.

> **Fork notice (GPL-3.0 §5a).** pristine-cli is a modified version of
> [Mole](https://github.com/tw93/mole) by tw93, licensed under GPL-3.0. It is **not** affiliated
> with or endorsed by Mole or its author. What changed, and when, is listed in
> [CHANGES-FORK.md](CHANGES-FORK.md). Almost all of the cleanup logic and its safety rules come
> from Mole.

## What the fork adds

The fork adds machine-readable, non-interactive modes so that a GUI can drive the engine as a
separate program:

- `pristine clean [--dry-run] --json [--exclude-from FILE] [--admin]` streams NDJSON events:
  the preview items with their sizes, per-path results, and a summary.
- A `pristine` entrypoint, and `scripts/pristine-dist.sh`, which builds a self-contained bundle
  with universal arm64 + x86_64 Go binaries.

The flags and the event schema are documented in [CHANGES-FORK.md](CHANGES-FORK.md).

## Usage

Requires macOS 12 or newer, on Intel or Apple Silicon.

```bash
git clone https://github.com/yashspr/pristine-cli.git && cd pristine-cli
make build                                   # builds bin/analyze-go and bin/status-go for this Mac
./pristine clean --dry-run                   # preview; nothing is deleted
./pristine clean --dry-run --json 2>/dev/null | head
./pristine status --json
./pristine analyze --json ~/Downloads
./pristine --help
```

`mo` and `mole` are kept as entrypoints too, so upstream changes merge cleanly. All three run the
same commands. Run as your normal user, never with `sudo`: the tool asks for admin access itself
when a task needs it.

Configuration and logs still use Mole's paths: `~/.config/mole/` (whitelist, purge paths,
preview list) and `~/Library/Logs/mole/operations.log`.

## Bundling

```bash
./scripts/pristine-dist.sh            # dev build: dist/pristine-cli-<commit>.tar.gz
./scripts/pristine-dist.sh --release  # needs a clean tree at a pristine-vX.Y.Z tag
```

Releases are tagged `pristine-vX.Y.Z`. Mole's own `V1.x` tags are kept in the repo and still
refer to Mole's releases.

## Development

Contributor rules, especially the deletion-safety rules, are in [AGENTS.md](AGENTS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md). They come from Mole and apply here unchanged.

```bash
./scripts/check.sh --format
MOLE_TEST_NO_AUTH=1 ./scripts/test.sh
MOLE_TEST_NO_AUTH=1 bats tests/pristine_*.bats
```

## License

GPL-3.0. See [LICENSE](LICENSE). Copyright for the original code belongs to Mole's authors.
Fork changes are also GPL-3.0. "Mole" is a trademark of the Mole project (see
[TRADEMARK.md](TRADEMARK.md)). This fork does not use the Mole name or logo for its own branding.
