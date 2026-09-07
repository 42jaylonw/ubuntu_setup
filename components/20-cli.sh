#!/usr/bin/env bash

component_yq() {
  local version='v4.53.6' machine checksum tmp binary
  if apt-cache show yq >/dev/null 2>&1; then
    run sudo apt-get install -y --no-install-recommends yq
    return
  fi
  case "$PLATFORM_ARCH" in
    amd64)
      machine=amd64
      checksum=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385
      ;;
    arm64)
      machine=arm64
      checksum=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09
      ;;
    *) return 1 ;;
  esac
  if ((DRY_RUN)); then
    log "Would install yq $version for $PLATFORM_ARCH from its verified upstream binary"
    return
  fi
  tmp="$(mktemp -d)" || return 1
  (
    trap 'rm -rf -- "$tmp"' EXIT
    binary="$tmp/yq"
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/mikefarah/yq/releases/download/$version/yq_linux_$machine" -o "$binary" || exit 1
    printf '%s  %s\n' "$checksum" "$binary" | sha256sum -c - >/dev/null || {
      warn 'checksum verification failed for yq'
      exit 1
    }
    sudo install -m 0755 -- "$binary" /usr/local/bin/yq
  )
}

register_component ripgrep label='ripgrep' category=cli description='Fast recursive text search' profiles=workstation probes=rg packages=ripgrep type=apt deps=bootstrap privilege=yes
register_component fd label='fd' category=cli description='Friendly file finder' profiles=workstation probes=fdfind packages=fd-find type=apt deps=bootstrap privilege=yes
register_component fd-link label='fd command alias' category=cli description='Expose fdfind as fd in ~/.local/bin' profiles=workstation probes=fd packages=fd type=symlink deps=fd installer=fdfind
register_component bat label='bat' category=cli description='Syntax-highlighting file viewer' profiles=workstation probes=batcat packages=bat type=apt deps=bootstrap privilege=yes
register_component bat-link label='bat command alias' category=cli description='Expose batcat as bat in ~/.local/bin' profiles=workstation probes=bat packages=bat type=symlink deps=bat installer=batcat
register_component jq label='jq' category=cli description='JSON processor' profiles=workstation probes=jq packages=jq type=apt deps=bootstrap privilege=yes
register_component yq label='yq' category=cli description='YAML processor' profiles=workstation probes=yq type=custom deps=bootstrap privilege=yes installer=component_yq
register_component btop label='btop' category=cli description='System resource monitor' profiles=workstation probes=btop packages=btop type=apt deps=bootstrap privilege=yes
register_component nvtop label='nvtop' category=cli description='GPU process monitor' profiles=workstation probes=nvtop packages=nvtop type=apt deps=bootstrap privilege=yes
register_component tmux label='tmux' category=cli description='Terminal multiplexer' profiles=workstation probes=tmux packages=tmux type=apt deps=bootstrap privilege=yes
register_component shellcheck label='ShellCheck' category=cli description='Static analysis for shell scripts' profiles=workstation probes=shellcheck packages=shellcheck type=apt deps=bootstrap privilege=yes
register_component shfmt label='shfmt' category=cli description='Shell script formatter' profiles=workstation probes=shfmt packages=shfmt type=apt deps=bootstrap privilege=yes
register_component eza label='eza / exa' category=cli description='Modern directory listing' profiles=workstation probes=eza packages=eza type=custom deps=bootstrap privilege=yes installer=component_eza checker=component_eza_status

component_eza() {
  if apt-cache show eza >/dev/null 2>&1; then run sudo apt-get install -y --no-install-recommends eza
  elif apt-cache show exa >/dev/null 2>&1; then run sudo apt-get install -y --no-install-recommends exa
  else warn 'eza/exa is unavailable for this Ubuntu release'; return 1; fi
}
component_eza_status() { has_command eza || has_command exa; }
