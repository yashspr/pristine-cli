# Pristine fork of Mole

This repository is a **modified version** of [Mole](https://github.com/tw93/mole) by tw93,
licensed under GPL-3.0 (see [LICENSE](LICENSE)). It is the command-line engine bundled inside
the Pristine Mac app. Pristine is not affiliated with or endorsed by Mole or its author.

Upstream base: `tw93/mole` v1.56.0 (`50790e8a`, 2026-09-27).

## Modifications

| Date | Change |
|---|---|
| 2026-09-27 | `clean --json`, `--exclude-from FILE`, `--admin` (machine-readable clean for the GUI) |
| 2026-09-27 | `pristine` entrypoint; `scripts/pristine-dist.sh` bundle builder |

## Releases

Fork releases are annotated tags `pristine-vX.Y.Z` (upstream's `V1.x` tags stay untouched and
keep describing Mole). The Pristine app bundles only tagged builds:
`scripts/pristine-dist.sh --release` refuses a dirty tree or an untagged commit, and each tag
must be pushed so its corresponding source is public (GPL-3.0 §6).

| Tag | Upstream base | Notes |
|---|---|---|
| `pristine-v0.1.0` | tw93/mole v1.56.0 (`50790e8a`) | `clean --json`, `--exclude-from`, `--admin`; `pristine` entrypoint; dist script |

Cutting a release:

```bash
git tag -a pristine-vX.Y.Z -m "pristine-vX.Y.Z: <summary> (upstream vA.B.C)"
./scripts/pristine-dist.sh --release   # → dist/pristine-cli-vX.Y.Z.tar.gz
git push origin pristine-vX.Y.Z
```

Versioning: minor for new machine interfaces or upstream merges, patch for fixes, major if the
JSON `schema_version` changes.

## Keeping upstream merges cheap

Rule: **fork logic lives in fork-only files; shared files only get hook lines.**

- Fork-only files (upstream never touches them, so they never conflict):
  `lib/pristine/*`, `pristine`, `scripts/pristine-dist.sh`, `tests/pristine_*.bats`,
  `CHANGES-FORK.md`.
- Behaviour is added by **wrapping upstream functions at runtime**
  (`pristine_wrap_function` in `lib/pristine/json.sh`): the upstream function is renamed to
  `_pristine_orig_<name>` and a fork wrapper takes its name. Upstream can rewrite those function
  bodies freely; a merge only breaks if a wrapped function is **renamed or removed**, and the
  fork tests catch that.
- Every edited line in a shared file ends with `# pristine-fork`, so
  `git grep -n 'pristine-fork'` is the complete list of hook points.

### Hook inventory

| Shared file | Lines | Purpose |
|---|---|---|
| `bin/clean.sh` | `source .../lib/pristine/clean.sh` | load fork code |
| `bin/clean.sh` | 2 lines at top of `main()` | strip fork flags, install wrappers |
| `.gitignore` | `/dist/` | ignore bundle output |

Upstream functions wrapped at runtime (must keep these names): `start_cleanup`,
`perform_cleanup`, `start_section`, `log_operation`, `cleanup`, `show_clean_help`. Also read:
`emit_deduplicated_dry_run_ledger`, `CLEAN_PREVIEW_LEDGER_FILE`, `WHITELIST_PATTERNS`,
`DRY_RUN`, `SYSTEM_CLEAN`, `total_size_cleaned`, `files_cleaned`, `total_items`,
`DRY_RUN_TOTAL_PARTIAL`, `MOLE_CLEAN_SIZING_TIMEOUTS`, `ensure_sudo_session`.

### Merging upstream

```bash
git fetch upstream
git merge upstream/main          # merge, not rebase: keeps fork history and tags intact
git grep -n 'pristine-fork'      # hook lines still in place?
MOLE_TEST_NO_AUTH=1 bats tests/pristine_*.bats
./scripts/check.sh --no-format
```

Then update "Upstream base" above.

## `clean` machine interface

```
pristine clean [--dry-run] --json [--exclude-from FILE] [--admin]
```

- `--json`: stdout carries **only** NDJSON events (one object per line); all human output moves
  to stderr. stdin is detached, so the run never waits for a keypress.
- `--exclude-from FILE`: newline-separated absolute paths (`~/` allowed, `#` comments) protected
  for this run only. They join Mole's whitelist in memory, so the same guards that honour
  `~/.config/mole/whitelist` in preview and in real removal honour them. As with the whitelist,
  excluding a path also keeps its parent directories. An unreadable or invalid file aborts the
  run with exit 1 before anything is scanned.
- `--admin`: ask for admin rights so system caches are included. With no terminal, Mole shows a
  native macOS password dialog. Without it, a non-interactive run only uses an already-cached
  sudo session.

Selection model: preview with `--dry-run --json`, let the user deselect items, then run
without `--dry-run`, passing the deselected paths via `--exclude-from`. The real run rescans;
anything not excluded that Mole would clean is cleaned.

### Events (`schema_version` 1)

| `type` | Fields |
|---|---|
| `start` | `schema_version`, `command`, `dry_run`, `system_clean`, `external_volume` (string or null), `excluded_paths` |
| `section` | `name` |
| `operation` | `action` (`REMOVED` / `SKIPPED` / `FAILED` / …), `path`, `detail` (human size or reason), `section` |
| `item` | dry run only: `path`, `section`, `size_kb` (int or null), `size_known`, `item_count`, `covered_by` (string or null) |
| `summary` | `dry_run`, `status` (`complete` / `cancelled` / `interrupted` / `incomplete`), `exit_code`, `size_kb`, `size_partial`, `items`, `categories`, `system_clean`, `permission_denied`, `removal_timeouts`, `free_space_kb`, `preview_file` |
| `end` | `exit_code`, `signal` — always the last line, also on early exit or interrupt |

Notes:
- `item` rows with `covered_by` sit inside another listed row. Show them (they can be excluded
  on their own), but don't add their size to a total; `summary.size_kb` already excludes them.
- Sizes are KiB. Mole's human output formats them with decimal units (1 GB = 10⁹ bytes).
- `--external` dry runs emit no `item` rows yet (upstream writes that preview as text only).
- New fields may be added within a schema version; consumers must ignore unknown fields and
  unknown `type`s. A breaking change bumps `schema_version`.
