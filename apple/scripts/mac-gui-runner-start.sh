#!/usr/bin/env bash
# Start the Mac GUI runner. RUN THIS FROM Terminal.app ON THE MAC — not over SSH.
#
# Claude connects over SSH, which lands in a launchd "Background" session with no
# window-server access, so it cannot drive macOS UI at all (screencapture fails,
# every app reports 0 windows, XCUITest times out enabling automation mode). This
# server, started from your desktop session, does that driving on Claude's behalf.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -n "${SSH_CONNECTION:-}" ]; then
  echo "⚠️  You appear to be over SSH (SSH_CONNECTION is set)."
  echo "    macOS UI automation will NOT work from here. Start this from Terminal.app on the Mac."
  echo
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec node scripts/mac-gui-runner.mjs
