// Migration repoint — the regression guard for a bug this code shipped once.
//
// The first version of scripts/migrate-am-artifacts.sh rewrote `librarySnapshot` on EVERY
// change-set, archived ones included. That did two bad things at once:
//   1. it un-pinned the snapshots the archive referenced — retention pins "a snapshot that some
//      change-set still names", so with every pointer moved to the newest file nothing
//      referenced the older ones and the next sweep deleted them; and
//   2. it left the archive claiming an export it was never generated against.
//
// Both halves are asserted here, against the real script.
//
//   node scripts/test/am-artifacts-migration.test.mjs

import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrate-am-artifacts.sh')
let pass = 0
const t = (name, fn) => {
  const box = mkdtempSync(join(tmpdir(), 'pdj-migrate-'))
  try { fn(box); pass++; console.log(`  ok  ${name}`) }
  catch (e) { console.error(`  FAIL  ${name}\n        ${e.message}`); process.exitCode = 1 }
  finally { rmSync(box, { recursive: true, force: true }) }
}

/** A fake ~/Downloads with two snapshots, one active change-set, and an archived one. */
function seed(box) {
  const dl = join(box, 'Downloads')
  const processed = join(dl, 'pocketdj-am-processed')
  mkdirSync(processed, { recursive: true })
  const oldSnap = join(dl, 'pocketdj-am-library-1000.xml')
  const newSnap = join(dl, 'pocketdj-am-library-2000.xml')
  writeFileSync(oldSnap, 'june export')
  writeFileSync(newSnap, 'august export')
  // Not ours — must survive untouched.
  writeFileSync(join(dl, 'Library.xml'), 'the user export')
  writeFileSync(join(dl, 'djpocketsearch-credentials.json'), '{}')
  // Active change-set, generated against the newest snapshot.
  writeFileSync(join(dl, 'pocketdj-am-changeset-2000.json'),
                JSON.stringify({ librarySnapshot: newSnap, added: ['sng_2'] }))
  // Archived change-set, generated against the JUNE snapshot.
  writeFileSync(join(processed, 'pocketdj-am-changeset-1000.json'),
                JSON.stringify({ librarySnapshot: oldSnap, added: ['sng_1'] }))
  return { dl, root: join(box, 'PocketDJ') }
}

const run = (dl, root, ...args) => execFileSync('bash', [SCRIPT, ...args], {
  env: { ...process.env, POCKETDJ_DOWNLOADS_DIR: dl, POCKETDJ_AM_ARTIFACT_DIR: root,
         POCKETDJ_AM_SNAPSHOT_DIR: join(root, 'snapshots.nosync') },
  encoding: 'utf8',
})

const readJSON = (p) => JSON.parse(readFileSync(p, 'utf8'))

console.log('am-artifacts migration')

t('a dry run moves nothing', (box) => {
  const { dl, root } = seed(box)
  run(dl, root)
  assert.ok(existsSync(join(dl, 'pocketdj-am-library-2000.xml')), 'snapshot stays put')
  assert.ok(existsSync(join(dl, 'pocketdj-am-changeset-2000.json')), 'change-set stays put')
  assert.ok(!existsSync(join(root, 'snapshots.nosync', 'pocketdj-am-library-2000.xml')))
})

t('the ARCHIVE is not repointed at the retained snapshot', (box) => {
  const { dl, root } = seed(box)
  const original = join(dl, 'pocketdj-am-library-1000.xml')
  run(dl, root, '--apply')
  const archived = readJSON(join(root, 'processed', 'pocketdj-am-changeset-1000.json'))
  const kept = join(root, 'snapshots.nosync', 'pocketdj-am-library-2000.xml')
  // THE regression assertion. Repointing this at `kept` is the bug that shipped once.
  assert.notEqual(archived.librarySnapshot, kept,
    'an archived change-set must never claim an export it was not generated against')
  // The migration does not delete, so the June snapshot it names is still there — leaving the
  // pointer alone is the accurate answer, not a missed rewrite.
  assert.equal(archived.librarySnapshot, original, 'a pointer that still resolves is left alone')
  assert.deepEqual(archived.added, ['sng_1'], 'the audit content is untouched')
})

t('an archived pointer whose snapshot is GONE is flagged, not redirected', (box) => {
  const { dl, root } = seed(box)
  // Simulate re-running the migration after the old snapshots have been reclaimed.
  rmSync(join(dl, 'pocketdj-am-library-1000.xml'))
  run(dl, root, '--apply')
  const archived = readJSON(join(root, 'processed', 'pocketdj-am-changeset-1000.json'))
  assert.equal(archived.librarySnapshot, null, 'a dangling pointer is recorded as absent')
  assert.ok(archived.librarySnapshotMissing, 'the original path is preserved for the record')
  assert.deepEqual(archived.added, ['sng_1'], 'the audit content survives either way')
})

t('the ACTIVE change-set is repointed at the moved snapshot', (box) => {
  const { dl, root } = seed(box)
  run(dl, root, '--apply')
  const active = readJSON(join(root, 'pocketdj-am-changeset-2000.json'))
  assert.equal(active.librarySnapshot,
    join(root, 'snapshots.nosync', 'pocketdj-am-library-2000.xml'),
    'the active pointer follows the file, or a consumer hard-fails on it')
})

t('the newest snapshot is retained with a hash sidecar', (box) => {
  const { dl, root } = seed(box)
  run(dl, root, '--apply')
  const snaps = readdirSync(join(root, 'snapshots.nosync')).sort()
  assert.deepEqual(snaps, ['pocketdj-am-library-2000.xml', 'pocketdj-am-library-2000.xml.sha256'],
    'the sidecar is what makes the next sync reuse instead of copying 157 MB')
})

t('files that are not ours are never touched', (box) => {
  const { dl, root } = seed(box)
  run(dl, root, '--apply')
  assert.equal(readFileSync(join(dl, 'Library.xml'), 'utf8'), 'the user export',
    'the manual Music.app export stays in Downloads, untouched')
  assert.ok(existsSync(join(dl, 'djpocketsearch-credentials.json')))
})

t('older snapshots are left in place for an explicit later step', (box) => {
  const { dl, root } = seed(box)
  run(dl, root, '--apply')
  assert.ok(existsSync(join(dl, 'pocketdj-am-library-1000.xml')),
    'the migration moves; it never deletes')
})

console.log(`\n${pass} passed`)
