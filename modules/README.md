# Module configs

One JSON file per component, including bootstrap prerequisites and managed shell
assets. The Go `usm` runner loads and validates all configs and currently implements
APT lifecycles. Other backends report unsupported until their reviewed adapters
are implemented. The current `setup` still reads `components/*.sh`.

JSON keeps the Go loader dependency-free. Configs contain data, not shell programs.
Until migration finishes, keep the JSON catalog and Bash registrations aligned.

| Field | Meaning |
| --- | --- |
| `schema_version` | Config format, currently `1` |
| `id`, `label`, `description` | Stable CLI identity and display text |
| `category`, `profiles`, `hidden` | Selection and display metadata |
| `platform` | Ubuntu minimum version and supported Debian architecture names |
| `depends_on` | Other module IDs; not the backend's dependency graph |
| `detect.commands` | Discovery hints; backend inventory/receipts establish ownership |
| `backend` | `apt`, `deb`, `vendor`, `symlink`, or named `adapter` |
| `spec` | Backend-specific data described below |
| `lifecycle` | Desired install/update semantics and removal policy |
| `legacy_source` | Migration reference only; never execute this field |

Backend data:

- `apt`: `packages` is the exact Debian package list.
- `deb`: `url` plus optional architecture mapping. Inspect the archive and record
  its actual package ID/version before calling APT; remove through APT.
- `vendor`: installer URL/interpreter/argument list and a named adapter. Optional
  `update_argv` selects a self-update command. The adapter must establish ownership
  and verify vendor-specific removal; no generic reverse-script operation exists.
- `symlink`: `target_command` and `link`; refuse to overwrite an unrelated file.
- `adapter`: `spec.adapter` selects reviewed code for the package. Remaining fields
  encode the existing source-selection, download, checksum, or shell-block behavior.

Templates such as `{arch}`, `{vendor_arch}`, `{version}`, `{platform}`, `{home}`,
and `{config_home}` are explicit substitutions by the matching backend, never
shell expansion. Reject unknown placeholders. Runtime paths must be resolved and
checked against the adapter's allowed installation locations.

`remove` policies refer to receipts: `recorded-packages`, `recorded-files`,
`recorded-backend`, or `managed-block-and-file`. They are requirements for the
future runner, not assertions that uninstall is already implemented.

Special cases retained from the repository:

- Chrome: amd64 only. Other modules declare amd64/arm64 as implementation targets.
- Ghostty: APT on 26.04+, Snap on older supported releases, community script opt-in.
- yq: existing APT choice and pinned, checksum-verified fallback. This preserves
  current behavior; the Ubuntu and upstream yq implementations may differ.
- eza: prefer the available eza package, otherwise exa; record the choice.
- ToDesk: accept `TODESK_DEB` when automatic download is blocked.
- Pixi/uv: existing self-update commands; preserve project environments on removal.
- Zsh config: preserve unrelated text and remove only the managed block/file.
- Sogou Pinyin replaces Fcitx 5: resolve the official amd64/arm64 DEB, install
  Fcitx 4/Qt runtimes, and select Fcitx for the user. Accept `SOGOU_DEB` for local
  downloads; preserve dictionaries and record/restore the previous input-method
  selection during removal. Desktop compatibility on 24.04+ needs VM validation.

Validate with `python3 scripts/validate_modules.py`. This checks config structure,
references, dependency cycles, and legacy ID coverage; it does not verify upstream
downloads or prove that installation/removal works.
