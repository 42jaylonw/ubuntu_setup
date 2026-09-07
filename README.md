# Ubuntu AI Developer Workstation

Set up an Ubuntu development machine with Zsh, Ghostty, editors, CLI tools,
C/C++ build tools, and Python/AI tooling.

## Quickstart

Run from this repository on Ubuntu 22.04+ (`amd64` or `arm64`; some apps have
architecture restrictions):

```sh
./setup                                        # interactive menu
./setup install --profile workstation --dry-run # preview
./setup install --profile workstation --yes     # install
./setup status
```

Choose `minimal` for Zsh, Git, and basic utilities, or `workstation` for the full
stack. GPU drivers, CUDA, containers, and local AI models are not included.

To install or update individual tools:

```sh
./setup list
./setup install git zsh-config --yes
./setup update --category ai --dry-run
./setup update --category ai --yes
```

Open a new terminal after shell changes; log out and back in if your login shell
or input method changed.

## Core ideas

- **Choose what you need.** Select components by ID, profile, or category.
- **Rerun when needed.** `install` skips installed tools and refreshes stale managed
  config. `update` refreshes selected installed tools; missing prerequisites may
  be installed. Use the original package manager for tools installed elsewhere.
- **Preview changes.** `--dry-run` shows the plan without changing the machine.
- **Keep personal settings.** A managed block in `~/.zshrc` loads
  `~/.config/ubuntu-setup/zshrc`; unrelated settings are preserved.
- **Shell features belong to Zsh.** Autosuggestions and syntax highlighting are
  included in both profiles. Ghostty is the terminal and Starship is the prompt;
  both work with these plugins. The workstation profile also adds fzf and zoxide.

To add plugins to an existing setup, run `./setup install zsh-config --yes`, then
`exec zsh`. Press Right Arrow at the end of a command to accept a suggestion.

## Go manager (in progress)

`./setup` is the full installer. The newer `usm` currently supports APT package
management on Ubuntu 24.04+; other backends are still being migrated.

With Go 1.23+ installed:

```sh
make build
./usm list
./usm install git --dry-run
sudo ./usm install git --yes
sudo ./usm update git --yes
sudo ./usm remove git --yes
```

Run from this repository or pass `--modules PATH`. USM tracks packages it installs
and does not adopt existing packages or installations made by `./setup`. Removal
preserves user data. Plans use local APT indexes; refresh them with
`sudo apt-get update` when needed.

See the [module catalog](modules/README.md) for configuration details and the
[migration plan](plan.md) for remaining work.

## Installation notes

- **Ghostty:** uses APT on Ubuntu 26.04+, otherwise Snap.
- **Sogou Pinyin:** uses Fcitx 4. After logging back in, add Sogou through
  `fcitx-configtool` if needed. Desktop compatibility on Ubuntu 24.04+ still needs
  validation.
- **Blocked downloads:** ToDesk and Sogou accept local packages through
  `TODESK_DEB=/path/to/package.deb` or `SOGOU_DEB=/path/to/package.deb` before
  `./setup install todesk` or `./setup install sogoupinyin`, respectively.

## Development

Keep Bash registrations in `components/` and JSON configs in `modules/` aligned.
The managed shell config lives in [config/zshrc](config/zshrc).

```sh
make test
make check
```

These checks require Go and Python 3. Use `make GO=/path/to/go test` if Go is not
on your `PATH`.
