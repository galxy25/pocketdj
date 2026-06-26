#!/usr/bin/env bash
# Provision the PocketDJ STEM indexer (Demucs) on the host, idempotently. Mirrors
# audio-index.sh's build guard. The rip server's /stemify* endpoints need this to have
# run once before they can separate anything.
#
# Two runtimes (one knob, POCKETDJ_DEMUCS_RUNTIME):
#   native (default) — a host venv using Apple MPS. The FAST path on the M-series iMac.
#   docker           — the pocketdj-stems CPU image. Portable / CI fallback (minutes/song).
#
# Either way the default weights are PRE-WARMED so the first real separation runs offline
# (an uncached torch-hub download mid-run would break the durable-queue guarantee).
#
#   scripts/stems-index.sh                              # native venv + MPS (default)
#   POCKETDJ_DEMUCS_RUNTIME=docker scripts/stems-index.sh
#   POCKETDJ_DEMUCS_MODEL=hdemucs_mmi scripts/stems-index.sh   # v3 fallback model
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${POCKETDJ_STEM_IMAGE:-pocketdj-stems:latest}
VENV=${POCKETDJ_STEM_VENV:-$HOME/.pocketdj/.venv-stems}
MODEL=${POCKETDJ_DEMUCS_MODEL:-htdemucs}
RUNTIME=${POCKETDJ_DEMUCS_RUNTIME:-native}

if [ "$RUNTIME" = docker ]; then
  echo "▶ provisioning stems (docker) · image=$IMAGE · model=$MODEL"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || docker build --build-arg STEM_MODEL="$MODEL" -t "$IMAGE" .claude/skills/analog-indexer/stems
  echo "✓ docker image ready ($IMAGE)"
else
  echo "▶ provisioning stems (native venv + MPS) · venv=$VENV · model=$MODEL"
  [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  # torch/torchaudio resolve to the newest arm64 wheels with MPS; demucs pinned for htdemucs.
  "$VENV/bin/pip" install --quiet "demucs==4.0.1" torch torchaudio
  # pre-warm the default weights so the first real run is offline + idempotent
  "$VENV/bin/python" -c "from demucs.pretrained import get_model; get_model('$MODEL')"
  echo "✓ native venv ready ($VENV) — weights for '$MODEL' warmed"
fi
