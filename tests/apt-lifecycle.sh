#!/usr/bin/env bash
# Run ONLY in a fresh disposable Ubuntu container/VM with the repository at /repo.
set -euo pipefail
[[ ${USM_DISPOSABLE:-} == 1 && $(id -u) == 0 ]] || {
  echo 'Requires root and USM_DISPOSABLE=1 in a disposable Ubuntu environment.' >&2
  exit 2
}
cd /repo
[[ ! -e /var/lib/usm ]]
if dpkg-query -W -f='${db:Status-Status}' git 2>/dev/null | grep -qx installed; then
  echo 'Fixture must start without Git installed.' >&2
  exit 2
fi
apt-get update
./usm list --json
./usm install git --dry-run --json
[[ ! -e /var/lib/usm ]]
./usm install git --yes
./usm install git --yes --json
./usm update git --yes
./usm pin git --yes
./usm update --all --dry-run --json
./usm lock --output /tmp/usm.lock.json
./usm sync --lock /tmp/usm.lock.json --dry-run --json
./usm sync --lock /tmp/usm.lock.json --yes --json
./usm unpin git --yes
./usm remove git --dry-run --json
[[ -f /var/lib/usm/git.json ]]
./usm remove git --yes
[[ ! -f /var/lib/usm/git.json ]]
if dpkg-query -W -f='${db:Status-Status}' git 2>/dev/null | grep -qx installed; then
  echo 'Git remains installed after removal.' >&2
  exit 1
fi
./usm remove git --yes --json
# An external installation must never be adopted or removed.
apt-get install -y git
./usm install git --yes
./usm update git --yes
./usm remove git --yes
[[ ! -f /var/lib/usm/git.json ]]
dpkg-query -W -f='${db:Status-Status}' git | grep -qx installed
printf '\nAPT lifecycle passed.\n'
