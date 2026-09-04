#!/usr/bin/env bash
#
# Build the current tree into /Applications/yap.app, signed with a real
# identity so the Accessibility grant survives.
#
# This is the loop for testing a change on this machine. It runs the same
# scripts/build-release.sh that CI runs, with notarization skipped — building
# the bundle rather than a bare binary is the point, because the bundle is
# what the product is and what TCC and LaunchServices see.
#
# The signing is the other half. An adhoc-signed build gives TCC nothing
# stable to key on, so it falls back to the code hash and every rebuild
# invalidates the Accessibility grant while System Settings still shows the
# row ticked. Signed with a Developer ID, the grant follows the identity.
#
#   APP_IDENTITY  signing identity. Auto-detected when exactly one Developer ID
#                 Application certificate exists; required otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LABEL="com.terrifiedbug.yap"
# Same variable name as build-release.sh, so one export covers both. Resolved
# automatically only when the choice is unambiguous: silently picking the
# first of several would sign with an identity you did not mean, and TCC keys
# on the identity, so the grant would break the next time the other one won.
APP_IDENTITY="${APP_IDENTITY:-}"
if [[ -z "$APP_IDENTITY" ]]; then
  # Newline-delimited rather than an array: macOS still ships bash 3.2 at
  # /bin/bash, which has no mapfile, and `env bash` finds it whenever a
  # newer one is not on PATH.
  found=$(
    security find-identity -v -p codesigning |
      awk -F'"' '/Developer ID Application/ { print $2 }'
  )
  count=$(printf '%s' "$found" | grep -c . || true)
  if [[ "$count" -eq 1 ]]; then
    APP_IDENTITY="$found"
  elif [[ "$count" -eq 0 ]]; then
    echo "No Developer ID Application certificate found." >&2
    echo "Signing is the whole point of this script — an adhoc binary loses the" >&2
    echo "Accessibility grant on every rebuild. Create one in Xcode → Settings →" >&2
    echo "Accounts → Manage Certificates." >&2
    exit 1
  else
    echo "More than one Developer ID Application certificate:" >&2
    printf '%s\n' "$found" | sed 's/^/  /' >&2
    echo "Pick one: APP_IDENTITY=\"...\" $0" >&2
    exit 1
  fi
fi

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

VERSION=$(sed -n 's/.*version: "\(.*\)".*/\1/p' Sources/yap/Yap.swift)
[[ -n "$VERSION" ]] || { echo "couldn't read the version from Sources/yap/Yap.swift" >&2; exit 1; }

step "Building yap.app $VERSION"
SKIP_NOTARIZE=1 VERSION="$VERSION" APP_IDENTITY="$APP_IDENTITY" ./scripts/build-release.sh

# A binary left at /usr/local/bin by an older yap is not merely stale: it is a
# second copy under a different code identity, and whichever one launchd runs
# is the one that owns the Accessibility grant. One binary, one identity.
if [[ -e /usr/local/bin/yap ]]; then
  step "Removing the stale /usr/local/bin/yap"
  echo "it predates the GUI-first layout and splits the TCC identity in two."
  sudo rm -f /usr/local/bin/yap
fi

step "Installing to /Applications"
# ditto rather than cp -R: it preserves the signature's extended attributes.
rm -rf /Applications/yap.app
ditto dist/yap.app /Applications/yap.app

step "Starting it"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  # Under launchd already: replace the job's image in place, so the login item
  # keeps pointing at the same place and a recording in flight is finalized by
  # the SIGTERM that -k sends.
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  echo "kickstarted the login agent"
else
  open -n /Applications/yap.app
  echo "launched /Applications/yap.app"
fi

echo
echo "The menu bar mark should be up within a second, and will say what it"
echo "still needs. Logs: $HOME/Library/Logs/yap/yap.err.log"
