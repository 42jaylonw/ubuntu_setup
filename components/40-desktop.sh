#!/usr/bin/env bash

component_ghostty() {
  local method="${GHOSTTY_METHOD:-auto}"
  if [[ "$method" == auto ]]; then if dpkg --compare-versions "$PLATFORM_VERSION" ge 26.04; then method=apt; else method=snap; fi; fi
  case "$method" in
    apt) run sudo apt-get install -y --no-install-recommends ghostty ;;
    snap)
      if ((DRY_RUN)); then log 'Would install or refresh the Ghostty Snap (stable channel)'; return; fi
      has_command snap || ((DRY_RUN)) || { warn 'snap is unavailable'; return 1; }
      if snap list ghostty >/dev/null 2>&1; then run sudo snap refresh ghostty
      else run sudo snap install ghostty --classic; fi ;;
    community) run_remote_installer ghostty-community https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh bash ;;
    *) warn "unsupported GHOSTTY_METHOD: $method"; return 1 ;;
  esac
}

register_component chrome label='Google Chrome' category=desktop description='Web browser' profiles=workstation probes=google-chrome type=deb deps=bootstrap privilege=yes arches=amd64 installer=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
register_component zed label='Zed' category=desktop description='GPU-accelerated code editor' profiles=workstation probes=zed type=remote deps=bootstrap installer=https://zed.dev/install.sh
register_component ghostty label='Ghostty' category=desktop description='GPU-accelerated terminal' profiles=workstation probes=ghostty type=custom deps=bootstrap privilege=yes installer=component_ghostty
