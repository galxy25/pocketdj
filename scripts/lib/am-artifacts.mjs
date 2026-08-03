// am-artifacts — where the Apple Music sync's audit artifacts live, and when they expire.
//
// WHY THIS EXISTS. `runAmCheck` writes two files per detected change: a 157 MB copy of the
// library export, and a ~230 KB change-set describing what it found. Neither is an input to
// anything that runs today — the detection cursor is a 322-byte state.json, and the indexer
// takes a Date-Added `--since`, never an export-to-export diff. Their only reader,
// scripts/am-sync-agent.sh, was never installed. So the pile grew to 17 snapshots / 2.6 GB in
// ~/Downloads, all 17 byte-identical to the export they were copied from.
//
// WHERE THINGS GO. Change-sets are small and are exactly the "what did that sync do?" record
// you want after a bad sync, so they go somewhere visible: ~/Documents/PocketDJ. Snapshots are
// 157 MB each and go in a `.nosync` subdirectory — ~/Documents is iCloud Drive-backed on this
// machine (files there already carry the `dataless` placeholder flag), and `*.nosync` is the
// documented CloudDocs exclusion convention. Without it, retained snapshots would upload to
// iCloud and could be evicted to placeholders that a launchd process must re-download to read.
//
// THE SAFETY PROPERTY. A file is deleted only when EVERY guard agrees:
//
//     drop  ⇔  rank >= keepNewest  AND  age > minAgeMs  AND  not referenced
//
// It is a conjunction, so any single guard vetoes the delete — age is never the sole predicate.
// `referenced` pins any snapshot a surviving change-set still points at, so the retained
// change-sets always remain replayable.

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const expand = (p) => p.replace(/^~/, homedir())

/** Root for the sync's audit artifacts. Override with POCKETDJ_AM_ARTIFACT_DIR. */
export function artifactRoot() {
  return expand(process.env.POCKETDJ_AM_ARTIFACT_DIR
    || join(homedir(), 'Documents', 'PocketDJ'))
}

/**
 * Where the bulk library snapshots go. Separate from the root ON PURPOSE: the `.nosync`
 * suffix keeps 157 MB files out of iCloud Drive. Override with POCKETDJ_AM_SNAPSHOT_DIR.
 */
export function snapshotDir() {
  return expand(process.env.POCKETDJ_AM_SNAPSHOT_DIR
    || join(artifactRoot(), 'snapshots.nosync'))
}

/** Archive of change-sets an agent has already applied (the idempotency ledger). */
export function processedDir() {
  return join(artifactRoot(), 'processed')
}

export function ensureDirs() {
  for (const d of [artifactRoot(), snapshotDir(), processedDir()]) mkdirSync(d, { recursive: true })
}

const HOUR = 3600_000

/**
 * Retention policy, per directory + filename pattern. `keepNewest` files always survive
 * regardless of age; beyond that a file must ALSO be older than `minAgeMs`.
 *
 * The user's ask was "the last 2 days of changes is fine, but not an ever-expanding set" —
 * hence 48 h, with a newest-N floor so a quiet fortnight can't leave you with nothing.
 */
export const POLICY = [
  { dir: snapshotDir, re: /^pocketdj-am-library-(\d+)\.xml$/, keepNewest: 1, minAgeMs: 48 * HOUR },
  { dir: artifactRoot, re: /^pocketdj-am-changeset-(\d+)\.json$/, keepNewest: 3, minAgeMs: 48 * HOUR },
  { dir: processedDir, re: /^pocketdj-am-library-(\d+)\.xml$/, keepNewest: 0, minAgeMs: 48 * HOUR },
  { dir: processedDir, re: /^pocketdj-am-changeset-(\d+)\.json$/, keepNewest: 30, minAgeMs: 720 * HOUR },
]

/**
 * Every snapshot path referenced by a change-set that still exists. A change-set pins its
 * snapshot by ABSOLUTE path (`librarySnapshot`), and a consumer hard-fails on a missing one —
 * so a retained change-set must never outlive the snapshot it names.
 */
function referencedSnapshots() {
  const pinned = new Set()
  for (const dir of [artifactRoot(), processedDir()]) {
    if (!existsSync(dir)) continue
    for (const name of readdirSync(dir)) {
      if (!/^pocketdj-am-changeset-\d+\.json$/.test(name)) continue
      try {
        const doc = JSON.parse(readFileSync(join(dir, name), 'utf8'))
        if (doc?.librarySnapshot) pinned.add(String(doc.librarySnapshot))
      } catch { /* an unreadable change-set pins nothing; it is itself prunable */ }
    }
  }
  return pinned
}

/**
 * Apply the policy. Returns the list of {path, bytes, reason} it removed (or WOULD remove in
 * dry mode) so the caller can log a real number rather than "cleaned up".
 *
 * POCKETDJ_AM_RETENTION: 'on' (default) | 'dry' (report only) | 'off' (no-op).
 */
export function pruneArtifacts({ now = Date.now(), dry = null } = {}) {
  const mode = process.env.POCKETDJ_AM_RETENTION || 'on'
  if (mode === 'off') return []
  const dryRun = dry ?? mode === 'dry'
  const pinned = referencedSnapshots()
  const removed = []

  for (const rule of POLICY) {
    const dir = rule.dir()
    if (!existsSync(dir)) continue
    // Rank by the epoch-ms IN THE NAME, not mtime: a move/copy rewrites mtime, and the name is
    // the only stamp that survives migration.
    const files = readdirSync(dir)
      .map((name) => ({ name, m: rule.re.exec(name) }))
      .filter((f) => f.m)
      .map((f) => ({ name: f.name, path: join(dir, f.name), stamp: Number(f.m[1]) }))
      .sort((a, b) => b.stamp - a.stamp)

    files.forEach((f, rank) => {
      if (rank < rule.keepNewest) return                      // newest-N floor
      let age
      try { age = now - statSync(f.path).mtimeMs } catch { return }
      if (age <= rule.minAgeMs) return                        // inside the window
      if (pinned.has(f.path)) return                          // a surviving change-set needs it
      let bytes = 0
      try { bytes = statSync(f.path).size } catch { /* ignore */ }
      if (!dryRun) {
        try { unlinkSync(f.path) } catch { return }
      }
      removed.push({ path: f.path, bytes, reason: `rank ${rank} >= keep ${rule.keepNewest}, age ${Math.round(age / HOUR)}h` })
    })
  }

  if (removed.length) {
    const mb = (removed.reduce((n, r) => n + r.bytes, 0) / 1e6).toFixed(1)
    console.error(`  am-artifacts: ${dryRun ? 'WOULD reclaim' : 'reclaimed'} ${mb} MB across ${removed.length} file(s)`)
  }
  return removed
}
