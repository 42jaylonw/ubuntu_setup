#!/usr/bin/env bash

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
UPDATE_MODE=0
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
declare -ag PLAN=() REQUESTED=()
declare -Ag RESULT=() VISITING=() VISITED=()

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
has_command() { command -v "$1" >/dev/null 2>&1; }
contains_word() { [[ " $1 " == *" $2 "* ]]; }

load_platform() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "cannot read $OS_RELEASE_FILE"
  local ID="" VERSION_ID="" VERSION_CODENAME=""
  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  [[ "$ID" == ubuntu ]] || die "this setup targets Ubuntu (found ${ID:-unknown})"
  dpkg --compare-versions "$VERSION_ID" ge 22.04 || die "Ubuntu 22.04 or newer is required"
  PLATFORM_VERSION="$VERSION_ID"; PLATFORM_CODENAME="${VERSION_CODENAME:-unknown}"
  PLATFORM_ARCH="${SETUP_ARCH:-$(dpkg --print-architecture)}"
  [[ "$PLATFORM_ARCH" == amd64 || "$PLATFORM_ARCH" == arm64 ]] || die "unsupported architecture: $PLATFORM_ARCH"
}

run() {
  if ((DRY_RUN)); then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi
}

component_supported() {
  local id="$1" min="${C_RELEASES[$id]%+}"
  contains_word "${C_ARCHES[$id]}" "$PLATFORM_ARCH" || return 1
  [[ "${C_RELEASES[$id]}" == *+ ]] && dpkg --compare-versions "$PLATFORM_VERSION" ge "$min"
}

component_status() {
  local id="$1" probe found=0 total=0 package
  component_supported "$id" || { printf unsupported; return; }
  if [[ -n "${C_CHECKER[$id]}" ]]; then
    "${C_CHECKER[$id]}" && printf installed || printf missing
    return
  fi
  for probe in ${C_PROBES[$id]}; do
    total=$((total + 1)); has_command "$probe" && found=$((found + 1))
  done
  if ((total == 0)); then
    for package in ${C_PACKAGES[$id]}; do
      total=$((total + 1)); dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' && found=$((found + 1))
    done
  fi
  if ((total > 0 && found == total)); then printf installed
  elif ((found > 0)); then printf partial
  else printf missing; fi
}

validate_ids() { local id; for id in "$@"; do [[ -n "${C_LABEL[$id]+x}" ]] || die "unknown component: $id"; done; }

list_components() {
  printf '%-18s %-10s %-12s %-28s %s\n' ID CATEGORY PROFILES LABEL DESCRIPTION
  local id
  for id in "${COMPONENT_IDS[@]}"; do
    [[ "${C_HIDDEN[$id]}" == yes ]] && continue
    printf '%-18s %-10s %-12s %-28s %s\n' "$id" "${C_CATEGORY[$id]}" "${C_PROFILES[$id]:--}" "${C_LABEL[$id]}" "${C_DESCRIPTION[$id]}"
  done
}

status_symbol() { case "$1" in installed|successful) printf '✓' ;; partial) printf '◐' ;; missing) printf '○' ;; unsupported) printf '⊘' ;; failed) printf '✗' ;; blocked) printf '!' ;; skipped) printf '–' ;; esac; }

status_components() {
  load_platform
  local -a ids=("$@"); ((${#ids[@]})) || ids=("${COMPONENT_IDS[@]}")
  validate_ids "${ids[@]}"
  printf '%-3s %-18s %-12s %s\n' '' COMPONENT STATUS DESCRIPTION
  local id status
  for id in "${ids[@]}"; do
    [[ "${C_HIDDEN[$id]}" == yes && $# == 0 ]] && continue
    status="$(component_status "$id")"
    printf '%-3s %-18s %-12s %s\n' "$(status_symbol "$status")" "$id" "$status" "${C_DESCRIPTION[$id]}"
  done
}

add_requested() { local id; for id in "$@"; do [[ " ${REQUESTED[*]} " == *" $id "* ]] || REQUESTED+=("$id"); done; }
expand_profile() { local id hit=0; for id in "${COMPONENT_IDS[@]}"; do if contains_word "${C_PROFILES[$id]}" "$1"; then add_requested "$id"; hit=1; fi; done; ((hit)) || die "unknown or empty profile: $1"; }
expand_categories() { local category id hit; IFS=',' read -r -a categories <<<"$1"; for category in "${categories[@]}"; do hit=0; for id in "${COMPONENT_IDS[@]}"; do if [[ "${C_CATEGORY[$id]}" == "$category" && "${C_HIDDEN[$id]}" != yes ]]; then add_requested "$id"; hit=1; fi; done; ((hit)) || die "unknown or empty category: $category"; done; }

visit_component() {
  local id="$1" dep
  [[ -z "${VISITING[$id]:-}" ]] || die "dependency cycle involving $id"
  [[ -z "${VISITED[$id]:-}" ]] || return 0
  VISITING[$id]=1
  for dep in ${C_DEPS[$id]}; do validate_ids "$dep"; visit_component "$dep"; done
  unset 'VISITING[$id]'; VISITED[$id]=1; PLAN+=("$id")
}
build_plan() { PLAN=(); VISITING=(); VISITED=(); local id; for id in "${REQUESTED[@]}"; do visit_component "$id"; done; }

preview_plan() {
  if ((UPDATE_MODE)); then printf '\nUpdate plan (missing selected tools are skipped):\n'
  else printf '\nInstallation plan:\n'; fi
  local id status
  for id in "${PLAN[@]}"; do status="$(component_status "$id")"; printf '  %-2s %-18s %-10s %s\n' "$(status_symbol "$status")" "$id" "$status" "${C_LABEL[$id]}"; done
}

confirm_plan() {
  ((DRY_RUN || ASSUME_YES)) && return 0
  [[ -t 0 ]] || die "confirmation requires a terminal; pass --yes"
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

dependencies_ok() { local dep; for dep in ${C_DEPS[$1]}; do [[ "${RESULT[$dep]:-}" =~ ^(successful|skipped)$ ]] || return 1; done; }

install_non_apt() {
  local id="$1" fn="${C_INSTALLER[$1]}"
  case "${C_TYPE[$id]}" in
    custom) declare -F "$fn" >/dev/null || return 1; "$fn" ;;
    remote) run_remote_installer "$id" "$fn" sh ;;
    snap) run sudo snap install "${C_PACKAGES[$id]}" --classic ;;
    symlink)
      local source_path
      source_path="$(command -v "$fn" 2>/dev/null || true)"
      if [[ -z "$source_path" && "$DRY_RUN" == 1 ]]; then source_path="/usr/bin/$fn"; fi
      [[ -n "$source_path" ]] || return 1
      run mkdir -p "$HOME/.local/bin" && { [[ -e "$HOME/.local/bin/${C_PACKAGES[$id]}" ]] || run ln -s "$source_path" "$HOME/.local/bin/${C_PACKAGES[$id]}"; } ;;
    deb) install_deb_component "$id" "$fn" ;;
    *) return 1 ;;
  esac
}

install_deb_component() { download_and_install_deb "$1" "$2"; }

install_deb_file() {
  local id="$1" deb="$2" architecture
  [[ -f "$deb" && -r "$deb" ]] || { warn "$id package is not a readable file: $deb"; return 1; }
  dpkg-deb --info "$deb" >/dev/null 2>&1 || {
    warn "$id package is not a valid Debian archive: $deb"
    return 1
  }
  architecture="$(dpkg-deb --field "$deb" Architecture 2>/dev/null)" || {
    warn "could not determine the architecture of $id package: $deb"
    return 1
  }
  [[ "$architecture" == all || "$architecture" == "$PLATFORM_ARCH" ]] || {
    warn "$id package architecture is $architecture, but this machine is $PLATFORM_ARCH"
    return 1
  }
  sudo apt-get install -y "$deb"
}

download_and_install_deb() {
  local id="$1" url="$2" checksum="${3:-}" tmp deb actual
  if ((DRY_RUN)); then log "Would download and install $url"; return; fi
  (
    tmp="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    deb="$tmp/$id.deb"
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$deb" || exit 1
    if [[ -n "$checksum" ]]; then
      case "${#checksum}" in
        32) actual="$(md5sum "$deb" | awk '{print $1}')" ;;
        64) actual="$(sha256sum "$deb" | awk '{print $1}')" ;;
        *) warn "unsupported checksum format for $id"; exit 1 ;;
      esac
      [[ "$actual" == "$checksum" ]] || { warn "checksum verification failed for $id"; exit 1; }
    fi
    install_deb_file "$id" "$deb" || exit 1
  )
}

execute_plan() {
  local id status failed=0 needs_sudo=0 apt_failed=0
  local -a apt_ids=() apt_packages=()
  RESULT=()
  for id in "${PLAN[@]}"; do
    status="$(component_status "$id")"
    if ((UPDATE_MODE)) && contains_word "${REQUESTED[*]}" "$id" && [[ "$status" == missing ]]; then RESULT[$id]=skipped
    elif [[ "$status" == installed ]] && { ((! UPDATE_MODE)) || ! contains_word "${REQUESTED[*]}" "$id"; }; then RESULT[$id]=skipped
    elif [[ "$status" == unsupported ]]; then RESULT[$id]=failed; failed=1
    elif [[ "${C_TYPE[$id]}" == apt ]]; then apt_ids+=("$id"); read -r -a packages <<<"${C_PACKAGES[$id]}"; apt_packages+=("${packages[@]}"); [[ "${C_PRIVILEGE[$id]}" == yes ]] && needs_sudo=1
    else [[ "${C_PRIVILEGE[$id]}" == yes ]] && needs_sudo=1; fi
  done
  if ((needs_sudo && ! DRY_RUN)); then sudo -v || die "sudo authentication failed"; fi
  if ((${#apt_ids[@]})); then
    log "Installing ${#apt_ids[@]} apt components in one batch"
    run sudo apt-get update && run sudo apt-get install -y --no-install-recommends "${apt_packages[@]}" || apt_failed=1
    for id in "${apt_ids[@]}"; do if ((apt_failed)); then RESULT[$id]=failed; failed=1; else RESULT[$id]=successful; fi; done
  fi
  for id in "${PLAN[@]}"; do
    [[ -n "${RESULT[$id]:-}" ]] && continue
    if ! dependencies_ok "$id"; then RESULT[$id]=blocked; failed=1; continue; fi
    if ((UPDATE_MODE)) && contains_word "${REQUESTED[*]}" "$id"; then
      log "Updating ${C_LABEL[$id]}"
      if update_non_apt "$id"; then RESULT[$id]=successful; else RESULT[$id]=failed; failed=1; fi
    else
      log "Installing ${C_LABEL[$id]}"
      if install_non_apt "$id"; then RESULT[$id]=successful; else RESULT[$id]=failed; failed=1; fi
    fi
  done
  printf '\nSummary:\n'
  for id in "${PLAN[@]}"; do printf '  %-2s %-18s %s\n' "$(status_symbol "${RESULT[$id]}")" "$id" "${RESULT[$id]}"; done
  ((failed)) && warn 'One or more components failed or were blocked; fix the reported prerequisite and rerun ./setup status.'
  return "$failed"
}

update_non_apt() {
  local id="$1"
  case "$id" in
    pixi) run pixi self-update ;;
    uv) run uv self update ;;
    *)
      if [[ "${C_TYPE[$id]}" == snap ]]; then run sudo snap refresh "${C_PACKAGES[$id]}"
      else install_non_apt "$id"; fi ;;
  esac
}

install_cli() {
  load_platform
  REQUESTED=(); local profile="" categories=""
  while (($#)); do case "$1" in
    --profile) [[ $# -ge 2 ]] || die '--profile requires a value'; profile="$2"; shift 2 ;;
    --category) [[ $# -ge 2 ]] || die '--category requires a value'; categories="${categories:+$categories,}$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; ASSUME_YES=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --) shift; add_requested "$@"; break ;;
    -*) die "unknown install/update option: $1" ;;
    *) add_requested "$1"; shift ;;
  esac; done
  [[ -z "$profile" ]] || expand_profile "$profile"
  [[ -z "$categories" ]] || expand_categories "$categories"
  ((${#REQUESTED[@]})) || expand_profile workstation
  validate_ids "${REQUESTED[@]}"; build_plan; preview_plan
  confirm_plan || { warn 'installation cancelled'; return 130; }
  execute_plan
}

run_remote_installer() {
  local name="$1" url="$2" interpreter="${3:-sh}" tmp_dir installer
  shift 3 || true
  if ((DRY_RUN)); then log "Would download and run $name installer from $url"; return; fi
  (
    tmp_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$tmp_dir"' EXIT
    installer="$tmp_dir/install"
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$installer" || exit 1
    chmod 0700 "$installer" && "$interpreter" "$installer" "$@"
  )
}

interactive_dashboard() {
  load_platform
  local gum choice selected categories category installed=0 missing=0 id status
  gum="$(bootstrap_gum 2>/dev/null || true)"
  for id in "${COMPONENT_IDS[@]}"; do [[ "${C_HIDDEN[$id]}" == yes ]] && continue; status="$(component_status "$id")"; [[ "$status" == installed ]] && installed=$((installed+1)) || missing=$((missing+1)); done
  printf '\033[1;36mUbuntu Setup\033[0m\nUbuntu %s (%s) · %s · workstation · %d installed / %d missing\n\n' "$PLATFORM_VERSION" "$PLATFORM_CODENAME" "$PLATFORM_ARCH" "$installed" "$missing"
  if [[ -n "$gum" ]]; then
    choice="$($gum choose 'Quick workstation setup' 'Select categories' 'Select individual tools' 'View status' 'Exit')" || return 130
  else
    warn 'Gum unavailable; using ANSI menu'
    printf '1) Quick workstation setup\n2) Select categories\n3) Select individual tools\n4) View status\n5) Exit\n'
    read -r -p 'Choose [1-5]: ' choice
    case "$choice" in 1) choice='Quick workstation setup';; 2) choice='Select categories';; 3) choice='Select individual tools';; 4) choice='View status';; *) choice='Exit';; esac
  fi
  case "$choice" in
    'Quick workstation setup') install_cli --profile workstation ;;
    'View status') status_components ;;
    'Select categories')
      if [[ -n "$gum" ]]; then
        selected="$($gum choose --no-limit Base Shell CLI Build Desktop 'AI / Python')" || return 130
        [[ -n "$selected" ]] || { warn 'no categories selected'; return 130; }
        categories=""
        while IFS= read -r category; do [[ "$category" == 'AI / Python' ]] && category=ai || category="${category,,}"; categories="${categories:+$categories,}$category"; done <<<"$selected"
        install_cli --category "$categories"
      else printf 'Available: base, shell, cli, build, desktop, ai\n'; read -r -p 'Categories (comma-separated): ' categories; install_cli --category "$categories"; fi ;;
    'Select individual tools')
      if [[ -n "$gum" ]]; then
        local defaults=""
        for id in "${COMPONENT_IDS[@]}"; do [[ "${C_HIDDEN[$id]}" == yes ]] && continue; contains_word "${C_PROFILES[$id]}" workstation && defaults="${defaults:+$defaults,}$id"; done
        selected="$({ for id in "${COMPONENT_IDS[@]}"; do [[ "${C_HIDDEN[$id]}" == yes ]] || printf '%s\n' "$id"; done; } | "$gum" choose --no-limit --filter --selected "$defaults")" || return 130
        [[ -n "$selected" ]] || { warn 'no components selected'; return 130; }
        mapfile -t chosen < <(printf '%s\n' "$selected"); install_cli "${chosen[@]}"
      else list_components; read -r -p 'Component IDs (space-separated): ' selected; [[ -n "$selected" ]] || { warn 'no components selected'; return 130; }; read -r -a chosen <<<"$selected"; install_cli "${chosen[@]}"; fi ;;
    *) return 0 ;;
  esac
}

bootstrap_gum() {
  has_command gum && { command -v gum; return; }
  local version=0.14.5 machine asset cache tmp archive sums expected actual
  case "$PLATFORM_ARCH" in amd64) machine=x86_64 ;; arm64) machine=arm64 ;; *) return 1 ;; esac
  asset="gum_${version}_Linux_${machine}.tar.gz"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/ubuntu-setup/gum/$version"
  [[ -x "$cache/gum" ]] && { printf '%s\n' "$cache/gum"; return; }
  (
    tmp="$(mktemp -d)" || exit 1; trap 'rm -rf -- "$tmp"' EXIT
    archive="$tmp/$asset"; sums="$tmp/checksums.txt"
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v$version/$asset" -o "$archive" || exit 1
    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/v$version/checksums.txt" -o "$sums" || exit 1
    expected="$(awk -v f="$asset" '$2==f {print $1}' "$sums")"; [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || exit 1
    actual="$(sha256sum "$archive" | awk '{print $1}')"; [[ "$actual" == "$expected" ]] || exit 1
    mkdir -p "$cache"; tar -xzf "$archive" -C "$tmp" || exit 1
    install -m 0755 "$tmp/gum" "$cache/gum" || exit 1
    printf '%s\n' "$cache/gum"
  )
}
