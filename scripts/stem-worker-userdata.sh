#!/bin/bash
# Launch-template boot script for a PocketDJ stem worker. Baked expectations (golden AMI):
# node at /usr/bin/node, the worker at /home/ubuntu/stem-worker.mjs + separate-one.py, and a
# python venv at /home/ubuntu/venv-stems with demucs installed. The instance launches with
# InstanceInitiatedShutdownBehavior=terminate, so `shutdown -h now` below = terminate = scale-to-0.
exec >> /var/log/stem-worker.log 2>&1
echo "=== stem worker boot $(date -u) ==="
cd /home/ubuntu
# Pull the CURRENT worker code from S3 — the AMI carries only the heavy deps (demucs/torch/node),
# so a code change is just an `aws s3 cp`, never a re-bake, and boots can't run stale baked code.
B=s3://pocketdj-rips-011183829623/worker-code
sudo -u ubuntu aws s3 cp $B/stem-worker.mjs      /home/ubuntu/stem-worker.mjs      --region us-west-2 --only-show-errors
sudo -u ubuntu aws s3 cp $B/separate-one.py      /home/ubuntu/separate-one.py      --region us-west-2 --only-show-errors
sudo -u ubuntu aws s3 cp $B/analyze-one.py       /home/ubuntu/analyze-one.py       --region us-west-2 --only-show-errors
sudo -u ubuntu aws s3 cp $B/analyze-beatgrid.py  /home/ubuntu/analyze-beatgrid.py  --region us-west-2 --only-show-errors
sudo -u ubuntu aws s3 cp $B/transcribe-one.py    /home/ubuntu/transcribe-one.py    --region us-west-2 --only-show-errors
# librosa for the analysis task, faster-whisper for the lyrics task. Idempotent + fast when already
# present (becomes a no-op once baked into the AMI). soundfile/audioread give librosa its mp3 loader
# (ffmpeg is installed). faster-whisper downloads its CTranslate2 model from HuggingFace on the FIRST
# lyrics job (workers have outbound internet) — accepted for now; bake the model into the AMI later.
sudo -u ubuntu /home/ubuntu/venv-stems/bin/pip install -q librosa soundfile audioread faster-whisper 2>&1 | tail -1
sudo -u ubuntu env \
  POCKETDJ_STEM_DEVICE=cpu \
  POCKETDJ_STEM_IDLE_SECONDS=120 \
  POCKETDJ_STEM_POLL_SECONDS=10 \
  /usr/bin/node /home/ubuntu/stem-worker.mjs --serve
echo "=== worker retired; terminating $(date -u) ==="
shutdown -h now
