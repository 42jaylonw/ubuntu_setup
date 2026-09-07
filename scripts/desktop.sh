#!/usr/bin/env bash

install_chrome() {
  has_command google-chrome && return
  local arch tmp_dir deb
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != amd64 ]]; then
    warn "automatic Google Chrome install is currently limited to amd64; use Google's Linux download page for $arch"
    return
  fi
  if ((DRY_RUN)); then
    log "Would download and install Google's current stable Chrome .deb"
    return
  fi
  tmp_dir="$(mktemp -d)"
  deb="$tmp_dir/google-chrome.deb"
  curl --proto '=https' --tlsv1.2 -fsSL \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    -o "$deb"
  sudo apt-get install -y "$deb"
  rm -rf -- "$tmp_dir"
}

install_ghostty() {
  has_command ghostty && return
  local method="${GHOSTTY_METHOD:-auto}"
  if [[ "$method" == auto ]]; then
    if dpkg --compare-versions "$VERSION_ID" ge 26.04; then
      method=apt
    else
      method=snap
    fi
  fi
  case "$method" in
    apt) apt_install ghostty ;;
    snap)
      if has_command snap || ((DRY_RUN)); then
        run sudo snap install ghostty --classic
      else
        warn "snap is unavailable; use GHOSTTY_METHOD=community or install Ghostty manually"
      fi
      ;;
    community)
      run_remote_installer ghostty-community \
        https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh bash
      ;;
    *) die "unsupported GHOSTTY_METHOD: $method (use auto, apt, snap, or community)" ;;
  esac
}

install_desktop() {
  install_chrome
  has_command zed || run_remote_installer zed https://zed.dev/install.sh sh
  install_ghostty
}
