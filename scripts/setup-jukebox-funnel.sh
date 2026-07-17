#!/usr/bin/env bash
# Publicly expose the PocketDJ jukebox server (interim, iMac) via Tailscale Funnel path-mount.
# Guests are NOT on the Tailnet, so unlike the rip server this service must be reachable from
# the open internet — Funnel gives it a TLS public URL without opening a port on the router.
#
#   scripts/setup-jukebox-funnel.sh
#
# Idempotent: prints the current funnel status, mounts /jukebox → 127.0.0.1:8788 if it isn't
# already, and echoes the resulting public base (bake this into JUKEBOX_PUBLIC_BASE + the app's
# Settings ▸ Jukebox base URL). The funnel strips the /jukebox mount before forwarding; the
# server strips a leading /jukebox too, so both direct and mounted access dispatch identically.
#
# NOTE: this changes machine network state — run it ON the iMac yourself; CI never invokes it.
set -euo pipefail

PORT="${JUKEBOX_PORT:-8788}"
MOUNT="/jukebox"
TARGET="http://127.0.0.1:${PORT}"

command -v tailscale >/dev/null 2>&1 || { echo "✗ tailscale CLI not found (install Tailscale first)" >&2; exit 1; }

echo "▶ current funnel status:"
tailscale funnel status 2>/dev/null || echo "  (no funnels configured yet)"

if tailscale funnel status 2>/dev/null | grep -q "${MOUNT} proxy ${TARGET}"; then
  echo "✓ funnel already mounts ${MOUNT} → ${TARGET}"
else
  echo "▶ mounting ${MOUNT} → ${TARGET} …"
  tailscale funnel --bg --set-path "${MOUNT}" "${TARGET}"
fi

# Derive the public base from this node's MagicDNS name (…​.ts.net) + the mount path.
DNS="$(tailscale status --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"
if [ -n "$DNS" ]; then
  echo "✓ public base: https://${DNS}${MOUNT}"
  echo "  set JUKEBOX_PUBLIC_BASE + Settings ▸ Jukebox base URL to that value."
else
  echo "⚠ could not derive the MagicDNS name — read it from 'tailscale funnel status' above and append ${MOUNT}."
fi
