#!/usr/bin/env bash
set -uo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
args=(install)
profile=workstation
only=''
dry_run=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Options:
  --profile minimal|workstation               Installation profile (default: workstation)
  --only base,cli,desktop,ai                  Run only these groups
  --dry-run                                  Print commands without running them
  -h, --help                                 Show this help
EOF
}

while (($#)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      profile="$2"
      shift 2
      ;;
    --only)
      [[ $# -ge 2 ]] || die "--only requires a comma-separated value"
      only="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done
if [[ -n "$only" ]]; then
  IFS=',' read -r -a groups <<<"$only"
  for group in "${groups[@]}"; do
    case "$group" in
      base) args+=(git git-lfs openssh zsh) ;;
      cli) args+=(ripgrep fd fd-link bat bat-link fzf jq yq btop nvtop tmux shellcheck shfmt eza build-essential cmake ninja clang gdb ccache starship zoxide zsh-config) ;;
      desktop) args+=(chrome zed ghostty wechat feishu todesk vscode) ;;
      ai) args+=(pixi uv codex zsh-config) ;;
      *) printf 'error: unknown group: %s\n' "$group" >&2; exit 1 ;;
    esac
  done
else
  args+=(--profile "$profile")
fi
((dry_run)) && args+=(--dry-run)
exec "$REPO_DIR/setup" "${args[@]}"
