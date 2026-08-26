#!/bin/bash
# Deploy the CLOUD TIMBRE worker: push the current code + the CALIBRATED docker image to the
# worker-code S3 prefix the launch template boots from. Same idiom as the stem lane's
# `aws s3 cp` deploy — no AMI re-bake, no ECR repository, no `docker login` at boot.
#
#   bash scripts/timbre-deploy-worker.sh            code only (fast)
#   bash scripts/timbre-deploy-worker.sh --image    code + re-export the ~360 MB image tarball
#
# The image tarball is the exact image that measured the existing corpus, NOT a rebuild from the
# Dockerfile — see scripts/timbre-worker-userdata.sh for why that distinction is load-bearing.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-levi}"
B=s3://pocketdj-rips-011183829623/worker-code
R="--region us-west-2 --only-show-errors"
aws s3 cp scripts/timbre-worker.mjs                                  $B/timbre-worker.mjs      $R
aws s3 cp scripts/timbre-batch.mjs                                   $B/timbre-batch.mjs       $R
aws s3 cp scripts/timbre-warm-worker.py                              $B/timbre-warm-worker.py  $R
aws s3 cp scripts/lib/audio-analyze.mjs                              $B/audio-analyze.mjs      $R
aws s3 cp .claude/skills/analog-indexer/audio/analyze-timbre.py      $B/analyze-timbre.py      $R
if [ "${1:-}" = "--image" ]; then
  T=$(mktemp -d)
  docker save pocketdj-audio:latest | gzip -1 > "$T/img.tgz"
  aws s3 cp "$T/img.tgz" $B/pocketdj-audio-arm64.tgz $R
  rm -rf "$T"
fi
# THE FINGERPRINT the worker asserts against. NOT the image ID: an image ID is the digest of the
# image CONFIG, and a `docker save` → `docker load` round-trip legitimately rewrites that config
# (Docker Desktop's containerd store and Docker CE serialize it differently), so an ID check fails
# on an image whose contents are bit-identical — it did, on the first boot of this template.
# RootFS.Layers are diff_ids: content addresses of the UNCOMPRESSED layers, i.e. the actual
# filesystem librosa runs from. Config.Env rides along because the five *_NUM_THREADS vars are on
# the numeric path (a multi-threaded BLAS changes reduction order, and therefore the low bits).
docker image inspect pocketdj-audio:latest \
  --format '{"layers":{{json .RootFS.Layers}},"env":{{json .Config.Env}},"arch":"{{.Architecture}}","os":"{{.Os}}"}' \
  > /tmp/pdj-audio-fp.json
aws s3 cp /tmp/pdj-audio-fp.json $B/pocketdj-audio-arm64.fingerprint.json $R
rm -f /tmp/pdj-audio-fp.json
echo "==> Done"
