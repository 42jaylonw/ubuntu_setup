#!/usr/bin/env bash

# These components resolve vendor "latest stable" channels on installation
# and when explicitly selected by ./setup update.

component_wechat() {
  local machine url
  case "$PLATFORM_ARCH" in amd64) machine=x86_64 ;; arm64) machine=arm64 ;; *) return 1 ;; esac
  url="https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_${machine}.deb"
  download_and_install_deb wechat "$url"
}

component_feishu() {
  local platform metadata url checksum
  case "$PLATFORM_ARCH" in amd64) platform=10 ;; arm64) platform=12 ;; *) return 1 ;; esac
  if ((DRY_RUN)); then log "Would resolve and install the latest Feishu Linux package for $PLATFORM_ARCH"; return; fi
  metadata="$(curl --proto '=https' --tlsv1.2 -fsSL "https://www.feishu.cn/api/package_info?platform=$platform")" || return 1
  url="$(jq -r '.data.download_link // empty' <<<"$metadata")"
  checksum="$(jq -r '.data.hash // empty' <<<"$metadata")"
  [[ "$url" == https://* && -n "$checksum" ]] || { warn 'Feishu returned invalid package metadata'; return 1; }
  download_and_install_deb feishu "$url" "$checksum"
}

component_todesk() {
  local page url local_deb="${TODESK_DEB:-}"
  if [[ -n "$local_deb" ]]; then
    if ((DRY_RUN)); then log "Would install ToDesk from local package: $local_deb"; return; fi
    install_deb_file todesk "$local_deb"
    return
  fi
  if ((DRY_RUN)); then log "Would resolve and install the latest ToDesk Linux package for $PLATFORM_ARCH"; return; fi
  page="$(curl --proto '=https' --tlsv1.2 -fsSL 'https://www.todesk.com/linux.html?product=remote&type=individual')" || return 1
  url="$(sed 's#\\u002F#/#g' <<<"$page" | grep -oE "https://dl\\.todesk\\.com/linux/todesk-v[0-9.]+-${PLATFORM_ARCH}\\.deb" | sort -V | tail -n 1)"
  [[ "$url" == https://dl.todesk.com/linux/* ]] || { warn 'could not resolve the latest ToDesk package'; return 1; }
  download_and_install_deb todesk "$url" || {
    warn 'ToDesk blocked the automatic download. Download the Debian/Ubuntu package in a browser, then rerun:'
    warn '  TODESK_DEB=/path/to/todesk.deb ./setup install todesk'
    return 1
  }
}

component_vscode() {
  local target
  case "$PLATFORM_ARCH" in amd64) target=linux-deb-x64 ;; arm64) target=linux-deb-arm64 ;; *) return  ;; esac
  if ((DRY_RUN)); then
    log 'Would enable the official Microsoft apt repository during VS Code package installation'
  else
    printf '%s\n' 'code code/add-microsoft-repo boolean true' | sudo debconf-set-selections || return 1
  fi
  download_and_install_deb vscode "https://update.code.visualstudio.com/latest/${target}/stable"
}

register_component wechat label='WeChat' category=desktop description='Tencent WeChat Linux client (latest stable)' profiles=workstation probes=wechat type=custom deps=bootstrap privilege=yes installer=component_wechat
register_component feishu label='Feishu' category=desktop description='Feishu collaboration client' profiles=workstation probes=bytedance-feishu-stable type=custom deps='bootstrap jq' privilege=yes installer=component_feishu
register_component todesk label='ToDesk' category=desktop description='ToDesk remote desktop client' profiles=workstation probes=todesk type=custom deps=bootstrap privilege=yes installer=component_todesk
register_component vscode label='Visual Studio Code' category=desktop description='Microsoft code editor (latest stable)' profiles=workstation probes=code type=custom deps=bootstrap privilege=yes installer=component_vscode
