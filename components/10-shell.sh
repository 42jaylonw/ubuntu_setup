#!/usr/bin/env bash

UBUNTU_SETUP_ZSH_CONFIG_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config/zshrc"

component_starship() { run_remote_installer starship https://starship.rs/install.sh sh --yes; }
component_zoxide() { run_remote_installer zoxide https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh sh; }
component_zsh_config() {
  local file="$HOME/.zshrc" config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ubuntu-setup"
  local source_file="$UBUNTU_SETUP_ZSH_CONFIG_SOURCE" begin='# >>> ubuntu-setup >>>' end='# <<< ubuntu-setup <<<' tmp
  if ((DRY_RUN)); then
    log "Would install managed Zsh config in $config_dir and update $file"
    return
  fi
  [[ -r "$source_file" ]] || { warn "Zsh config asset not found: $source_file"; return 1; }
  mkdir -p -- "$config_dir" "$(dirname -- "$file")"
  install -m 0644 -- "$source_file" "$config_dir/zshrc"
  tmp="$(mktemp)" || return 1
  if [[ -f "$file" ]]; then awk -v b="$begin" -v e="$end" '$0==b {skip=1} !skip {print} $0==e {skip=0}' "$file" >"$tmp"; fi
  {
    cat "$tmp"
    printf '\n%s\n' "$begin"
    printf '%s\n' '[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/ubuntu-setup/zshrc" ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/ubuntu-setup/zshrc"'
    printf '%s\n' "$end"
  } >"$file"
  rm -f -- "$tmp"
}
component_zsh_config_status() {
  local installed="${XDG_CONFIG_HOME:-$HOME/.config}/ubuntu-setup/zshrc"
  [[ -f "$HOME/.zshrc" && -f "$installed" ]] &&
    grep -Fq '# >>> ubuntu-setup >>>' "$HOME/.zshrc" && cmp -s -- "$UBUNTU_SETUP_ZSH_CONFIG_SOURCE" "$installed"
}

register_component zsh label='Zsh' category=shell description='Interactive shell' profiles='minimal workstation' probes='zsh' packages='zsh' type=apt deps=bootstrap privilege=yes
register_component zsh-autosuggestions label='Zsh autosuggestions' category=shell description='Suggest commands from shell history' profiles='minimal workstation' packages=zsh-autosuggestions type=apt deps=zsh privilege=yes
register_component zsh-syntax-highlighting label='Zsh syntax highlighting' category=shell description='Highlight commands while typing' profiles='minimal workstation' packages=zsh-syntax-highlighting type=apt deps=zsh privilege=yes
register_component starship label='Starship' category=shell description='Cross-shell prompt' profiles=workstation probes=starship type=custom deps=bootstrap installer=component_starship
register_component zoxide label='zoxide' category=shell description='Smarter directory navigation' profiles=workstation probes=zoxide type=custom deps=bootstrap installer=component_zoxide
register_component fzf label='fzf' category=shell description='Fuzzy finder' profiles=workstation probes=fzf packages=fzf type=apt deps=bootstrap privilege=yes
register_component zsh-config label='Managed Zsh configuration' category=shell description='History, completion, plugins, PATH, prompt, and tool hooks' profiles='minimal workstation' packages='' type=custom deps='zsh zsh-autosuggestions zsh-syntax-highlighting' installer=component_zsh_config checker=component_zsh_config_status
