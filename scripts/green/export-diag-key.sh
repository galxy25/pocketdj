#!/usr/bin/env bash
# Export the PocketDJ diag-writer key (Secrets Manager) into a .pdjdiagkey file that the app
# imports (Settings ▸ Debug ▸ "Import upload key from file…", drag & drop onto that row, or
# double-click the file). Levi never types the key: import it once on the Mac and the
# "diag-key" credsync doc carries it to every device on the Apple ID.
#
#   scripts/green/export-diag-key.sh                 # green (profile llc) → ~/Downloads/pocketdj-diag-key.pdjdiagkey
#   scripts/green/export-diag-key.sh --env blue      # blue's equivalent, READ-ONLY (errors if none exists)
#   scripts/green/export-diag-key.sh --out <path>    # different output path
#
# File shape (schema v1 — must match DiagKeyFile in apple/PocketDJ/Support/DiagKeyImport.swift):
#   {"type":"pocketdj-diag-key","schemaVersion":1,"env":"green","account":"623170744161",
#    "accessKeyID":"AKIA…","secret":"…","exportedAt":"2026-…Z"}
#
# SECRET HYGIENE: the secret value never touches argv, an env var, stdout, or stderr. The aws
# output is piped straight into an isolated python that writes the file (mode 0600, created
# under umask 077) and prints only non-secret facts. Never run this with `bash -x`.
# Read-only against AWS (describe-secret + get-secret-value). Test: scripts/test/export-diag-key.test.sh
set -euo pipefail
umask 077

ENV_NAME="green"
OUT="${HOME}/Downloads/pocketdj-diag-key.pdjdiagkey"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --env=*) ENV_NAME="${1#--env=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "export-diag-key: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$ENV_NAME" in
  green) PROFILE="llc";  SECRET_ID="pocketdj/green/pocketdj-diag-writer" ;;
  # Blue is the nonprofit's account: read-only. Its diag-writer key was never stored in
  # Secrets Manager (2026-10-12), so this errors unless one is added there later.
  blue)  PROFILE="levi"; SECRET_ID="pocketdj/blue/pocketdj-diag-writer" ;;
  *) echo "export-diag-key: --env must be green or blue (got '$ENV_NAME')" >&2; exit 2 ;;
esac
[[ -n "$OUT" ]] || { echo "export-diag-key: --out needs a path" >&2; exit 2; }

command -v aws >/dev/null || { echo "export-diag-key: aws CLI not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "export-diag-key: python3 not found" >&2; exit 1; }

# 1. Metadata only (no value): proves the secret exists and yields the owning account (ARN).
if ! ARN=$(aws --profile "$PROFILE" secretsmanager describe-secret --secret-id "$SECRET_ID" \
             --query ARN --output text 2>/dev/null) || [[ -z "$ARN" || "$ARN" == "None" ]]; then
  echo "export-diag-key: no $ENV_NAME diag-writer secret '$SECRET_ID' (profile $PROFILE) — nothing exported" >&2
  exit 1
fi
ACCOUNT=$(printf '%s' "$ARN" | cut -d: -f5)
if [[ ! "$ACCOUNT" =~ ^[0-9]{12}$ ]]; then
  echo "export-diag-key: could not read the account id from the secret ARN" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

# 2. The value: aws stdout → python stdin → file. Nothing secret is printed on any path
#    (python reports decode problems generically, never echoing input).
aws --profile "$PROFILE" secretsmanager get-secret-value --secret-id "$SECRET_ID" \
    --query SecretString --output text 2>/dev/null \
| python3 -I -c '
import json, os, sys, re, datetime
out, env, account = sys.argv[1], sys.argv[2], sys.argv[3]
raw = sys.stdin.read()
def fail(msg):
    sys.stderr.write("export-diag-key: " + msg + "\n"); sys.exit(1)
if not raw.strip():
    fail("secret value was empty or unreadable (aws error suppressed to keep output secret-free)")
try:
    d = json.loads(raw)
except Exception:
    fail("secret value is not JSON")
if not isinstance(d, dict):
    fail("secret value is not a JSON object")
kid = str(d.get("AccessKeyId") or d.get("accessKeyId") or d.get("accessKeyID") or "").strip()
sec = str(d.get("SecretAccessKey") or d.get("secretAccessKey") or d.get("secret") or "").strip()
if not kid or not sec:
    fail("secret JSON lacks AccessKeyId/SecretAccessKey (keys present: %s)" % sorted(d.keys()))
if not re.fullmatch(r"(AKIA|ASIA)[A-Z0-9]{16}", kid):
    fail("AccessKeyId does not look like an IAM access key id")
doc = {"type": "pocketdj-diag-key", "schemaVersion": 1, "env": env, "account": account,
       "accessKeyID": kid, "secret": sec,
       "exportedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
tmp = out + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, sort_keys=True)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, out)
# Non-secret confirmation only: the key id TAIL (last 4) so the operator can tell keys apart.
print("export-diag-key: wrote %s (env=%s account=%s key=…%s, mode 0600)" % (out, env, account, kid[-4:]))
' "$OUT" "$ENV_NAME" "$ACCOUNT"

echo "export-diag-key: next — PocketDJ (Mac) ▸ Settings ▸ Debug ▸ Import upload key from file… (or double-click the file)"
