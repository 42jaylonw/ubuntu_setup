#!/usr/bin/env bash

# Sogou uses Fcitx 4. The vendor guide's Qt runtime packages are needed in
# addition to the dependencies declared in the DEB.
# https://shurufa.sogou.com/linux/guide
component_sogoupinyin_url() {
  # The official page embeds download URLs in escaped JSON. Match only its
  # HTTPS download host, package name, and the selected architecture.
  sed 's/\\//g' | grep -oE "https://ime-sec\\.gtimg\\.com/pc/dl/[A-Za-z0-9/_-]+/sogoupinyin_[0-9.]+_${PLATFORM_ARCH}\\.deb" | sort -Vu | tail -n 1
}

# Same public URL signing used by Sogou's Linux download button. The CDN
# rejects the unsigned URLs embedded in the page with HTTP 403.
component_sogoupinyin_signed_url() {
  local path="${1#https://ime-sec.gtimg.com}" stamp digest
  [[ "$1" == https://ime-sec.gtimg.com/pc/dl/* ]] || return 1
  stamp="$(TZ=Asia/Shanghai date +%Y%m%d%H%M)" || return 1
  digest="$(printf '%s' "44tv2uj7ct7j0gfixf19cs6bdvqdhi${stamp}${path}" | md5sum)" || return 1
  printf 'https://ime-sec.gtimg.com/%s/%s%s\n' "$stamp" "${digest%% *}" "$path"
}

component_sogoupinyin_conflicts() {
  local package
  for package in fcitx5-chinese-addons-data fcitx5-module-punctuation fcitx5-pinyin fcitx5-table; do
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" == installed ]]; then
      printf '%s-\n' "$package"
    fi
  done
}

component_sogoupinyin() {
  local local_deb="${SOGOU_DEB:-}" package architecture
  local -a runtime=(fcitx fcitx-config-gtk fcitx-frontend-gtk3 fcitx-frontend-qt5 im-config
    libqt5qml5 libqt5quick5 libqt5quickwidgets5 qml-module-qtquick2 libgsettings-qt1)
  if ((DRY_RUN)); then
    if [[ -n "$local_deb" ]]; then log "Would validate and install Sogou from $local_deb"
    else log "Would resolve the official Sogou Linux download for $PLATFORM_ARCH"; fi
    run sudo apt-get install -y --no-install-recommends "${runtime[@]}"
    [[ "${SOGOU_REPLACE_FCITX5:-0}" != 1 ]] || log 'Would replace conflicting Fcitx 5 packages with Fcitx 4 after APT simulation'
    run im-config -n fcitx
    return
  fi
  (
    local tmp deb page url simulation removed
    local -a conflicts=() apt_args
    tmp="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    deb="$local_deb"
    if [[ -z "$deb" ]]; then
      page="$(curl --proto '=https' --tlsv1.2 -fsSL https://shurufa.sogou.com/linux)" || exit 1
      url="$(component_sogoupinyin_url <<<"$page")"
      [[ -n "$url" ]] || { warn 'Sogou download not found; set SOGOU_DEB to a package from https://shurufa.sogou.com/linux'; exit 1; }
      deb="$tmp/sogoupinyin.deb"
      url="$(component_sogoupinyin_signed_url "$url")" || exit 1
      curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$deb" || {
        warn 'Sogou download failed; download from https://shurufa.sogou.com/linux and set SOGOU_DEB=/absolute/path/to/package.deb'
        exit 1
      }
    fi
    dpkg-deb --info "$deb" >/dev/null 2>&1 || { warn 'Sogou download is not a valid Debian archive'; exit 1; }
    package="$(dpkg-deb --field "$deb" Package)" || exit 1
    architecture="$(dpkg-deb --field "$deb" Architecture)" || exit 1
    [[ "$package" == sogoupinyin && "$architecture" == "$PLATFORM_ARCH" ]] || {
      warn "Expected sogoupinyin for $PLATFORM_ARCH; got $package for $architecture"
      exit 1
    }
    # APT requires an absolute path or ./ prefix for local archives.
    deb="$(realpath -- "$deb")" || exit 1
    mapfile -t conflicts < <(component_sogoupinyin_conflicts)
    if ((${#conflicts[@]})) && [[ "${SOGOU_REPLACE_FCITX5:-0}" != 1 ]]; then
      warn 'Fcitx 5 Chinese-input packages conflict with Sogou/Fcitx 4. Rerun with SOGOU_REPLACE_FCITX5=1 to replace them (no purge or autoremove).'
      exit 1
    fi
    apt_args=(--no-install-recommends --no-auto-remove)
    [[ "${SOGOU_REPLACE_FCITX5:-0}" == 1 ]] || apt_args+=(--no-remove)
    apt_args+=(install "$deb" "${runtime[@]}" "${conflicts[@]}")
    simulation="$(LC_ALL=C apt-get --simulate "${apt_args[@]}" 2>&1)" || { warn "$simulation"; exit 1; }
    while read -r removed; do
      case "$removed" in
        fcitx5|fcitx5-chinese-addons|fcitx5-chinese-addons-bin|fcitx5-chinese-addons-data|fcitx5-module-pinyinhelper|fcitx5-module-punctuation|fcitx5-pinyin|fcitx5-table)
          [[ "${SOGOU_REPLACE_FCITX5:-0}" == 1 ]] || exit 1 ;;
        *) warn "Refusing unexpected APT removal: $removed"; exit 1 ;;
      esac
      log "Replacing conflicting package: $removed"
    done < <(awk '$1 == "Remv" {print $2}' <<<"$simulation")
    # Keep runtime replacement and Sogou in one resolved transaction. Download
    # first so a network failure leaves the current input method installed.
    run sudo apt-get -y --download-only "${apt_args[@]}" || exit 1
    run sudo apt-get -y "${apt_args[@]}" || exit 1
    [[ "$(dpkg-query -W -f='${db:Status-Status}' sogoupinyin 2>/dev/null)" == installed ]] || exit 1
    run im-config -n fcitx || exit 1
    log 'Sogou installed. Log out and back in, open fcitx-configtool, and add Sogou Pinyin if absent.'
    log 'Previously configured Fcitx 5 autostart entries may need disabling in Startup Applications.'
  )
}

register_component sogoupinyin label='Sogou Pinyin' category=desktop description='Sogou Chinese input method with Fcitx 4' profiles=workstation packages='sogoupinyin fcitx fcitx-config-gtk fcitx-frontend-gtk3 fcitx-frontend-qt5 im-config libqt5qml5 libqt5quick5 libqt5quickwidgets5 qml-module-qtquick2 libgsettings-qt1' type=custom deps=bootstrap privilege=yes installer=component_sogoupinyin
