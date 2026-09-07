#!/usr/bin/env bash

install_cli() {
  apt_install \
    build-essential cmake ninja-build clang clangd clang-format gdb ccache \
    pkg-config shellcheck shfmt ripgrep fd-find bat fzf jq yq btop nvtop tmux

  if apt-cache show eza >/dev/null 2>&1; then
    apt_install eza
  elif apt-cache show exa >/dev/null 2>&1; then
    apt_install exa
  else
    warn "eza is not packaged for this Ubuntu release; skipping it"
  fi

  # Ubuntu names these binaries differently from their upstream commands.
  run mkdir -p "$HOME/.local/bin"
  [[ -e "$HOME/.local/bin/fd" ]] || run ln -s "$(command -v fdfind || printf /usr/bin/fdfind)" "$HOME/.local/bin/fd"
  [[ -e "$HOME/.local/bin/bat" ]] || run ln -s "$(command -v batcat || printf /usr/bin/batcat)" "$HOME/.local/bin/bat"

  # These are small static binaries distributed by maintained upstream installers.
  has_command starship || run_remote_installer starship https://starship.rs/install.sh sh --yes
  has_command zoxide || run_remote_installer zoxide https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh sh

  append_zsh_block
}
