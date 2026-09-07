#!/usr/bin/env bash

declare -ag COMPONENT_IDS=()
declare -Ag C_LABEL=() C_CATEGORY=() C_DESCRIPTION=() C_PROFILES=()
declare -Ag C_PROBES=() C_PACKAGES=() C_TYPE=() C_DEPS=() C_PRIVILEGE=()
declare -Ag C_ARCHES=() C_RELEASES=() C_INSTALLER=() C_HIDDEN=() C_CHECKER=()

register_component() {
  local id="${1:-}" key value
  shift || true
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid component ID: $id"
  [[ -z "${C_LABEL[$id]+x}" ]] || die "duplicate component ID: $id"
  C_LABEL[$id]="$id" C_CATEGORY[$id]="" C_DESCRIPTION[$id]=""
  C_PROFILES[$id]="" C_PROBES[$id]="" C_PACKAGES[$id]="" C_TYPE[$id]="apt"
  C_DEPS[$id]="" C_PRIVILEGE[$id]="no" C_ARCHES[$id]="amd64 arm64"
  C_RELEASES[$id]="22.04+" C_INSTALLER[$id]="" C_HIDDEN[$id]="no" C_CHECKER[$id]=""
  for key in "$@"; do
    [[ "$key" == *=* ]] || die "invalid registration field for $id: $key"
    value="${key#*=}"; key="${key%%=*}"
    case "$key" in
      label) C_LABEL[$id]="$value" ;; category) C_CATEGORY[$id]="$value" ;;
      description) C_DESCRIPTION[$id]="$value" ;; profiles) C_PROFILES[$id]="$value" ;;
      probes) C_PROBES[$id]="$value" ;; packages) C_PACKAGES[$id]="$value" ;;
      type) C_TYPE[$id]="$value" ;; deps) C_DEPS[$id]="$value" ;;
      privilege) C_PRIVILEGE[$id]="$value" ;; arches) C_ARCHES[$id]="$value" ;;
      releases) C_RELEASES[$id]="$value" ;; installer) C_INSTALLER[$id]="$value" ;;
      checker) C_CHECKER[$id]="$value" ;;
      hidden) C_HIDDEN[$id]="$value" ;; *) die "unknown registration field: $key" ;;
    esac
  done
  [[ "${C_TYPE[$id]}" =~ ^(apt|remote|deb|snap|symlink|custom)$ ]] || die "invalid installer type for $id"
  if [[ "${C_TYPE[$id]}" == custom ]]; then
    [[ "${C_INSTALLER[$id]}" =~ ^component_[a-zA-Z0-9_]+$ ]] || die "invalid installer function for $id"
  fi
  [[ -z "${C_CHECKER[$id]}" || "${C_CHECKER[$id]}" =~ ^component_[a-zA-Z0-9_]+_status$ ]] || die "invalid status checker for $id"
  COMPONENT_IDS+=("$id")
}

discover_components() {
  local dir="$1" file
  [[ -d "$dir" ]] || die "component directory not found: $dir"
  while IFS= read -r file; do
    # shellcheck source=/dev/null
    source "$file"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
  ((${#COMPONENT_IDS[@]})) || die "no components registered"
}
