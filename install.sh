#!/bin/bash
set -euo pipefail

REPO="newtontriumphant/kopfkino"
APPS="${KOPFKINO_APPS:-$HOME/Applications}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*"; exit 1; }

say "installing kopfkino :3"

[ "$(uname)" = "Darwin" ] || die "kopfkino only works on a Mac, sorry!"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "kopfkino needs macOS 14 (Sonoma) or newer. you have $(sw_vers -productVersion)."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "first, macOS needs Apple's developer tools.
a popup should have appeared: click \"Install\" and wait for it to finish (5-10 min).
then paste the same install command again!"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/macos/Kopfkino.swift" ]; then
  SRC="$here"
else
  say "downloading…"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$TMP"
  SRC="$TMP/kopfkino-main"
fi

say "building (takes ~30 seconds)…"
bash "$SRC/build.sh" >/dev/null

pkill -x Kopfkino 2>/dev/null || true
mkdir -p "$APPS"
rm -rf "$APPS/Kopfkino.app"
cp -R "$SRC/build/Kopfkino.app" "$APPS/Kopfkino.app"

say "done! kopfkino is in $APPS"
echo
echo "  1. put BOTH AirPods in your ears (and make them your Mac's sound output)"
echo "  2. if macOS asks to let Kopfkino use motion data, click Allow"
echo "  3. press K in the flight sim to calibrate"
echo
echo "  next time just open Kopfkino from Spotlight (cmd + space, type kopfkino)."
echo "  it lives in your menu bar (the AirPods icon) where you can quit it."
echo

[ "${KOPFKINO_NO_OPEN:-0}" = "1" ] || open "$APPS/Kopfkino.app"
