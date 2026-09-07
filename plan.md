# General Ubuntu Software Manager

Build a small local CLI for installing, updating, and removing Ubuntu software.
Target Ubuntu 24.04 and newer on amd64 and arm64, subject to each module's limits.
Keep the existing minimal/workstation profiles and all 39 registered components.

## Keep it small

- Go core; JSON module configs parsed with the standard library.
- Start with plain CLI output and `--json`. Add a terminal dashboard later.
- Delegate package resolution to APT/Snap and installation to reviewed vendor adapters.
- One executable, one module directory, JSON receipts, and an operation log.
- No daemon, web server, database, plugin marketplace, or custom dependency solver.
- Bash remains the bootstrap and temporary compatibility entry point.

## User commands (planned)

```sh
usm list
usm status [module...]
usm install git codex
usm install --profile workstation --dry-run
usm update codex
usm update --all
usm remove codex --dry-run
usm remove codex
```

Support `--category`, `--yes`, `--dry-run`, and `--json` consistently.
`update` and `remove` require explicit IDs or `--all`; `--all` means managed modules.
`install` skips an already satisfied installation; `update` skips missing modules;
`remove` skips absent modules and preserves user data. Do not silently adopt or
switch the provider of software already installed outside this manager.

## One pipeline

1. **Load:** validate module configs, selection, Ubuntu release, and architecture.
2. **Inspect:** query backend package identity/version and read ownership receipts.
   Command probes are hints, never proof of ownership. Reconcile stale receipts.
3. **Plan:** resolve module prerequisites, selected backend, and concrete actions.
   Install dependencies first; remove selected dependents first. Block removal
   needed by a retained managed module. Let APT resolve Debian dependencies.
4. **Apply:** show the plan, confirm unless `--yes`, execute using argument arrays,
   and serialize mutations. Elevate only system actions. Respect backend locks.
5. **Verify:** inspect the resulting state, atomically write receipts, and report
   per-module success/failure. Continue independent work; block failed dependents.

Dry run does not install, refresh caches, write receipts, or run vendor scripts.
It may read local package metadata; report unresolved downloads/versions honestly.
Before applying, resolve and validate downloads. Never claim cross-backend rollback.

## Module contract

`modules/*.json` is the future runner's catalog. See [modules/README.md](modules/README.md).
Most new software should require one config file. Use a named, compiled adapter
only when normal APT, DEB, vendor, or symlink handling is insufficient.
Adapters expose inspect/install/update/remove and capability information.

Preserve the installed backend/channel in the receipt. Ghostty's release-based
default chooses a provider only for a new installation. Updates do not migrate it.
APT package names and exact DEB metadata drive removal, not executable names.
Treat backend-native versions as opaque outside the backend; do not assume semver.

## Software version control

Make upgrades deliberate and software selections reproducible with exact versions,
per-module pins, and a Git-friendly JSON lock file. Keep this within the existing
planner and backend adapters; do not introduce a separate version solver.

```sh
usm versions pixi
usm install pixi --version <exact-version>
usm pin pixi
usm unpin pixi
usm lock --output usm.lock.json
usm sync --lock usm.lock.json --dry-run
usm sync --lock usm.lock.json
```

- **Discover and select:** `versions` lists versions available from the selected
  backend, or explains why enumeration is unsupported. `--version` accepts one
  module and requests an exact backend-native version for install/update. Fail
  before mutation if unavailable or unsupported; never substitute `latest`.
- **Pin:** `pin` records a verified managed installation's current version as the
  desired version. Normal updates, including `update --all`, skip pinned modules
  and explain why. Conflicting explicit version requests require `unpin` first.
  Pins govern USM operations only; report drift caused by external package tools
  or self-updaters, and expose whether a backend can enforce a native hold.
- **Lock:** export verified managed installations in stable module-ID order with
  a schema version, Ubuntu release/architecture, manifest digest, backend/channel,
  exact package versions, pin policy, and artifact checksums where available.
  Exclude credentials, machine-specific paths, and timestamps that create noisy
  diffs. The file is safe to review and commit to Git; receipts remain local
  ownership records. Mark entries that cannot be reproduced exactly.
- **Sync:** validate every selected lock entry and resolve exact artifacts before
  applying through the normal pipeline. Reject incompatible targets, changed
  manifests, unsupported exact installs, and unavailable versions with actionable
  errors. Show version changes and require `--allow-downgrade` for downgrades.
  Sync does not remove extra modules, adopt external installs, switch providers,
  or override conflicting pins. An older lock file requests a normal sync, not
  transactional rollback; partial failures retain accurate receipts.

Adapters declare version listing, exact install, downgrade, and native-hold
capabilities. Compare versions through the backend. Lock files capture managed
software selections, not the entire OS dependency graph, and cannot guarantee
future upstream artifact availability. `status` shows installed versus pinned
versions and drift; version commands follow the same dry-run and JSON conventions.

## Minimal state and removal rules

Keep user receipts in `$XDG_STATE_HOME/usm` (default `~/.local/state/usm`) and
system receipts in root-owned `/var/lib/usm`. A receipt records module ID,
manifest digest, backend, scope, package IDs, version/channel, created paths,
checksums, managed shell edits, and operation outcome. Only elevated code writes
system receipts; it must not trust arbitrary deletion paths from user receipts.

- Record only files/packages introduced or explicitly adopted by the manager.
- Remove only recorded resources; refuse modified files or changed symlinks.
- Preserve projects, environments, credentials, caches, and unrelated dotfile text.
- No automatic `autoremove`, purge, repository deletion, or wildcard directory removal.
- For vendor installers, implement and verify ownership capture before enabling
  removal. If ownership is incomplete, report removal unsupported with a reason.
- Keep a receipt after partial failure so the next run can inspect and recover.

## Implementation order

- [ ] **1. Core:** config loader, validation, list/status, plan output, JSON receipts,
  injectable command runner, and APT install/update/remove. Start with Git.
- [ ] **2. Ordinary modules:** migrate all APT packages, DEBs, fd/bat links, and
  managed Zsh config. Validate DEB package name/architecture before installation.
- [ ] **3. Special modules:** Snap route for Ghostty; vendor adapters for Codex,
  Pixi, uv, Zed, Starship, zoxide; eza/yq alternatives; Feishu/ToDesk/VS Code.
  Include Sogou Pinyin with its Fcitx 4/Qt runtime and user input-method setup.
  Preserve `SOGOU_DEB`, `TODESK_DEB`, `GHOSTTY_METHOD`, and `PIXI_VERSION` behavior
  where relevant. Record the previous input-method selection for removal.
- [ ] **4. Version control:** add version capability reporting, exact selection,
  pins/drift reporting, deterministic lock export, and lock-based sync. Start with
  APT and one version-capable vendor adapter; report other adapters' limitations.
- [ ] **5. Finish migration:** verify all 39 modules' full lifecycle, then make
  `setup` delegate to Go. Until then, retain the current Bash runner.
- [ ] **Later, only if needed:** Flatpak backend, interactive TUI, profile export.

For each milestone: unit-test planning/failure handling with fake backends, then
exercise install → repeat install → update → remove in disposable Ubuntu VMs.
Cover 24.04 and 26.04, architecture restrictions, missing packages, external installs,
modified owned files, and interrupted operations. Use containers for quick APT
checks; use VMs for Snap/system services. Add newer releases after validation.
Version-control checks cover pinned bulk updates, external drift, unavailable
versions, incompatible locks, deterministic exports, downgrade consent, and
partial sync failures without silently falling back to newer versions.

## What is delivered now

The dependency-free Go runner now implements catalog validation, list/status,
selection and dependency plans, APT install/update/remove, atomic system receipts,
serialized mutations, download preflight, and an operation log. The same pipeline
also implements APT version enumeration, exact versions, pins/drift, deterministic
lock export, and lock sync. Fake-backend tests cover lifecycle, ownership, dependency
failures, interrupted receipts, pin policy, and version/lock validation.

Milestone 1 implementation is present. The Git lifecycle test passed in disposable
Ubuntu 24.04 and 26.04 amd64 containers, including repeat install, update, pin/lock
sync, removal, and preservation of an external installation. Go unit/race tests,
`go vet`, all 67 Bash checks, catalog validation, and an ARM64 cross-build passed.
Supported-target VM and native ARM64 validation are still required before marking
the milestone complete. Ordinary APT configs also run
through this backend. Remaining ordinary/special adapters and vendor version
control are not implemented in Go; those modules report unsupported. The existing
Bash runner remains active, and its removal behavior is unchanged. See README.md
for build commands and the disposable APT lifecycle test.

All 39 configs retain current package mappings, installer URLs, fallbacks, profiles,
and restrictions. Vendor paths/removal behavior must be verified during adapter
implementation. Run `python3 scripts/validate_modules.py` to check catalog structure
and legacy ID coverage.
