# PocketDJ audio indexer — runs librosa in a clean linux stack.
# (macOS arm64 pip wheels for scipy/numpy segfault in librosa's CQT/beat paths; a
#  linux/aarch64 container has working wheels and matches the future cloud server.)
FROM python:3.11-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libsndfile1 \
 && rm -rf /var/lib/apt/lists/*

# Force single-threaded BLAS/OpenMP/numba per process. We parallelize at the ALBUM
# level (one subprocess per album), and concurrent fresh-python numpy imports otherwise
# race during OpenBLAS thread-pool init and SEGFAULT under load.
ENV OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMBA_NUM_THREADS=1 \
    VECLIB_MAXIMUM_THREADS=1

# Pin numpy<2 for numba/librosa compatibility; let pip resolve the rest.
RUN pip install --no-cache-dir "numpy<2" "librosa==0.11.0" soundfile scipy

COPY audio_index.py /app/audio_index.py
WORKDIR /app
ENTRYPOINT ["python", "audio_index.py"]
