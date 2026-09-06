#!/bin/bash
# Deploy the STEM worker: push the current worker code to the `worker-code/` S3 prefix that
# `stem-worker-userdata.sh` copies from on every boot. The golden AMI carries only the heavy deps
# (demucs/torch/node/ffmpeg), so a code change is exactly this `aws s3 cp` — never an AMI re-bake.
#
#   bash scripts/stem-deploy-worker.sh          push the worker + its python helpers, then VERIFY
#   bash scripts/stem-deploy-worker.sh --check  verify what is deployed; push nothing, exit 1 on drift
#
# WHY THIS EXISTS. Until now the stem lane had no deploy script (the timbre lane has
# `timbre-deploy-worker.sh`) and the ad-hoc `aws s3 cp` lived only in someone's shell history — so
# `worker-code/stem-worker.mjs` drifted a month behind the repo with nothing saying so. That was
# survivable while the workers were on-demand and the drift was a refactor. It stops being
# survivable on SPOT: the interruption handling (`armSpotWatch` / `releaseInflight` / the IMDS
# `spot/instance-action` poll) lives in `stem-worker.mjs`, so an un-deployed worker means every
# reclaim strands its job for the full 1800 s visibility timeout AND spends one of the queue's three
# deliveries. Three unlucky reclaims dead-letter a song that never failed, and `pumpStemDlq()` marks
# it errored for good.
#
# VERIFY MEANS READ THE BYTES BACK — `aws s3 cp`'s exit code is not verification. A 0 says the
# request was accepted, not that a booting worker will read what we meant to ship: a push to the
# wrong prefix, a stale object from a half-finished earlier deploy, or a local tree that is itself
# spot-blind all exit 0. So every file is downloaded again and compared byte-for-byte with its
# source, and the READ-BACK stem-worker.mjs must carry the whole interruption path.
#
# TWO INDEPENDENT GUARDS AGAINST THE ROLLOUT RACE, and they check different things on purpose.
#
#   1. `stem-autoscaler.mjs` gates ITSELF: before requesting spot it reads the deployed object's
#      BODY (ETag-cached, so the download is rare) and refuses to ask for spot unless the marker
#      `spot/instance-action` is in it. That guard needs nothing from this script — it works even
#      if the worker was deployed by hand — which is exactly why it is the one that gates.
#   2. This script writes `x-amz-meta-spot-aware=yes` as a PROVENANCE record: which tree was
#      deployed (sha256) and when. `stem-spot-setup.mjs --status` reads it with a single HEAD, so
#      an operator's preflight costs no download, and a missing stamp says "nobody verified these
#      bytes" even when the body happens to be fine.
#
# The ORDER below is what makes the stamp mean anything:
#
#   1. upload with NO metadata  → a plain PUT replaces the object AND its user metadata, so the
#                                 stamp is CLEARED by the upload itself. Until step 3 the object
#                                 carries no claim at all.
#   2. read back + compare      → the marker check runs on the bytes S3 will actually serve.
#   3. stamp, only on success   → a metadata-only self-copy. Nothing else in the repo writes it.
#
# So the stamp can only ever be written by a deploy that already proved itself. It is allowed to
# UNDER-claim — a hand-run `aws s3 cp` sets no metadata, so a perfectly good worker reads as
# "unverified" until this script re-deploys it — and it must never OVER-claim, which is why a
# failed verification leaves the object bare rather than stamped. Both guards fail toward
# on-demand; neither can fail open.
#
# The marker set below is a strict SUPERSET of the autoscaler's single `spot/instance-action`.
# Deliberate: a worker that satisfies this script always satisfies the autoscaler, so the deploy
# gate can only ever be the tighter of the two.
#
# ORDER IS LOAD-BEARING AT THE FLEET LEVEL TOO: deploy the worker BEFORE the autoscaler starts
# asking for spot. Running this first is always safe — the spot code is inert on an on-demand
# instance (IMDS answers 404 forever, `armSpotWatch` logs and stands down).
#
# The python helpers live under .claude/skills/analog-indexer/ (one copy, shared with the local
# indexer path) and are FLATTENED into worker-code/ because userdata fetches them by bare name.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-levi}"
BUCKET=pocketdj-rips-011183829623
PREFIX=worker-code
B="s3://$BUCKET/$PREFIX"
R="--region us-west-2 --only-show-errors"

# source:remote-name. The remote name is the BARE name userdata fetches; the cross-check below
# asserts this list still covers everything `stem-worker-userdata.sh` asks for.
FILES=(
  "scripts/stem-worker.mjs:stem-worker.mjs"
  "scripts/transcribe-one.py:transcribe-one.py"
  ".claude/skills/analog-indexer/stems/separate-one.py:separate-one.py"
  ".claude/skills/analog-indexer/audio/analyze-one.py:analyze-one.py"
  ".claude/skills/analog-indexer/audio/analyze-beatgrid.py:analyze-beatgrid.py"
)

# What "spot-aware" means, in ONE place. All three must be present: the IMDS path alone also matches
# the comment that explains it, and a marker set that a rename can satisfy by accident is not a
# guard. Erring strict is deliberate — a false negative blocks a deploy loudly and costs a minute,
# a false positive ships a spot-blind fleet and dead-letters songs that never failed.
SPOT_MARKERS=('spot/instance-action' 'armSpotWatch' 'releaseInflight')

spot_aware() {   # spot_aware <file> — 0 only if EVERY marker is present
  local f="$1" m
  # -F: fixed strings. `spot/instance-action` is a literal, not a pattern, and a marker that
  # quietly behaved as a regex would be a guard nobody could reason about.
  for m in "${SPOT_MARKERS[@]}"; do grep -qF -- "$m" "$f" || return 1; done
}

# Every file the boot script fetches from the worker-code prefix. Derived from the userdata itself
# rather than restated here: the failure this catches is a new `aws s3 cp $B/foo.py` landing in
# userdata while FILES above is forgotten, which boots a worker that dies on a missing helper —
# and does so only on the NEXT launch, long after the commit that caused it.
userdata_expects() {
  grep -oE '\$B/[A-Za-z0-9._-]+' scripts/stem-worker-userdata.sh | sed 's|^\$B/||' | sort -u
}

rc=0
for pair in "${FILES[@]}"; do
  [ -f "${pair%%:*}" ] || { echo "!! missing source ${pair%%:*}" >&2; rc=1; }
done
[ $rc -eq 0 ] || exit 1

deployed_names=$(printf '%s\n' "${FILES[@]}" | sed 's|^.*:||' | sort -u)
missing_from_files=$(comm -23 <(userdata_expects) <(printf '%s\n' "$deployed_names"))
if [ -n "$missing_from_files" ]; then
  echo "!! stem-worker-userdata.sh fetches files this script never deploys:" >&2
  printf '     %s\n' $missing_from_files >&2
  echo "   Add them to FILES, or a booting worker will fail on a missing helper." >&2
  exit 1
fi

# Download every deployed object ONCE into a temp dir, then run all checks against local files.
# Never `aws s3 cp - | grep -q`: with `set -o pipefail`, grep -q exits at the first match, aws takes
# SIGPIPE, and the pipeline reports FAILURE on a file that matched perfectly well. Whether that
# happens depends on whether the object fits the 64 KB pipe buffer — so the bug stays invisible
# until the worker grows, then starts reporting a spot-aware deploy as spot-blind.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# verify_files — read every object back and compare with its source, then assert the read-back
# worker carries the interruption path. Sets rc=1 on any drift. Used identically by --check
# (before) and by the deploy path (after), so what a deploy asserts and what an operator can ask
# are the same test rather than two that can drift apart.
verify_files() {
  local pair src remote
  for pair in "${FILES[@]}"; do
    src="${pair%%:*}"; remote="${pair##*:}"
    if aws s3 cp "$B/$remote" "$T/$remote" $R 2>/dev/null; then
      if cmp -s "$src" "$T/$remote"; then echo "  same      $remote"
      else echo "  DRIFTED   $remote  (deployed differs from $src)"; rc=1; fi
    else
      echo "  MISSING   $remote  (never deployed)"; rc=1
    fi
  done
  # The spot markers, checked on the bytes S3 serves — not on the working tree, which is exactly
  # the thing that can be ahead of the fleet.
  if [ -f "$T/stem-worker.mjs" ] && spot_aware "$T/stem-worker.mjs"; then
    echo "  spot watch: PRESENT in the deployed worker"
  else
    echo "  spot watch: ABSENT from the deployed worker — reclaims would strand jobs for the full"
    echo "              visibility timeout and burn deliveries toward the DLQ. Deploy before spot."
    rc=1
  fi
}

# report_stamp — the provenance record, kept separate from verify_files because the two answer
# different questions: the markers say what the deployed bytes ARE, the stamp says whether a
# verified deploy vouched for them and from which tree. A spot-aware body with no stamp is the
# hand-`cp` case — correct code, no proof. The autoscaler would still allow spot there (it reads
# the body itself); what is missing is the audit trail, so this reports it without pretending the
# fleet is blocked.
report_stamp() {
  local stamp
  stamp=$(aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/stem-worker.mjs" \
    --query 'Metadata."spot-aware"' --output text --region us-west-2 2>/dev/null || echo None)
  if [ "$stamp" = "yes" ]; then
    echo "  spot stamp: x-amz-meta-spot-aware=yes — a verified deploy vouched for these bytes"
  else
    echo "  spot stamp: ABSENT — these bytes were never verified by this script (hand-deployed?)."
    echo "              Re-run without --check to deploy + verify + stamp."
    rc=1
  fi
}

if [ "${1:-}" = "--check" ]; then
  verify_files
  report_stamp
  exit $rc
fi
if [ $# -gt 0 ]; then
  echo "usage: stem-deploy-worker.sh [--check]" >&2; exit 2
fi

# Refuse to ship a spot-blind worker in the first place. Catching it here — before the upload that
# clears the stamp — leaves the currently-deployed object and its stamp untouched, so a mistaken
# deploy from a stale branch cannot take the fleet off spot on its way to failing.
if ! spot_aware scripts/stem-worker.mjs; then
  echo "!! scripts/stem-worker.mjs is missing the spot interruption path (${SPOT_MARKERS[*]})." >&2
  echo "   Refusing to deploy: the fleet runs on spot and this worker could not handle a reclaim." >&2
  exit 1
fi

for pair in "${FILES[@]}"; do
  src="${pair%%:*}"; remote="${pair##*:}"
  aws s3 cp "$src" "$B/$remote" $R
  echo "  pushed $src -> $B/$remote"
done

# Post-condition, not a hope. The stamp is deliberately NOT consulted here: the PUT above cleared
# it, and it is re-earned below only if this passes.
echo "verifying read-back from S3…"
verify_files
if [ $rc -ne 0 ]; then
  echo "!! read-back verification FAILED — the deployed worker is NOT what this tree holds." >&2
  echo "   The spot-aware stamp was NOT written, so stem-autoscaler.mjs will stay on-demand." >&2
  echo "   Investigate before launching anything." >&2
  exit 1
fi

# EARNED: stamp the object now that its bytes are proven. Metadata-only self-copy — the body is
# already correct and re-uploading it would re-open the unproven window for no reason.
# ContentType is passed through explicitly because REPLACE drops every header it is not given, and
# the bucket has ObjectOwnership=BucketOwnerEnforced (ACLs disabled), so there is no object ACL for
# this copy to lose — public reads come from the bucket policy, which a copy does not touch.
SHA=$(shasum -a 256 scripts/stem-worker.mjs | awk '{print $1}')
AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aws s3api copy-object --bucket "$BUCKET" --key "$PREFIX/stem-worker.mjs" \
  --copy-source "$BUCKET/$PREFIX/stem-worker.mjs" \
  --metadata-directive REPLACE --content-type text/javascript \
  --metadata "spot-aware=yes,sha256=$SHA,deployed-at=$AT" \
  --region us-west-2 --output json > /dev/null

STAMP=$(aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/stem-worker.mjs" \
  --query 'Metadata."spot-aware"' --output text --region us-west-2 2>/dev/null || echo None)
if [ "$STAMP" != "yes" ]; then
  echo "!! the spot-aware stamp did not land (read back: $STAMP). The BYTES are correct and the" >&2
  echo "   fleet is safe — the autoscaler verifies the body itself — but the provenance record is" >&2
  echo "   missing, so 'stem-spot-setup.mjs --status' will keep reporting it as unverified." >&2
  exit 1
fi
# Paranoia that has already paid for itself once: confirm the stamping self-copy did not disturb the
# body. copy-object is metadata-only here, but "should not" is not "did not", and the whole point of
# this script is that the fleet reads what we think it reads.
aws s3 cp "$B/stem-worker.mjs" "$T/post-stamp.mjs" $R
if ! cmp -s scripts/stem-worker.mjs "$T/post-stamp.mjs"; then
  echo "!! the body CHANGED during the metadata self-copy — do not launch; investigate." >&2
  exit 1
fi

echo "==> verified: worker-code/stem-worker.mjs matches scripts/stem-worker.mjs, carries the spot"
echo "    interruption path, and is stamped spot-aware=yes (sha256 ${SHA:0:12}…, $AT)."
echo "==> Done. Workers pick this up on their NEXT boot; instances already running keep their old code."
