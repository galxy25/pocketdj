#!/usr/bin/env bash
# PUBLICLY expose the PocketDJ rip server (iMac) via Tailscale Funnel — the beta-testing
# promotion. Beta users are NOT on the Tailnet, so rip-on-demand / live HLS / search-add
# must be reachable from the open internet, exactly like the jukebox broker.
#
#   scripts/setup-rip-funnel.sh
#
# PORT CHOICE IS LOAD-BEARING: Funnel is per-PORT and this machine already uses
#   443  → `tailscale serve` (Tailnet-only rip server — kept, Levi's devices don't change)
#   8443 → Funnel /jukebox (guest request line)
# so the public rip server rides Funnel's THIRD HTTPS port, 10000.
#
# Public posture is the server's DEFAULT (beta doctrine: simplicity first, high-trust
# testers — it always boots, warning if tokens are missing). This script provisions the
# tokens in ~/.pocketdj/rip-server.env (chmod 600, NEVER in the repo — the launchd plist
# stays secret-free; the server reads the env file):
#   RIP_TOKEN        user tier — beta testers (rip/stream/status/search)
#   RIP_ADMIN_TOKEN  admin tier — Levi only (backfills, ingest, analysis, am-sync)
# Existing tokens are kept (idempotent), so re-running never invalidates distributed ones.
# Per-IP rate limiting ships OFF; add RIP_RATE_LIMIT=1 to the env file if it's ever needed.
#
# NOTE: this changes machine network state — run it ON the iMac yourself; CI never invokes it.
set -euo pipefail

PORT="${RIP_PORT:-8787}"
FUNNEL_PORT="${RIP_FUNNEL_PORT:-10000}"
TARGET="http://127.0.0.1:${PORT}"
ENV_FILE="$HOME/.pocketdj/rip-server.env"
LABEL="com.pocketdj.ripserver"

# The CLI may not be on PATH on macOS — fall back to the app bundle's binary.
TS="$(command -v tailscale || true)"
[ -z "$TS" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] \
  && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -z "$TS" ] && { echo "✗ tailscale CLI not found (install Tailscale first)" >&2; exit 1; }

# ---- tokens: generate once, keep forever (re-runs must not break distributed tokens) ----
mkdir -p "$HOME/.pocketdj"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
get_env() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
set_env() {  # upsert KEY=VALUE in the env file
  grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
  echo "$1=$2" >> "$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
USER_TOKEN="$(get_env RIP_TOKEN)"
ADMIN_TOKEN="$(get_env RIP_ADMIN_TOKEN)"
[ -z "$USER_TOKEN" ]  && USER_TOKEN="$(openssl rand -hex 24)"  && echo "▶ generated RIP_TOKEN (user tier)"
[ -z "$ADMIN_TOKEN" ] && ADMIN_TOKEN="$(openssl rand -hex 24)" && echo "▶ generated RIP_ADMIN_TOKEN (admin tier)"
set_env RIP_TOKEN "$USER_TOKEN"
set_env RIP_ADMIN_TOKEN "$ADMIN_TOKEN"
set_env RIP_PUBLIC "1"

# ---- restart the server so it picks up public mode + tokens ----
if launchctl list "$LABEL" >/dev/null 2>&1; then
  echo "▶ restarting $LABEL (public mode) …"
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  echo "⚠ launchd agent $LABEL not loaded — load it, then re-run (scripts/launchd/$LABEL.plist)"
fi
for _ in $(seq 1 15); do
  curl -s -m 2 "http://localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -s -m 3 "http://localhost:$PORT/health" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('auth') and d.get('public'), d; print('✓ rip server is up in PUBLIC mode (auth on)')" \
  || { echo "✗ server not healthy in public mode — check ~/.pocketdj/rip-server.log" >&2; exit 1; }

# ---- funnel mount (idempotent) ----
echo "▶ current funnel status:"
"$TS" funnel status 2>/dev/null || echo "  (no funnels configured yet)"
if "$TS" funnel status 2>/dev/null | grep -q ":${FUNNEL_PORT}"; then
  echo "✓ funnel already serves :${FUNNEL_PORT}"
else
  echo "▶ mounting :${FUNNEL_PORT} → ${TARGET} …"
  "$TS" funnel --bg --https="${FUNNEL_PORT}" "${TARGET}"
fi

# Derive the public base from this node's MagicDNS name.
DNS="$("$TS" status --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)"
echo ""
echo "✓ public rip server base: https://${DNS:-<magicdns-name>}:${FUNNEL_PORT}"
echo "  (must match Config.ripServerBase / Settings ▸ Rip server URL)"
echo ""
echo "  beta-tester token (Settings ▸ Rip server ▸ token):"
echo "    $USER_TOKEN"
echo "  ADMIN token (Levi's devices ONLY — never distribute):"
echo "    $ADMIN_TOKEN"
