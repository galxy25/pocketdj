// Retention policy tests — the POLICY, not the plumbing.
//
// The property that matters is negative: the prune must never delete something a later step
// needs. So most of these assert that a file SURVIVES.
//
//   node scripts/test/am-artifacts-retention.test.mjs

import { mkdtempSync, mkdirSync, writeFileSync, readdirSync, utimesSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'

const HOUR = 3600_000
let pass = 0
const t = (name, fn) => {
  const root = mkdtempSync(join(tmpdir(), 'pdj-retention-'))
  const snaps = join(root, 'snapshots.nosync')
  const processed = join(root, 'processed')
  mkdirSync(snaps, { recursive: true }); mkdirSync(processed, { recursive: true })
  process.env.POCKETDJ_AM_ARTIFACT_DIR = root
  process.env.POCKETDJ_AM_SNAPSHOT_DIR = snaps
  delete process.env.POCKETDJ_AM_RETENTION
  try {
    fn({ root, snaps, processed })
    pass++
    console.log(`  ok  ${name}`)
  } catch (e) {
    console.error(`  FAIL  ${name}\n        ${e.message}`)
    process.exitCode = 1
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

/** Write a file and backdate its mtime by `ageHours`. */
const put = (dir, name, body, ageHours) => {
  const p = join(dir, name)
  writeFileSync(p, body)
  const when = (Date.now() - ageHours * HOUR) / 1000
  utimesSync(p, when, when)
  return p
}
const snapName = (ms) => `pocketdj-am-library-${ms}.xml`
const csName = (ms) => `pocketdj-am-changeset-${ms}.json`
const ls = (d) => readdirSync(d).sort()

// A fresh import each time so the module re-reads the env-derived paths.
const load = () => import(`../lib/am-artifacts.mjs?${Math.random()}`)

console.log('am-artifacts retention')

const run = async () => {
  const { pruneArtifacts } = await load()

  t('newest snapshot survives even when ancient', ({ snaps }) => {
    put(snaps, snapName(1000), 'a', 5000)
    pruneArtifacts()
    assert.deepEqual(ls(snaps), [snapName(1000)], 'the only snapshot must survive')
  })

  t('older snapshots go once past the window', ({ snaps }) => {
    put(snaps, snapName(1000), 'old', 100)
    put(snaps, snapName(2000), 'mid', 100)
    put(snaps, snapName(3000), 'new', 100)
    pruneArtifacts()
    assert.deepEqual(ls(snaps), [snapName(3000)], 'keepNewest=1 keeps only the newest')
  })

  t('a snapshot INSIDE the 48h window survives even when out-ranked', ({ snaps }) => {
    put(snaps, snapName(1000), 'old', 1)   // 1 hour old
    put(snaps, snapName(2000), 'new', 1)
    pruneArtifacts()
    assert.deepEqual(ls(snaps), [snapName(1000), snapName(2000)], 'age guard vetoes the delete')
  })

  t('a snapshot PINNED by a surviving change-set is never deleted', ({ root, snaps }) => {
    const pinned = put(snaps, snapName(1000), 'old', 500)
    put(snaps, snapName(9000), 'new', 500)
    // A recent change-set still points at the OLD snapshot. Rank and age both say drop it;
    // the reference guard must override both, or the change-set becomes unreplayable.
    put(root, csName(9000), JSON.stringify({ librarySnapshot: pinned }), 1)
    pruneArtifacts()
    assert.ok(ls(snaps).includes(snapName(1000)), 'pinned snapshot must survive rank+age')
  })

  t('keeps the newest 3 change-sets', ({ root }) => {
    for (const ms of [1000, 2000, 3000, 4000, 5000]) put(root, csName(ms), '{}', 100)
    pruneArtifacts()
    assert.deepEqual(ls(root).filter((f) => f.startsWith('pocketdj-am-changeset')),
      [csName(3000), csName(4000), csName(5000)])
  })

  t('POCKETDJ_AM_RETENTION=off is a true no-op', ({ snaps }) => {
    for (const ms of [1000, 2000, 3000]) put(snaps, snapName(ms), 'x', 500)
    process.env.POCKETDJ_AM_RETENTION = 'off'
    const removed = pruneArtifacts()
    delete process.env.POCKETDJ_AM_RETENTION
    assert.equal(removed.length, 0)
    assert.equal(ls(snaps).length, 3, 'nothing removed when off')
  })

  t('dry mode reports without deleting', ({ snaps }) => {
    for (const ms of [1000, 2000, 3000]) put(snaps, snapName(ms), 'x', 500)
    const removed = pruneArtifacts({ dry: true })
    assert.equal(removed.length, 2, 'reports the two it would drop')
    assert.equal(ls(snaps).length, 3, 'but deletes nothing')
  })

  t('ignores files that do not match the pattern', ({ root, snaps }) => {
    put(snaps, 'Library.xml', 'the user export', 5000)
    put(snaps, 'notes.txt', 'x', 5000)
    put(root, 'djpocketsearch-credentials.json', '{}', 5000)
    pruneArtifacts()
    assert.ok(ls(snaps).includes('Library.xml'), 'a bare Library.xml is never matched')
    assert.ok(ls(snaps).includes('notes.txt'))
    assert.ok(ls(root).includes('djpocketsearch-credentials.json'))
  })

  t('ranks by the stamp in the NAME, not mtime (migration rewrites mtime)', ({ snaps }) => {
    // The migration moves files, which touches mtime — so a freshly-moved OLD snapshot must
    // still rank as old, or a move could make the wrong file look newest.
    put(snaps, snapName(1000), 'old-but-just-moved', 0)
    put(snaps, snapName(5000), 'genuinely newest', 100)
    pruneArtifacts()
    assert.ok(ls(snaps).includes(snapName(5000)), 'highest stamp is the keeper')
  })

  console.log(`\n${pass} passed`)
}

run()
