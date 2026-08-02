#!/usr/bin/env bash
#
# Build the current tree and install it over /usr/local/bin/yap, signed with a
# real identity so the Accessibility grant survives.
#
# This is the loop for testing a change on this machine. scripts/build-release.sh
# is the other one: it builds the .app, notarizes and packages a .dmg for other
# people. Nothing here is distributable.
#
# The signing is the point. An adhoc-signed binary gives TCC nothing stable to
# key on, so it falls back to the code hash, and every rebuild invalidates the
# Accessibility grant while System Settings still shows the row ticked. Signed
# with a Developer ID, the grant follows the identity and survives rebuilds.
#
#   APP_IDENTITY  signing identity. Auto-detected when exactly one Developer ID
#                 Application certificate exists; required otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=".build/arm64-apple-macosx/release/yap"
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

step "Building"
swift build -c release --arch arm64

step "Signing"
# --timestamp=none: a secure timestamp needs a round trip to Apple and only
# matters for distribution. Local installs are rebuilt constantly.
codesign --force --options runtime --timestamp=none \
  --entitlements packaging/yap.entitlements \
  --sign "$APP_IDENTITY" "$BIN"
echo "signed: $APP_IDENTITY"

step "Installing"
LOG="$HOME/Library/Logs/yap/yap.err.log"
# Only read what this run appends; the log outlives many installs.
offset=$(stat -f%z "$LOG" 2>/dev/null || echo 0)

sudo install -m 755 "$BIN" /usr/local/bin/yap
/usr/local/bin/yap install --launch-at-login

# `install --launch-at-login` reports that it wrote and bootstrapped the agent,
# which is not the same as the agent being usable: it exits 0 when
# Accessibility is missing, precisely so KeepAlive does not relaunch it
# forever. Check rather than claim.
#
# A PID is not the check either. On a cold model cache the daemon downloads
# several hundred megabytes and compiles for the ANE before it ever touches
# Accessibility, so it has a PID for minutes and then exits. Waiting on the
# line it prints when the hotkey tap is actually live is the only signal that
# means what it says.
step "Waiting for it to come up"

running() { launchctl list "$LABEL" 2>/dev/null | grep -q '"PID" ='; }
ready() { tail -c "+$((offset + 1))" "$LOG" 2>/dev/null | grep -q 'listening on'; }

echo "(first run downloads the model — this can take a few minutes)"
deadline=$((SECONDS + 600))
while [ "$SECONDS" -lt "$deadline" ]; do
  if ready; then
    echo "✓ running"
    exit 0
  fi
  running || break
  sleep 2
done

if ready; then
  echo "✓ running"
  exit 0
fi

# Almost always the one-time grant. Changing the signing identity — including
# the first time this script signs what used to be adhoc — gives TCC a new
# identity to key on, so the old row is dead even though it still looks ticked.
#
# The daemon has already exited by now, and exits 0 so KeepAlive leaves it
# alone. Granting therefore fixes nothing on its own: something has to start it
# again afterwards. That is the whole reason this does not just print and quit.
echo "not running yet — it starts, finds no Accessibility grant, and exits."
echo
echo "  1. remove any stale 'yap' row, then add:  /usr/local/bin/yap"
echo "  2. come back here and press Return"
echo
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
read -r _

step "Starting it again"
offset=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  ready && break
  running || break
  sleep 2
done
if ready; then
  echo "✓ running"
else
  echo "✗ still not running. The reason is in the log:" >&2
  echo "  tail ~/Library/Logs/yap/yap.err.log" >&2
  echo "  /usr/local/bin/yap doctor" >&2
  exit 1
fi
