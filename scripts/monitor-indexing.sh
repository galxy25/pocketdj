#!/usr/bin/env bash
# monitor-indexing.sh — watches enrich-playwright.mjs and keeps INDEXING_STATUS.md current.
# Runs as a detached loop; updates the status file every ~120 seconds until the run ends.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG="$PROJECT_ROOT/index-out/pw-progress.log"
SHARDS_DIR="$PROJECT_ROOT/index-out/shards-pw"
STATUS_FILE="$PROJECT_ROOT/index-out/INDEXING_STATUS.md"
MERGE_CMD="node .claude/skills/analog-indexer/lib/cli.mjs merge index-out/shards-pw --out-dir index-out/full --source Vinyl.md --lines 1366 --vinyl 1366"

# Convert an ISO-8601 UTC timestamp (2026-06-13T19:49:43.330Z) to epoch seconds.
# Works on both macOS (BSD date) and Linux (GNU date).
iso_to_epoch() {
  local ts="${1%%.*}"  # strip fractional seconds: "2026-06-13T19:49:43"
  ts="${ts%Z}"          # strip trailing Z if present
  local epoch
  # Try BSD date (macOS)
  if epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null); then
    echo "$epoch"
  # Try GNU date
  elif epoch=$(date -d "${ts}Z" +%s 2>/dev/null); then
    echo "$epoch"
  else
    echo 0
  fi
}

count_shards() {
  local n
  n=$(find "$SHARDS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "${n:-0}"
}

write_status() {
  local now_ts
  now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')

  # ── Parse the progress log ────────────────────────────────────────────────
  local all_enriched
  all_enriched=$(grep -E '^enriched [0-9]+/[0-9]+ matched=[0-9]+ at ' "$LOG" 2>/dev/null || true)

  local done=0 total=1366 matched=0
  if [[ -n "$all_enriched" ]]; then
    local last_line
    last_line=$(echo "$all_enriched" | tail -1)
    done=$(echo  "$last_line" | awk '{print $2}' | cut -d'/' -f1)
    total=$(echo "$last_line" | awk '{print $2}' | cut -d'/' -f2)
    matched=$(echo "$last_line" | awk '{print $3}' | cut -d'=' -f2)
  fi

  # Guard against empty/corrupt reads
  [[ "$done"    =~ ^[0-9]+$ ]] || done=0
  [[ "$total"   =~ ^[0-9]+$ ]] || total=1366
  [[ "$matched" =~ ^[0-9]+$ ]] || matched=0

  # ── Percent complete ───────────────────────────────────────────────────────
  local pct=0
  if (( total > 0 )); then
    pct=$(awk "BEGIN {printf \"%.1f\", ($done/$total)*100}")
  fi

  # ── Match rate ─────────────────────────────────────────────────────────────
  local match_rate="0.0%"
  if (( done > 0 )); then
    match_rate=$(awk "BEGIN {printf \"%.1f%%\", ($matched/$done)*100}")
  fi

  # ── Throughput: use last ≤5 enriched lines ────────────────────────────────
  local rate_per_min="0.00" eta_str="unknown" eta_abs="unknown"
  local window_lines
  window_lines=$(echo "$all_enriched" | tail -5)
  local line_count
  line_count=$(echo "$window_lines" | grep -c '^enriched' 2>/dev/null || true)
  [[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0

  if (( line_count >= 2 )); then
    local first_line last_win_line
    first_line=$(echo "$window_lines" | head -1)
    last_win_line=$(echo "$window_lines" | tail -1)

    local first_done first_ts last_done last_ts
    first_done=$(echo "$first_line"    | awk '{print $2}' | cut -d'/' -f1)
    first_ts=$(echo   "$first_line"    | awk '{print $5}')
    last_done=$(echo  "$last_win_line" | awk '{print $2}' | cut -d'/' -f1)
    last_ts=$(echo    "$last_win_line" | awk '{print $5}')

    local first_epoch last_epoch
    first_epoch=$(iso_to_epoch "$first_ts")
    last_epoch=$(iso_to_epoch "$last_ts")

    local delta_albums delta_secs
    delta_albums=$(( last_done - first_done ))
    delta_secs=$(( last_epoch - first_epoch ))

    if (( delta_secs > 0 && delta_albums > 0 )); then
      rate_per_min=$(awk "BEGIN {printf \"%.2f\", ($delta_albums / $delta_secs) * 60}")
      local remaining=$(( total - done ))
      local eta_secs
      eta_secs=$(awk "BEGIN {printf \"%d\", ($remaining * $delta_secs / $delta_albums)}")

      local eta_h=$(( eta_secs / 3600 ))
      local eta_m=$(( (eta_secs % 3600) / 60 ))
      eta_str="~${eta_h}h ${eta_m}m"

      local now_epoch finish_epoch
      now_epoch=$(date +%s)
      finish_epoch=$(( now_epoch + eta_secs ))
      if eta_abs=$(date -r "$finish_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null); then
        : # BSD date succeeded
      elif eta_abs=$(date -d "@$finish_epoch" '+%Y-%m-%d %H:%M %Z' 2>/dev/null); then
        : # GNU date succeeded
      else
        eta_abs="unknown"
      fi
    fi
  fi

  # ── Process & shard status ────────────────────────────────────────────────
  local proc_status="running"
  if ! pgrep -f enrich-playwright.mjs >/dev/null 2>&1; then
    if (( done >= total && total > 0 )); then
      proc_status="finished"
    else
      proc_status="stopped (process gone)"
    fi
  fi

  local shard_count
  shard_count=$(count_shards)

  # ── Write the markdown ────────────────────────────────────────────────────
  cat > "$STATUS_FILE" <<EOF
# PocketDJ Indexing Status

**Last updated:** $now_ts

## Progress
- Done: **$done / $total** ($pct%)

## Match quality
- Matched: **$matched** of $done processed
- Match rate: **$match_rate**

## Throughput & ETA
- Rate: **$rate_per_min albums/min** (based on last $line_count checkpoints)
- ETA: **$eta_str** (approx. $eta_abs)

## Run status
- Process: **$proc_status**
- Shard files written: **$shard_count**

## How to merge when done
\`\`\`
$MERGE_CMD
\`\`\`

## How to check progress
- This file: \`cat index-out/INDEXING_STATUS.md\`
- Live tail:  \`tail -f index-out/pw-progress.log\`
EOF
}

write_final_status() {
  local now_ts
  now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')

  local all_enriched
  all_enriched=$(grep -E '^enriched [0-9]+/[0-9]+ matched=[0-9]+ at ' "$LOG" 2>/dev/null || true)

  local done=0 total=1366 matched=0
  if [[ -n "$all_enriched" ]]; then
    local last_line
    last_line=$(echo "$all_enriched" | tail -1)
    done=$(echo  "$last_line" | awk '{print $2}' | cut -d'/' -f1)
    total=$(echo "$last_line" | awk '{print $2}' | cut -d'/' -f2)
    matched=$(echo "$last_line" | awk '{print $3}' | cut -d'=' -f2)
  fi

  [[ "$done"    =~ ^[0-9]+$ ]] || done=0
  [[ "$total"   =~ ^[0-9]+$ ]] || total=1366
  [[ "$matched" =~ ^[0-9]+$ ]] || matched=0

  local unmatched=$(( done - matched ))
  local match_rate="0.0%"
  if (( done > 0 )); then
    match_rate=$(awk "BEGIN {printf \"%.1f%%\", ($matched/$done)*100}")
  fi

  local shard_count
  shard_count=$(count_shards)

  cat > "$STATUS_FILE" <<EOF
# PocketDJ Indexing — FINAL SUMMARY

**Completed:** $now_ts

## Results
- Total processed: **$done / $total**
- Matched: **$matched** ($match_rate)
- Unmatched: **$unmatched**
- Shard files: **$shard_count**

## Merge command
\`\`\`
$MERGE_CMD
\`\`\`
EOF
  echo "[monitor] Run complete. Final status written to $STATUS_FILE"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "[monitor] Starting. Status file: $STATUS_FILE"
echo "[monitor] Poll interval: 120s"
cd "$PROJECT_ROOT"

while true; do
  write_status

  # Parse current done/total to check completion
  local_done=0
  local_total=1366
  local_last=$(grep -E '^enriched [0-9]+/[0-9]+ matched=[0-9]+ at ' "$LOG" 2>/dev/null | tail -1 || true)
  if [[ -n "$local_last" ]]; then
    local_done=$(echo "$local_last" | awk '{print $2}' | cut -d'/' -f1)
    local_total=$(echo "$local_last" | awk '{print $2}' | cut -d'/' -f2)
    [[ "$local_done"  =~ ^[0-9]+$ ]] || local_done=0
    [[ "$local_total" =~ ^[0-9]+$ ]] || local_total=1366
  fi

  # Done? Write final and exit.
  if (( local_done >= local_total && local_total > 0 )); then
    write_final_status
    exit 0
  fi

  # Process gone and not done?
  if ! pgrep -f enrich-playwright.mjs >/dev/null 2>&1; then
    echo "[monitor] Process gone before completion ($local_done/$local_total). Writing final status."
    write_final_status
    exit 0
  fi

  echo "[monitor] $(date '+%H:%M:%S') — $local_done/$local_total done. Sleeping 120s…"
  sleep 120
done
