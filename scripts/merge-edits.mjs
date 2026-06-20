#!/usr/bin/env node
// merge-edits — fold a client-exported edits document back into the main index.
//
// This is the SERVER (iMac) half of the metadata-edit round-trip. The native
// app's Settings ▸ Edits ▸ Export writes a versioned `EditsDocument` (see
// apple/PocketDJ/Models/EditSchema.swift). This tool applies those per-item field
// overrides onto a `current-index.json`, in place or to --out, so a subsequent
// `scripts/deploy.sh` republishes them to the read-only S3/CloudFront index that
// every client reads.
//
//   node scripts/merge-edits.mjs --edits pocketdj-edits.json \
//        --index public/current-index.json [--out merged.json] [--dry-run]
//
// Contract (MUST stay in sync with EditSchema.swift):
//   EditsDocument = { schemaVersion:int, albums:{[albumId]:AlbumEdit}, songs:{[songId]:SongEdit}, meta?:{} }
//   AlbumEdit = { name?, artist?, genre?, year?, country? }              // all optional
//   SongEdit  = { name?, artist?, year?, trackNumber?, bpm?, key?, camelot?, explicit?, sentimentKeywords?[] }
//
// Semantics:
//   • Only PRESENT (non-undefined) edit fields override; absent fields are left
//     untouched (deltas). This mirrors the client's `applying(_:)` overlay.
//   • Keyed by stable content-derived ids (alb_… / sng_…) → an edit applies to the
//     same item on every device.
//   • Idempotent: re-running with the same edits yields the same index.
//   • Version-safe: a newer schemaVersion is tolerated (known fields applied,
//     unknown ignored); an older one is accepted as-is (fields are additive-only).
import fs from 'node:fs';

const SUPPORTED_SCHEMA = 1;
const ALBUM_FIELDS = ['name', 'artist', 'genre', 'year', 'country'];
const SONG_FIELDS = ['name', 'artist', 'year', 'trackNumber', 'bpm', 'key', 'camelot', 'explicit', 'sentimentKeywords'];

function parseArgs(argv) {
  const out = { dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--edits') out.edits = argv[++i];
    else if (a === '--index') out.index = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    else if (a === '--dry-run') out.dryRun = true;
    else if (a === '-h' || a === '--help') out.help = true;
    else { console.error(`Unknown arg: ${a}`); out.help = true; }
  }
  return out;
}

function usage() {
  console.log(`merge-edits — apply a client edits export onto the index.

  node scripts/merge-edits.mjs --edits <edits.json> --index <index.json> [--out <file>] [--dry-run]

  --edits     EditsDocument JSON exported from a PocketDJ client (required)
  --index     index.json to merge into (e.g. public/current-index.json) (required)
  --out       write merged index here (default: overwrite --index)
  --dry-run   report what WOULD change; write nothing`);
}

/** Apply present edit fields onto an index item; returns the # of fields changed. */
function applyEdit(item, edit, fields) {
  let changed = 0;
  for (const f of fields) {
    if (edit[f] === undefined || edit[f] === null) continue; // absent ⇒ no override
    const next = edit[f];
    if (JSON.stringify(item[f]) !== JSON.stringify(next)) { item[f] = next; changed++; }
  }
  return changed;
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help || !args.edits || !args.index) { usage(); process.exit(args.help ? 0 : 2); }

  const doc = JSON.parse(fs.readFileSync(args.edits, 'utf8'));
  const index = JSON.parse(fs.readFileSync(args.index, 'utf8'));

  const version = doc.schemaVersion ?? 0;
  if (version > SUPPORTED_SCHEMA) {
    console.warn(`⚠︎ edits schemaVersion ${version} is newer than supported (${SUPPORTED_SCHEMA}); applying known fields only.`);
  } else if (version < SUPPORTED_SCHEMA) {
    console.warn(`ℹ︎ edits schemaVersion ${version} < ${SUPPORTED_SCHEMA}; fields are additive-only, applying as-is.`);
  }

  const albumById = new Map((index.albums ?? []).map((a) => [a.id, a]));
  const songById = new Map((index.songs ?? []).map((s) => [s.id, s]));

  let albumsChanged = 0, songsChanged = 0, fieldsChanged = 0, unknown = 0;
  for (const [id, edit] of Object.entries(doc.albums ?? {})) {
    const item = albumById.get(id);
    if (!item) { console.warn(`  · unknown album ${id} (skipped)`); unknown++; continue; }
    const n = applyEdit(item, edit, ALBUM_FIELDS);
    if (n) { albumsChanged++; fieldsChanged += n; }
  }
  for (const [id, edit] of Object.entries(doc.songs ?? {})) {
    const item = songById.get(id);
    if (!item) { console.warn(`  · unknown song ${id} (skipped)`); unknown++; continue; }
    const n = applyEdit(item, edit, SONG_FIELDS);
    if (n) { songsChanged++; fieldsChanged += n; }
  }

  console.log(`✓ merged: ${albumsChanged} album(s), ${songsChanged} song(s), ${fieldsChanged} field(s) changed`
    + (unknown ? `; ${unknown} unknown id(s) skipped` : ''));

  if (args.dryRun) { console.log('(dry-run: nothing written)'); return; }
  const outPath = args.out ?? args.index;
  fs.writeFileSync(outPath, JSON.stringify(index, null, 2) + '\n');
  console.log(`→ wrote ${outPath}`);
  if (fieldsChanged) console.log('Next: redeploy the index — scripts/deploy.sh <dev|prod>');
}

main();
