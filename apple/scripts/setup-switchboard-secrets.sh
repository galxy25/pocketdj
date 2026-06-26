#!/usr/bin/env bash
# setup-switchboard-secrets.sh — generate the GITIGNORED Switchboard secrets Swift file from the
# repo-root switchboard-credentials.json. Run once after cloning (and whenever the keys change)
# so the Mix tab compiles + initializes with the real appID/appSecret/Superpowered license. The
# secret is NEVER hardcoded into committed Swift — it lives only in this generated file.
#
#   apple/scripts/setup-switchboard-secrets.sh
#
# Reads:  <repo>/switchboard-credentials.json                  (gitignored — Levi's real keys)
# Writes: <repo>/apple/PocketDJ/Mix/SwitchboardSecrets.swift   (gitignored)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
creds="$repo_root/switchboard-credentials.json"
out="$repo_root/apple/PocketDJ/Mix/SwitchboardSecrets.swift"

if [[ ! -f "$creds" ]]; then
  echo "error: $creds not found (gitignored — ask Levi for the Switchboard keys)" >&2
  exit 1
fi

# Pull the three fields. Prefer jq; fall back to python3 (both ship on a dev Mac).
read_field() {
  if command -v jq >/dev/null 2>&1; then
    jq -er ".$1" "$creds"
  else
    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$creds" "$1"
  fi
}

app_id="$(read_field appID)"
app_secret="$(read_field appSecret)"
license="$(read_field superpoweredLicenseKey)"

mkdir -p "$(dirname "$out")"
cat > "$out" <<EOF
// SwitchboardSecrets.swift — GENERATED, GITIGNORED. Do NOT commit; do NOT edit by hand.
// Regenerate with: apple/scripts/setup-switchboard-secrets.sh
// Source of truth: <repo>/switchboard-credentials.json
enum SwitchboardSecrets {
    static let appID = "$app_id"
    static let appSecret = "$app_secret"
    static let superpoweredLicenseKey = "$license"
}
EOF

echo "wrote $out"
