#!/usr/bin/env bash
# Offline test for scripts/green/export-diag-key.sh: a fake `aws` on PATH serves a canned
# secret, and we assert (a) the file is written in the app's import shape with mode 0600,
# (b) NOTHING the script prints — stdout or stderr, success or failure — contains secret
# material, (c) --env blue errors when blue has no such secret, and (d) a malformed secret
# fails without echoing it. Never touches AWS.
#   bash scripts/test/export-diag-key.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/green/export-diag-key.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_ID="AKIAFAKEFAKEFAKE1234"
FAKE_SECRET="fAkEsEcReT/0123456789+abcdefghijklmnopQRST"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/aws" <<'SHIM'
#!/usr/bin/env bash
# Fake aws: answers describe-secret / get-secret-value for the configured ids only.
args="$*"
mode="${FAKE_AWS_MODE:-ok}"
if [[ "$args" == *"pocketdj/green/pocketdj-diag-writer"* && "$args" == *"--profile llc"* ]]; then
  if [[ "$args" == *describe-secret* ]]; then
    echo "arn:aws:secretsmanager:us-west-2:623170744161:secret:pocketdj/green/pocketdj-diag-writer-AbCdEf"; exit 0
  fi
  if [[ "$args" == *get-secret-value* ]]; then
    case "$mode" in
      ok)        printf '{"AccessKeyId":"%s","SecretAccessKey":"%s"}\n' "$FAKE_ID" "$FAKE_SECRET" ;;
      notjson)   printf 'garbage-%s\n' "$FAKE_SECRET" ;;
      missing)   printf '{"SecretAccessKey":"%s"}\n' "$FAKE_SECRET" ;;
    esac
    exit 0
  fi
fi
echo "An error occurred (ResourceNotFoundException) when calling the operation: Secrets Manager can't find the specified secret." >&2
exit 254
SHIM
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH" FAKE_ID FAKE_SECRET

pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
clean() { # $1 = captured output file, $2 = label
  if grep -qF -- "$FAKE_SECRET" "$1" || grep -qF -- "$FAKE_ID" "$1"; then bad "$2: output leaked secret material"; else ok "$2: output carries no secret material"; fi
}

echo "export-diag-key.test"

# 1. Green happy path.
OUT="$WORK/out/pocketdj-diag-key.pdjdiagkey"
if FAKE_AWS_MODE=ok bash "$SCRIPT" --out "$OUT" >"$WORK/log1" 2>&1; then ok "green export exits 0"; else bad "green export exits 0"; cat "$WORK/log1"; fi
clean "$WORK/log1" "green export"
[[ -f "$OUT" ]] && ok "file written" || bad "file written"
mode=$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT")
[[ "$mode" == "600" ]] && ok "file mode 0600" || bad "file mode 0600 (got $mode)"
if python3 -I - "$OUT" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["type"] == "pocketdj-diag-key", d["type"]
assert d["schemaVersion"] == 1
assert d["env"] == "green" and d["account"] == "623170744161"
assert d["accessKeyID"] == os.environ["FAKE_ID"] and d["secret"] == os.environ["FAKE_SECRET"]
assert set(d) == {"type","schemaVersion","env","account","accessKeyID","secret","exportedAt"}, sorted(d)
PY
then ok "file has the app's import shape"; else bad "file has the app's import shape"; fi
[[ ! -e "$OUT.tmp" ]] && ok "no temp file left behind" || bad "no temp file left behind"

# 2. Blue has no diag secret → error, no file.
OUTB="$WORK/out/blue.pdjdiagkey"
if bash "$SCRIPT" --env blue --out "$OUTB" >"$WORK/log2" 2>&1; then bad "--env blue errors when absent"; else ok "--env blue errors when absent"; fi
grep -q "no blue diag-writer secret" "$WORK/log2" && ok "--env blue says why" || bad "--env blue says why"
[[ ! -e "$OUTB" ]] && ok "--env blue writes nothing" || bad "--env blue writes nothing"

# 3. Malformed secrets fail WITHOUT echoing the value.
for m in notjson missing; do
  OUTM="$WORK/out/$m.pdjdiagkey"
  if FAKE_AWS_MODE=$m bash "$SCRIPT" --out "$OUTM" >"$WORK/log-$m" 2>&1; then bad "$m secret fails"; else ok "$m secret fails"; fi
  clean "$WORK/log-$m" "$m secret"
  [[ ! -e "$OUTM" ]] && ok "$m secret writes nothing" || bad "$m secret writes nothing"
done

# 4. Bad --env value.
if bash "$SCRIPT" --env purple --out "$WORK/x" >"$WORK/log4" 2>&1; then bad "unknown --env rejected"; else ok "unknown --env rejected"; fi

echo "export-diag-key.test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
