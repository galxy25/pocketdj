#!/usr/bin/env bash
# Publicly expose the PocketDJ jukebox server (interim, iMac) via Tailscale Funnel path-mount.
# Guests are NOT on the Tailnet, so unlike the rip server this service must be reachable from
# the open internet — Funnel gives it a TLS public URL without opening a port on the router.
#
#   scripts/setup-jukebox-funnel.sh
#
# PORT CHOICE IS LOAD-BEARING: Funnel is per-PORT, and this machine's 443 already serves the
# TAILNET-ONLY rip server at / — funneling a path on 443 would expose the rip server to the
# public internet too. The jukebox therefore rides Funnel's second HTTPS port (8443); the rip
# server's Tailnet boundary is untouched.
#
# Idempotent: prints the current funnel status, mounts :8443/jukebox → 127.0.0.1:8788 if it
# isn't already, and echoes the resulting public base (must match JUKEBOX_PUBLIC_BASE + the
# app's Settings ▸ Jukebox base URL). The funnel strips the /jukebox mount before forwarding;
# the server strips a leading /jukebox too, so direct and mounted access dispatch identically.
#
# NOTE: this changes machine network state — run it ON the iMac yourself; CI never invokes it.
set -euo pipefail

PORT="${JUKEBOX_PORT:-8788}"
FUNNEL_PORT="${JUKEBOX_FUNNEL_PORT:-8443}"
MOUNT="/jukebox"
TARGET="http://127.0.0.1:${PORT}"

# The CLI may not be on PATH on macOS — fall back to the app bundle's binary.
TS="$(command -v tailscale || true)"
[ -z "$TS" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] \
  && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -z "$TS" ] && { echo "✗ tailscale CLI not found (install Tailscale first)" >&2; exit 1; }

echo "▶ current funnel status:"
"$TS" funnel status 2>/dev/null || echo "  (no funnels configured yet)"

if "$TS" funnel status 2>/dev/null | grep -q ":${FUNNEL_PORT}" && \
   "$TS" funnel status 2>/dev/null | grep -q "${MOUNT} proxy ${TARGET}"; then
  echo "✓ funnel already mounts :${FUNNEL_PORT}${MOUNT} → ${TARGET}"
else
  echo "▶ mounting :${FUNNEL_PORT}${MOUNT} → ${TARGET} …"
  "$TS" funnel --bg --https="${FUNNEL_PORT}" --set-path "${MOUNT}" "${TARGET}"
fi

# Derive the public base from this node's MagicDNS name (….ts.net) + port + mount path.
DNS="$("$TS" status --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"
if [ -n "$DNS" ]; then
  echo "✓ public base: https://${DNS}:${FUNNEL_PORT}${MOUNT}"
  echo "  must match JUKEBOX_PUBLIC_BASE + Settings ▸ Jukebox base URL."
else
  echo "⚠ could not derive the MagicDNS name — read it from 'funnel status' above and append :${FUNNEL_PORT}${MOUNT}."
fi
