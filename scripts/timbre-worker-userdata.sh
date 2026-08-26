#!/bin/bash
# Launch-template boot script for a PocketDJ CLOUD TIMBRE worker (arm64 / AL2023).
#
# Unlike the stem worker there is NO golden AMI and NO pip install: the analysis environment is
# the pocketdj-audio DOCKER IMAGE, shipped as a `docker save` tarball of the EXACT image that
# measured the existing 12,395 vectors. A rebuild from the Dockerfile would NOT be the same
# calibration — it pins only librosa==0.11.0, while scipy/soundfile/numba/llvmlite/soxr/audioread
# all float, and every one of them sits on the numeric path (soxr resamples 44.1k→22.05k,
# libsndfile decodes the mp3, scipy provides the FFT/DCT, numba JITs the onset kernels).
# The image DIGEST is asserted below; a mismatch shuts the instance down rather than analysing
# with an unverified stack. The instance launches with InstanceInitiatedShutdownBehavior=terminate,
# so `shutdown -h now` = terminate = scale-to-0.
#
# THE BOOT LOG IS SHIPPED TO S3 ON EXIT (worker-logs/<instance>.log). A worker that dies during
# boot terminates itself, taking /var/log with it and leaving an EMPTY EC2 console — the first
# boot of this template failed exactly that way and was undiagnosable until the log shipped.
LOG=/var/log/timbre-worker.log
exec >> $LOG 2>&1
set -x
IID=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
      | { read -r T; curl -sf http://169.254.169.254/latest/meta-data/instance-id -H "X-aws-ec2-metadata-token: $T"; })
ship() { aws s3 cp $LOG "s3://pocketdj-rips-011183829623/worker-logs/${IID:-unknown}.log" --region us-west-2 --only-show-errors || true; }
trap ship EXIT
echo "=== timbre worker boot $(date -u) instance=$IID ==="

# DEAD-MAN SWITCH, armed BEFORE anything can hang. Scale-to-zero here is not an autoscaler
# decision — it is this instance shutting itself down when serve() returns — so ANY path that
# never returns bills a c7g.2xlarge indefinitely: a wedged docker/python round-trip, a dnf that
# hangs on a mirror, an S3 copy with no progress. There is no ASG and no max-instance-lifetime
# behind this template to catch it. `shutdown -h +N` is scheduled in the background and is
# superseded by the `shutdown -h now` at the end of a healthy run, so a normal worker never sees
# it; a wedged one terminates anyway. N is generously above a real run (idle-exit is 120 s and a
# batch is minutes), so it can only ever fire on a fault.
shutdown -h "+${POCKETDJ_TIMBRE_MAX_LIFETIME_MIN:-360}" "pdj timbre worker max lifetime" || true

dnf install -y docker || yum install -y docker
dnf install -y nodejs20 || dnf install -y nodejs || dnf install -y nodejs18
NODE=$(command -v node || command -v node-20 || echo /usr/bin/node)
"$NODE" --version || { echo "FATAL no node"; shutdown -h now; exit 1; }
systemctl enable --now docker

B=s3://pocketdj-rips-011183829623/worker-code
H=/home/ec2-user/pdj
mkdir -p $H/scripts/lib $H/.claude/skills/analog-indexer/audio
# The worker runs the SAME driver + engine the local corpus was measured with, at the SAME
# relative paths (timbre-batch.mjs derives both from its own location), so a code change is an
# `aws s3 cp` — never an AMI re-bake, and a boot can never run stale baked code.
aws s3 cp $B/timbre-worker.mjs       $H/scripts/timbre-worker.mjs                              --region us-west-2 --only-show-errors
aws s3 cp $B/timbre-batch.mjs        $H/scripts/timbre-batch.mjs                               --region us-west-2 --only-show-errors
aws s3 cp $B/timbre-warm-worker.py   $H/scripts/timbre-warm-worker.py                          --region us-west-2 --only-show-errors
aws s3 cp $B/audio-analyze.mjs       $H/scripts/lib/audio-analyze.mjs                          --region us-west-2 --only-show-errors
aws s3 cp $B/analyze-timbre.py       $H/.claude/skills/analog-indexer/audio/analyze-timbre.py  --region us-west-2 --only-show-errors
chown -R ec2-user:ec2-user $H

# Load the calibrated image and PROVE it is the one that measured the corpus.
aws s3 cp $B/pocketdj-audio-arm64.tgz              /tmp/img.tgz --region us-west-2 --only-show-errors
aws s3 cp $B/pocketdj-audio-arm64.fingerprint.json /tmp/fp.json --region us-west-2 --only-show-errors
gunzip -c /tmp/img.tgz | docker load
rm -f /tmp/img.tgz
# Assert CONTENT identity, not the image ID: a save/load round-trip rewrites the image config
# (and therefore the ID) while the layers are bit-identical. RootFS.Layers are diff_ids — content
# addresses of the uncompressed filesystem librosa actually runs from — and Config.Env carries the
# five *_NUM_THREADS vars that sit on the numeric path. Those two are what "the same stack" means.
WANT=$(python3 -c 'import json;d=json.load(open("/tmp/fp.json"));print(json.dumps([d["layers"],sorted(d["env"]),d["arch"],d["os"]]))')
GOT=$(docker image inspect pocketdj-audio:latest --format '{"layers":{{json .RootFS.Layers}},"env":{{json .Config.Env}},"arch":"{{.Architecture}}","os":"{{.Os}}"}' \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps([d["layers"],sorted(d["env"]),d["arch"],d["os"]]))')
if [ "$WANT" != "$GOT" ]; then
  echo "FATAL image fingerprint mismatch — refusing to analyse"
  echo "  want=$WANT"
  echo "  got =$GOT"
  shutdown -h now
  exit 1
fi
echo "image fingerprint verified (layers+env+arch match the calibrated image)"
usermod -aG docker ec2-user

sudo -u ec2-user env \
  POCKETDJ_TIMBRE_SHARDS="${POCKETDJ_TIMBRE_SHARDS:-8}" \
  POCKETDJ_TIMBRE_IDLE_SECONDS=120 \
  AWS_REGION=us-west-2 \
  "$NODE" $H/scripts/timbre-worker.mjs --serve
echo "=== worker retired; terminating $(date -u) ==="
ship
shutdown -h now
