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
sudo -u ubuntu aws s3 cp $B/stem-worker.mjs  /home/ubuntu/stem-worker.mjs  --region us-west-2 --only-show-errors
sudo -u ubuntu aws s3 cp $B/separate-one.py  /home/ubuntu/separate-one.py  --region us-west-2 --only-show-errors
sudo -u ubuntu env \
  POCKETDJ_STEM_DEVICE=cpu \
  POCKETDJ_STEM_IDLE_SECONDS=120 \
  POCKETDJ_STEM_POLL_SECONDS=10 \
  /usr/bin/node /home/ubuntu/stem-worker.mjs --serve
echo "=== worker retired; terminating $(date -u) ==="
shutdown -h now
