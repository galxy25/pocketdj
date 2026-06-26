# PocketDJ STEM indexer — Demucs (htdemucs default). SEPARATE image from pocketdj-audio:
# torch+demucs are heavy and would conflict with the numpy<2/librosa pin. A container on
# macOS is CPU-ONLY (Docker Desktop's linux VM has no Metal/MPS passthrough) — this is the
# portable / CI fallback path; the native host venv (scripts/stems-index.sh) is the fast
# MPS path on the Apple-Silicon iMac.
FROM python:3.11-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
 && rm -rf /var/lib/apt/lists/*

# CPU-only torch wheels (no MPS inside a linux container anyway). Let pip resolve the
# torch/torchaudio pair the demucs pin needs.
RUN pip install --no-cache-dir torch torchaudio --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir "demucs==4.0.1"

# Bake the default weights into the image so runs are OFFLINE + IDEMPOTENT (an uncached
# torch-hub download mid-run would break the durable-queue guarantee). Override the model
# at build time for a v3 fallback image:
#   docker build --build-arg STEM_MODEL=hdemucs_mmi -t pocketdj-stems:hdemucs_mmi .
ENV TORCH_HOME=/opt/torch
ARG STEM_MODEL=htdemucs
RUN python -c "from demucs.pretrained import get_model; get_model('${STEM_MODEL}')"

# Do NOT pin OMP/OPENBLAS *_NUM_THREADS=1 like the librosa image: demucs benefits from
# multi-core and the stem queue is concurrency-1 (no in-process BLAS race to guard against).
COPY separate-one.py /app/separate-one.py
WORKDIR /app
ENTRYPOINT ["python", "separate-one.py"]
