#!/usr/bin/env bash

UBUNTU_SETUP_GHOSTTY_ASSETS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config"

component_ghostty_config() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}" data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local file="$config_home/ghostty/config" tmp
  local begin='# >>> ubuntu-setup >>>' end='# <<< ubuntu-setup <<<'
  if ((DRY_RUN)); then
    log "Would configure Ghostty D-Bus launcher, persistent instance, and login autostart in $config_home"
    return
  fi
  mkdir -p -- "$config_home/ghostty" "$config_home/ubuntu-setup" "$config_home/autostart" "$data_home/applications" "$HOME/.local/bin"
  install -m 0644 -- "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty" "$config_home/ubuntu-setup/ghostty"
  tmp="$(mktemp)" || return 1
  if [[ -f "$file" ]]; then awk -v b="$begin" -v e="$end" '$0==b {skip=1} !skip {print} $0==e {skip=0}' "$file" >"$tmp"; fi
  {
    cat "$tmp"
    printf '\n%s\n' "$begin"
    printf 'config-file = %s/ubuntu-setup/ghostty\n' "$config_home"
    printf '%s\n' "$end"
  } >"$file"
  rm -f -- "$tmp"
  install -m 0755 -- "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty-new-window" "$HOME/.local/bin/ghostty-new-window"
  install -m 0644 -- "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty.desktop" "$data_home/applications/com.mitchellh.ghostty.desktop"
  # Snap uses a different desktop ID; override it only for that installation.
  if [[ "${GHOSTTY_METHOD:-auto}" == snap ]] || [[ -f /var/lib/snapd/desktop/applications/ghostty_com.mitchellh.ghostty.desktop ]] ||
     { [[ "${GHOSTTY_METHOD:-auto}" == auto ]] && dpkg --compare-versions "$PLATFORM_VERSION" lt 26.04; }; then
    install -m 0644 -- "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty.desktop" "$data_home/applications/ghostty_com.mitchellh.ghostty.desktop"
  fi
  install -m 0644 -- "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty-autostart.desktop" "$config_home/autostart/ubuntu-setup-ghostty.desktop"
}

component_ghostty_config_status() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}" data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  grep -Fxq "config-file = $config_home/ubuntu-setup/ghostty" "$config_home/ghostty/config" 2>/dev/null &&
    cmp -s "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty" "$config_home/ubuntu-setup/ghostty" &&
    cmp -s "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty-new-window" "$HOME/.local/bin/ghostty-new-window" &&
    cmp -s "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty.desktop" "$data_home/applications/com.mitchellh.ghostty.desktop" &&
    cmp -s "$UBUNTU_SETUP_GHOSTTY_ASSETS/ghostty-autostart.desktop" "$config_home/autostart/ubuntu-setup-ghostty.desktop"
}

register_component ghostty-config label='Ghostty startup configuration' category=desktop description='D-Bus windows, persistent instance, and login autostart' profiles=workstation type=custom deps=zsh-config installer=component_ghostty_config checker=component_ghostty_config_status
