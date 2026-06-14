#!/usr/bin/env bash
# Run the PocketDJ AUDIO indexer (segment + BPM + key) — parallelism via N isolated
# Docker CONTAINERS, each single-threaded over a disjoint round-robin shard.
#
# Why containers, not in-process threads: librosa/numpy/OpenBLAS segfault under in-process
# concurrency on this stack (concurrent cold numpy imports race on BLAS thread-pool init).
# At concurrency 1 it's rock-solid, so we get throughput by running several one-at-a-time
# containers in parallel (separate process namespaces → no shared-BLAS race). The external
# USB drive's read bandwidth caps useful parallelism around 3 (benchmarked).
#
# Each container copies an album to a /tmp work dir, segments, runs BPM+key, then DELETES
# the copy + segments (bounded disk; never touches ~/Downloads, which Docker can't read on
# macOS). Idempotent + resumable: re-running skips albums already in its shard's part file.
#
#   scripts/audio-index.sh                  # AUDIO_CONC parallel containers (default 3)
#   AUDIO_CONC=4 scripts/audio-index.sh     # tune parallelism (throughput vs host load)
#   scripts/audio-index.sh --limit 5        # smoke test (per-shard limit)
#   scripts/audio-index.sh --top-db 26 --min-gap 0.8   # tune segmentation
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=${AUDIO_IMAGE:-pocketdj-audio}
VINYL_DIR=${VINYL_DIR:-/Volumes/RipBurnMix}
WORK_DIR=${WORK_DIR:-/tmp/pdj-audio-work}
SHARDS=${AUDIO_CONC:-3}
INDEX=${AUDIO_INDEX:-index-out/current/index.json}
OUT=${AUDIO_OUT:-index-out/shards-pw/audio.jsonl}
PARTDIR=index-out/shards-pw/audio-parts

mkdir -p "$WORK_DIR" "$PARTDIR" "$(dirname "$OUT")"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" .claude/skills/analog-indexer/audio

echo "▶ audio indexing · $SHARDS parallel containers (single-threaded each) · vinyl=$VINYL_DIR"
pids=()
for k in $(seq 0 $((SHARDS - 1))); do
  docker run --rm \
    -v "$VINYL_DIR:/vinyl:ro" \
    -v "$WORK_DIR:/work" \
    -v "$(pwd)/index-out:/data" \
    "$IMAGE" \
    --index "/data/${INDEX#index-out/}" \
    --vinyl-dir /vinyl \
    --out "/data/shards-pw/audio-parts/audio.shard-$k.jsonl" \
    --work-dir /work --concurrency 1 --shard "$k" --num-shards "$SHARDS" \
    "$@" >"/tmp/pdj-audio-shard-$k.log" 2>&1 &
  pids+=($!)
done

fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done

# Merge shard part files -> audio.jsonl (last record per albumId wins).
node -e '
const fs=require("fs"),path=require("path");
const dir="index-out/shards-pw/audio-parts";
const m=new Map();
for(const f of fs.readdirSync(dir).filter(x=>/\.jsonl$/.test(x)))
  for(const l of fs.readFileSync(path.join(dir,f),"utf8").split("\n").filter(Boolean)){try{const r=JSON.parse(l);if(r.albumId)m.set(r.albumId,l)}catch{}}
let ok=0,bad=0; for(const l of m.values()){try{JSON.parse(l).ok?ok++:bad++}catch{}}
fs.writeFileSync("index-out/shards-pw/audio.jsonl",[...m.values()].join("\n")+(m.size?"\n":""));
console.log(`merged ${m.size} albums (${ok} ok / ${bad} failed) -> index-out/shards-pw/audio.jsonl`);
'
echo "✓ audio indexing pass complete (shards exit code $fail)"
