#!/usr/bin/env bash
# Regression test: deploy.sh must refuse a REC_ENROLL_SECRETS list that drops the secret compiled
# into Config.swift (shipped iOS clients never read the endpoints doc). No AWS calls are made
# beyond what aws-env.sh does offline; GUARD_ONLY=1 exits right after the guard.
set -u
D="$(cd "$(dirname "$0")" && pwd)"
C="$(sed -n 's/.*recEngineEnrollSecret = "\([^"]*\)".*/\1/p' "$D/../../../apple/PocketDJ/Support/Config.swift" | head -1)"
[ -n "$C" ] || { echo "FAIL: could not read compiled secret"; exit 1; }
fail=0
GUARD_ONLY=1 REC_ENROLL_SECRETS="brand-new-secret-0123456789abcdef" bash "$D/deploy.sh" >/dev/null 2>&1 && { echo "FAIL: single new secret accepted"; fail=1; }
GUARD_ONLY=1 REC_ENROLL_SECRETS="$C,brand-new-secret-0123456789abcdef" bash "$D/deploy.sh" >/dev/null 2>&1 || { echo "FAIL: old,new rejected"; fail=1; }
GUARD_ONLY=1 REC_ENROLL_SECRETS="brand-new-secret-0123456789abcdef" bash "$D/deploy.sh" --force-drop-compiled >/dev/null 2>&1 || { echo "FAIL: force flag ignored"; fail=1; }
[ $fail = 0 ] && echo "deploy guard tests passed"; exit $fail
