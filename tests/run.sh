#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
not_ok() { printf 'not ok - %s\n' "$1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }
contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }

tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/bin"
cat >"$tmp/os-release" <<'EOF'
ID=ubuntu
VERSION_ID=22.04
VERSION_CODENAME=jammy
EOF

# shellcheck source=../scripts/lib.sh
source "$ROOT/scripts/lib.sh"
# shellcheck source=../scripts/registry.sh
source "$ROOT/scripts/registry.sh"
HOME="$tmp/home" OS_RELEASE_FILE="$tmp/os-release" SETUP_ARCH=amd64
discover_components "$ROOT/components"
load_platform

check 'component discovery preserves nvtop' test -n "${C_LABEL[nvtop]:-}"
check 'bundled shell tooling is registered' test -n "${C_LABEL[shellcheck]:-}${C_LABEL[shfmt]:-}"
check 'optional direnv component is omitted' test -z "${C_LABEL[direnv]:-}"
check 'optional GitHub CLI component is omitted' test -z "${C_LABEL[gh]:-}"
check 'workstation preserves Chrome' contains "${C_PROFILES[chrome]}" workstation
check 'Sogou is registered for workstation' contains "${C_PROFILES[sogoupinyin]}" workstation
check 'Sogou includes Fcitx 4 runtime' contains " ${C_PACKAGES[sogoupinyin]} " ' fcitx '
check 'Fcitx 5 component is replaced' test -z "${C_LABEL[fcitx5]:-}"
for added in codex wechat vscode; do
  check "$added is registered for workstation" contains "${C_PROFILES[$added]}" workstation
done
for added in feishu todesk; do
  check "$added is registered for workstation" contains "${C_PROFILES[$added]}" workstation
done
check 'Feishu probes its packaged executable' test "${C_PROBES[feishu]}" = bytedance-feishu-stable
check 'yq uses the verified upstream installer' test "${C_INSTALLER[yq]}" = component_yq
REQUESTED=(); expand_profile minimal
check 'minimal includes Git' contains " ${REQUESTED[*]} " ' git '
check 'minimal excludes desktop' not_contains " ${REQUESTED[*]} " ' chrome '
REQUESTED=(); expand_categories cli; build_plan
check 'dependencies precede requested components' test "${PLAN[0]}" = bootstrap
REQUESTED=(zsh-config); build_plan
check 'Zsh config installs its plugins before activation' test "${PLAN[*]}" = 'bootstrap zsh zsh-autosuggestions zsh-syntax-highlighting zsh-config'

component_test_status() { return 1; }
register_component partial-test label=Partial category=cli description=fixture probes='bash command-that-does-not-exist' type=custom installer=component_test checker=''
check 'multi-probe status is partial' test "$(component_status partial-test)" = partial
check 'architecture restriction is unsupported' test "$(SETUP_ARCH=arm64 PLATFORM_ARCH=arm64 component_status chrome)" = unsupported

if ( bash -c 'source "$1/scripts/lib.sh"; source "$1/scripts/registry.sh"; register_component bad_id' _ "$ROOT" ) >/dev/null 2>&1; then not_ok 'invalid IDs rejected'; else ok 'invalid IDs rejected'; fi
if ( bash -c 'source "$1/scripts/lib.sh"; source "$1/scripts/registry.sh"; register_component same; register_component same' _ "$ROOT" ) >/dev/null 2>&1; then not_ok 'duplicate IDs rejected'; else ok 'duplicate IDs rejected'; fi

out="$(HOME="$tmp/home" OS_RELEASE_FILE="$tmp/os-release" SETUP_ARCH=amd64 "$ROOT/setup" install --profile minimal --dry-run 2>&1)"
check 'dry-run shows a plan' contains "$out" 'Installation plan:'
check 'dry-run excludes workstation tools' not_contains "$out" 'Google Chrome'
check 'dry-run does not create zshrc' test ! -e "$tmp/home/.zshrc"
# Exercise the backend even when the host already has yq installed.
yq_out="$(DRY_RUN=1 PLATFORM_VERSION=22.04 component_yq 2>&1)"
check 'Jammy yq uses verified upstream fallback' contains "$yq_out" 'verified upstream binary'
check 'Jammy yq avoids unavailable apt package' not_contains "$yq_out" 'apt-get install -y --no-install-recommends yq'

component_zsh_config
printf 'user setting after block\n' >>"$tmp/home/.zshrc"
component_zsh_config
markers="$(grep -Fc '# >>> ubuntu-setup >>>' "$tmp/home/.zshrc")"
check 'managed Zsh block is not duplicated' test "$markers" -eq 1
check 'managed Zsh update preserves unrelated content' grep -Fq 'user setting after block' "$tmp/home/.zshrc"
check 'managed Zsh asset is installed' cmp -s "$ROOT/config/zshrc" "$tmp/home/.config/ubuntu-setup/zshrc"
check 'managed Zsh block sources the installed asset' grep -Fq 'ubuntu-setup/zshrc"' "$tmp/home/.zshrc"
check 'managed Zsh status verifies current asset' component_zsh_config_status

printf '\n# stale\n' >>"$tmp/home/.config/ubuntu-setup/zshrc"
check 'stale managed Zsh asset is detected' test "$(component_status zsh-config)" = missing
component_zsh_config
check 'managed Zsh asset refreshes cleanly' component_zsh_config_status

# Configuration remains installable even when Ghostty itself is already present.
REQUESTED=(ghostty); build_plan
check 'Ghostty includes startup and shell configuration' contains " ${PLAN[*]} " ' zsh-config ghostty-config ghostty '
component_ghostty_config
printf 'font-size = 14\n' >>"$HOME/.config/ghostty/config"
component_ghostty_config
check 'Ghostty preserves personal settings' grep -Fxq 'font-size = 14' "$HOME/.config/ghostty/config"
check 'Ghostty config block is not duplicated' test "$(grep -Fc '# >>> ubuntu-setup >>>' "$HOME/.config/ghostty/config")" -eq 1
check 'Ghostty config status verifies assets' component_ghostty_config_status
printf '# stale\n' >>"$HOME/.local/bin/ghostty-new-window"
check 'Ghostty detects stale launcher' test "$(component_status ghostty-config)" = missing
component_ghostty_config

launcher_result="$(
  ghostty() { printf '%s\n' "$*"; [[ "${LAUNCHER_FALLBACK:-0}" == 0 || "$1" != +new-window ]]; }
  export -f ghostty
  bash "$ROOT/config/ghostty-new-window"
)"
check 'Ghostty launcher uses D-Bus first' test "$launcher_result" = '+new-window'
launcher_result="$(
  ghostty() { printf '%s\n' "$*"; [[ "$1" != +new-window ]]; }
  export -f ghostty
  # exec needs an executable for the fallback.
  printf '#!/bin/sh\nprintf "fallback:%%s\\n" "$*"\n' >"$tmp/bin/ghostty"
  chmod +x "$tmp/bin/ghostty"
  PATH="$tmp/bin:$PATH" bash "$ROOT/config/ghostty-new-window"
)"
check 'Ghostty launcher falls back when D-Bus fails' contains "$launcher_result" 'fallback:--gtk-single-instance=true'
if command -v desktop-file-validate >/dev/null 2>&1; then
  check 'Ghostty desktop entries are valid' desktop-file-validate "$ROOT/config/ghostty.desktop" "$ROOT/config/ghostty-autostart.desktop"
fi

if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$tmp/completion-bin"
  for tool in pixi uv; do
    cat >"$tmp/completion-bin/$tool" <<'EOF'
#!/bin/sh
printf '%s\n' "$0" >>"$COMPLETION_LOG"
printf 'typeset -g completion_fixture_loaded=1\n'
EOF
    chmod +x "$tmp/completion-bin/$tool"
  done
  # Avoid unrelated prompt/tool hooks and exercise completion initialization once.
  completion_fixture="$tmp/completion-fixture.zsh"
  sed '/command -v starship /d; /command -v zoxide /d' "$ROOT/config/zshrc" >"$completion_fixture"
  for run_index in 1 2; do
    HOME="$tmp/completion-home" XDG_CACHE_HOME="$tmp/completion-cache" PATH="$tmp/completion-bin:/usr/bin:/bin" COMPLETION_LOG="$tmp/completion.log" \
      zsh -f -c 'function compdef() { :; }; function compinit() { return 99; }; source "$1"; [[ $completion_fixture_loaded == 1 ]]' _ "$completion_fixture"
    check "cached completions load on shell $run_index" test "$?" -eq 0
  done
  check 'Pixi and uv generators run only once across shells' test "$(wc -l <"$tmp/completion.log")" -eq 2
  printf '# upgraded binary\n' >>"$tmp/completion-bin/pixi"
  HOME="$tmp/completion-home" XDG_CACHE_HOME="$tmp/completion-cache" PATH="$tmp/completion-bin:/usr/bin:/bin" COMPLETION_LOG="$tmp/completion.log" \
    zsh -f -c 'source "$1"' _ "$completion_fixture"
  check 'binary changes regenerate only that completion' test "$(wc -l <"$tmp/completion.log")" -eq 3
fi

wrapper="$(HOME="$tmp/home" OS_RELEASE_FILE="$tmp/os-release" SETUP_ARCH=amd64 "$ROOT/install.sh" --only base --dry-run 2>&1)"
check 'compatibility wrapper translates --only' contains "$wrapper" 'OpenSSH client'
check 'compatibility wrapper limits category' not_contains "$wrapper" 'Google Chrome'

set +e
non_tty="$("$ROOT/setup" </dev/null 2>&1)"; rc=$?
set -e
check 'no subcommand without TTY exits 2' test "$rc" -eq 2
check 'no subcommand prints usage' contains "$non_tty" 'Usage:'

cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"
exit 0
EOF
chmod +x "$tmp/bin/sudo"
sudo_log="$tmp/sudo.log"
PATH="$tmp/bin:$PATH" SUDO_LOG="$sudo_log" HOME="$tmp/home" OS_RELEASE_FILE="$tmp/os-release" SETUP_ARCH=amd64 "$ROOT/setup" status git >/dev/null
check 'status performs no sudo calls' test ! -e "$sudo_log"
batch="$(PATH="$tmp/bin:$PATH" SUDO_LOG="$sudo_log" bash -c '
  source "$1/scripts/lib.sh"; source "$1/scripts/registry.sh"
  register_component apt-one label=One probes=never-one packages="one-a one-b" type=apt privilege=yes
  register_component apt-two label=Two probes=never-two packages=two type=apt privilege=yes
  PLATFORM_ARCH=amd64; PLATFORM_VERSION=22.04; REQUESTED=(apt-one apt-two)
  build_plan; execute_plan
' _ "$ROOT" 2>&1)"
installs="$(grep -c '^apt-get install ' "$sudo_log")"
validations="$(grep -c '^-v$' "$sudo_log")"
check 'selected apt packages are installed in one batch' test "$installs" -eq 1
check 'batched apt components retain individual success' contains "$batch" 'apt-one'
check 'sudo authentication is requested once' test "$validations" -eq 1

already_installed="$({
  component_must_skip() { printf 'installer-ran\n'; }
  register_component must-skip label=Skip probes=bash type=custom installer=component_must_skip
  REQUESTED=(must-skip); build_plan; execute_plan
} 2>&1)"
check 'installed components are always skipped' contains "$already_installed" 'must-skip          skipped'
check 'skipped component installers are not invoked' not_contains "$already_installed" 'installer-ran'

updates="$({
  UPDATE_MODE=1
  component_update_fixture() { printf 'update-ran\n'; }
  component_dependency_fixture() { printf 'dependency-ran\n'; }
  register_component update-dep probes=bash type=custom installer=component_dependency_fixture
  register_component update-present probes=bash type=custom deps=update-dep installer=component_update_fixture
  register_component update-missing probes=never-update-missing type=custom installer=component_update_fixture
  REQUESTED=(update-present update-missing); build_plan; execute_plan
} 2>&1)"
check 'update invokes installed component installer' contains "$updates" update-ran
check 'update skips installed dependencies not selected' not_contains "$updates" dependency-ran
check 'update skips missing selected tools' contains "$updates" 'update-missing     skipped'
ai_updates="$({ DRY_RUN=1; update_non_apt codex; update_non_apt pixi; update_non_apt uv; } 2>&1)"
check 'Codex updates use the official standalone installer' contains "$ai_updates" 'https://chatgpt.com/codex/install.sh'
check 'Pixi updates use self-update' contains "$ai_updates" 'pixi self-update'
check 'uv updates use self update' contains "$ai_updates" 'uv self update'
snap_update="$({
  DRY_RUN=0; GHOSTTY_METHOD=snap
  run() { printf '%s\n' "$*"; }
  snap() { [[ "$1" == list && "$2" == ghostty ]]; }
  component_ghostty
} 2>&1)"
check 'installed Ghostty Snap is refreshed' contains "$snap_update" 'snap refresh ghostty'
update_cli="$(HOME="$tmp/home" OS_RELEASE_FILE="$tmp/os-release" SETUP_ARCH=amd64 "$ROOT/setup" update git --dry-run 2>&1)"
check 'update CLI displays its plan' contains "$update_cli" 'Update plan'
check 'update upgrades selected installed APT packages' contains "$update_cli" 'apt-get install -y --no-install-recommends git'

printf '%s\n' '<html>vendor anti-bot challenge</html>' >"$tmp/not-a-package.deb"
: >"$sudo_log"
invalid_deb="$(PATH="$tmp/bin:$PATH" SUDO_LOG="$sudo_log" install_deb_file todesk "$tmp/not-a-package.deb" 2>&1 || true)"
check 'invalid Debian downloads are rejected before APT' contains "$invalid_deb" 'not a valid Debian archive'
check 'invalid Debian downloads never reach sudo' test ! -s "$sudo_log"
todesk_dry="$(TODESK_DEB="$tmp/browser-download.deb" DRY_RUN=1 component_todesk 2>&1)"
check 'ToDesk accepts an explicit browser-downloaded package' contains "$todesk_dry" 'browser-download.deb'

sogou_dry="$(SOGOU_DEB="$tmp/sogou.deb" DRY_RUN=1 component_sogoupinyin 2>&1)"
check 'Sogou accepts a local DEB in dry-run' contains "$sogou_dry" 'sogou.deb'
check 'Sogou dry-run selects Fcitx for the user' contains "$sogou_dry" 'im-config -n fcitx'
check 'Sogou dry-run includes Qt runtime' contains "$sogou_dry" 'libqt5quickwidgets5'
: >"$sudo_log"
sogou_invalid="$(PATH="$tmp/bin:$PATH" SUDO_LOG="$sudo_log" SOGOU_DEB="$tmp/not-a-package.deb" component_sogoupinyin 2>&1 || true)"
check 'Sogou rejects invalid packages before changing the system' contains "$sogou_invalid" 'not a valid Debian archive'
check 'invalid Sogou package never reaches sudo' test ! -s "$sudo_log"
sogou_page='{"link":"https:\/\/ime-sec.gtimg.com\/pc\/dl\/gzindex\/123\/sogoupinyin_4.2.1.145_amd64.deb","arm":"https://ime-sec.gtimg.com/pc/dl/gzindex/456/sogoupinyin_4.2.1.145_arm64.deb"}'
check 'Sogou resolves escaped amd64 URL' test "$(PLATFORM_ARCH=amd64 component_sogoupinyin_url <<<"$sogou_page")" = 'https://ime-sec.gtimg.com/pc/dl/gzindex/123/sogoupinyin_4.2.1.145_amd64.deb'
check 'Sogou selects arm64 URL independently' test "$(PLATFORM_ARCH=arm64 component_sogoupinyin_url <<<"$sogou_page")" = 'https://ime-sec.gtimg.com/pc/dl/gzindex/456/sogoupinyin_4.2.1.145_arm64.deb'

sogou_signed="$({
  date() { printf '202609071100\n'; }
  component_sogoupinyin_signed_url 'https://ime-sec.gtimg.com/pc/dl/gzindex/1680521603/sogoupinyin_4.2.1.145_amd64.deb'
})"
check 'Sogou signs URLs like the official download button' test "$sogou_signed" = 'https://ime-sec.gtimg.com/202609071100/6986265b4699c6c80cfec266a8f97cfb/pc/dl/gzindex/1680521603/sogoupinyin_4.2.1.145_amd64.deb'
if component_sogoupinyin_signed_url 'https://untrusted.example/package.deb' >/dev/null; then not_ok 'Sogou rejects unrelated download hosts'; else ok 'Sogou rejects unrelated download hosts'; fi

sogou_install_fixture() (
  DRY_RUN=0 SOGOU_DEB="$tmp/not-a-package.deb"
  dpkg-deb() {
    case "${3:-}" in Package) printf 'sogoupinyin\n' ;; Architecture) printf 'amd64\n' ;; esac
  }
  dpkg-query() { printf 'installed'; }
  apt-get() { printf 'Remv %s [1]\n' "${SOGOU_TEST_REMOVAL:-fcitx5}"; }
  run() { printf '%s\n' "$*"; }
  component_sogoupinyin
)
sogou_conflict="$(SOGOU_REPLACE_FCITX5=0 sogou_install_fixture 2>&1 || true)"
check 'Sogou explains Fcitx 5 replacement' contains "$sogou_conflict" 'SOGOU_REPLACE_FCITX5=1'
check 'Sogou leaves packages untouched without replacement opt-in' not_contains "$sogou_conflict" 'sudo apt-get'
sogou_replace="$(SOGOU_REPLACE_FCITX5=1 sogou_install_fixture 2>&1)"
check 'Sogou predownloads before replacing the input method' contains "$sogou_replace" 'sudo apt-get -y --download-only'
check 'Sogou installs DEB and runtime in the same transaction' contains "$sogou_replace" 'not-a-package.deb fcitx fcitx-config-gtk'
check 'Sogou configures Fcitx after successful installation' contains "$sogou_replace" 'im-config -n fcitx'
sogou_unexpected="$(SOGOU_REPLACE_FCITX5=1 SOGOU_TEST_REMOVAL=ubuntu-desktop sogou_install_fixture 2>&1 || true)"
check 'Sogou refuses unrelated package removals' contains "$sogou_unexpected" 'Refusing unexpected APT removal: ubuntu-desktop'
check 'unexpected removals never reach sudo' not_contains "$sogou_unexpected" 'sudo apt-get'

old_path="$PATH"; PATH="$tmp/bin:/usr/bin:/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/curl"
check 'Gum download failure is reported to caller' test -z "$(bootstrap_gum 2>/dev/null || true)"
fallback="$(bootstrap_gum() { return 1; }; interactive_dashboard <<<'5' 2>&1)"
check 'ANSI fallback offers equivalent core menu' contains "$fallback" 'Quick workstation setup'
PATH="$old_path"

outcomes="$({
  C_LABEL=() C_CATEGORY=() C_DESCRIPTION=() C_PROFILES=() C_PROBES=() C_PACKAGES=()
  C_TYPE=() C_DEPS=() C_PRIVILEGE=() C_ARCHES=() C_RELEASES=() C_INSTALLER=()
  C_HIDDEN=() C_CHECKER=() COMPONENT_IDS=() REQUESTED=() PLAN=() RESULT=() VISITING=() VISITED=()
  component_fail() { return 1; }; component_pass() { printf 'continued\n'; }
  register_component first label=First type=custom probes=no-first installer=component_fail
  register_component second label=Second type=custom probes=no-second installer=component_pass
  register_component third label=Third type=custom probes=no-third deps=first installer=component_pass
  PLATFORM_ARCH=amd64 PLATFORM_VERSION=22.04
  REQUESTED=(first second third); build_plan; execute_plan || true
  printf '%s/%s/%s\n' "${RESULT[first]}" "${RESULT[second]}" "${RESULT[third]}"
} 2>&1)"
check 'independent installs continue after failure' contains "$outcomes" continued
check 'failed dependencies block dependents' contains "$outcomes" 'failed/successful/blocked'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
