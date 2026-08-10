#!/usr/bin/env bash
# Resolve EVERY id the explicit-edition feature needs, end to end, unattended.
#
# Levi 2026-08-08: "we should resolve all ids but only need to rip on demand" and
# "hold off on the bulk rerip until all ids are resolved". So this chain is the gate on
# the bulk re-rip — it must finish before scripts/rerip-collection-editions.mjs runs for
# real, and nothing here enqueues a single rip.
#
# STRICTLY SEQUENTIAL, deliberately: all three stages rewrite
# public/apple-music-index.json wholesale (atomic tmp+rename). Two of them running at once
# would not corrupt the file, but the second writer would silently drop the first's work —
# the same class of loss the am-sync forward-merge exists to prevent.
#
#   stage 1  wait out the explicit crawl already in flight
#   stage 2  resolve-apple-music-catalog  — fill appleMusicId where it is missing. The
#            lookup route walks song -> artistId -> explicit album, so a song with no
#            catalog id has no starting point and is UNREACHABLE until this runs. That is
#            ~20,700 songs, 14,375 of them flagged explicit: the dominant blocker.
#   stage 3  resolve-explicit-lookup --all — second pass, now that stage 2 gave those
#            songs an id to walk from.
#
# Every stage is independently resumable from its own cache, so killing this script loses
# at most the in-flight request. Re-run it and it picks up.
set -u
cd "$(dirname "$0")/.." || exit 1
LOG_DIR=index-out/apple-music
mkdir -p "$LOG_DIR"
CHAIN_LOG="$LOG_DIR/resolve-all-ids-chain.log"

say() { printf '\n=== %s :: %s ===\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$CHAIN_LOG"; }

counts() {
  node -e '
    const d=require("fs").readFileSync("public/apple-music-index.json","utf8");
    const s=JSON.parse(d).songs;
    const ex=s.filter(x=>x.explicit);
    console.error(`    songs ${s.length} | with catalog id ${s.filter(x=>x.appleMusicId).length}`
      + ` | explicit-flagged ${ex.length} | of those WITH an explicit id ${ex.filter(x=>x.appleMusicIdExplicit).length}`);
  ' 2>&1 | tee -a "$CHAIN_LOG"
}

say "chain start"; counts

# ── stage 1: wait for whatever explicit crawl is already running ─────────────────────
if pgrep -f 'resolve-explicit-[l]ookup' >/dev/null; then
  say "stage 1 — waiting for the in-flight explicit crawl"
  while pgrep -f 'resolve-explicit-[l]ookup' >/dev/null; do sleep 60; done
fi
say "stage 1 done"; counts

# ── stage 2: catalog ids for songs that have NONE (fast, certain) ────────────────────
# --only-missing-id is load-bearing: without it the resolver ALSO re-crawls every song
# whose cache has a storeId but no collectionId (69,915 here vs 3,264 that genuinely lack
# an id) — 3.4x the network for a field the explicit route never reads, and it would have
# delayed the ids Levi actually asked for by well over a day.
say "stage 2 — catalog ids for the 3.2k songs with none (~2h)"
node scripts/resolve-apple-music-catalog.mjs --only-missing-id --delay-ms 2000 >> "$LOG_DIR/catalog-ids.log" 2>&1
say "stage 2 exit=$?"; counts

# ── stage 3: explicit editions over the newly-reachable songs ────────────────────────
say "stage 3 — resolve-explicit-lookup --all"
node scripts/resolve-explicit-lookup.mjs --all --delay-ms 2000 >> "$LOG_DIR/explicit-lookup-all.log" 2>&1
say "stage 3 exit=$?"; counts

# ── stage 4: the long tail — retry songs iTunes Search failed on before ──────────────
# ~17k cached MISSES: songs a previous run looked for and could not match. Lower yield
# than stage 2 by construction, which is exactly why it runs AFTER the certain wins and
# after stage 3 has already banked them.
say "stage 4 — retry the cached misses (long tail, lower yield)"
node scripts/resolve-apple-music-catalog.mjs --retry-misses --only-missing-id --delay-ms 2000 >> "$LOG_DIR/catalog-ids.log" 2>&1
say "stage 4 exit=$?"; counts

# ── stage 5: final explicit pass over anything stage 4 unlocked ──────────────────────
say "stage 5 — final resolve-explicit-lookup --all"
node scripts/resolve-explicit-lookup.mjs --all --delay-ms 2000 >> "$LOG_DIR/explicit-lookup-all.log" 2>&1
say "stage 5 exit=$?"; counts

say "CHAIN COMPLETE — ids resolved; the bulk re-rip gate is now open (still dry-run by default)"
