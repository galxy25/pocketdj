#!/usr/bin/env node
// Self-test for the explicit-variant matcher (scripts/lib/explicit-variants.mjs) and the
// edition-aware am-match extensions. No deps, no network:  node scripts/test-explicit-variants.mjs
// Exits non-zero on any failure.
import { classifyExplicitness, findEditions } from './lib/explicit-variants.mjs';
import { loadLibraryXML, indexLibrary, findInLibrary } from './lib/am-match.mjs';
import { collectionSongIds } from './resolve-explicit-variants.mjs';
import { writeFileSync, readFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

let failures = 0;
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { console.log(`  ✓ ${label}`); return; }
  failures++;
  console.error(`  ✗ ${label}\n      expected ${e}\n      actual   ${a}`);
}

// ---------------- classifyExplicitness ----------------
console.log('classifyExplicitness');
eq(classifyExplicitness('explicit'), 'explicit', "'explicit' -> explicit");
eq(classifyExplicitness('cleaned'), 'clean', "'cleaned' -> clean");
eq(classifyExplicitness('notExplicit'), 'clean', "'notExplicit' -> clean");
eq(classifyExplicitness(undefined), null, 'absent -> null');
eq(classifyExplicitness(''), null, 'empty -> null');

// ---------------- findEditions ----------------
console.log('findEditions');
const song = { id: 'sng_1a7f6bc854af', name: 'Late Night', artist: 'Childish Gambino', length: 289000, albumId: 'alb_1' };

// explicit + clean pair of the SAME recording found; the clean album is "(Clean)" (cosmetic).
{
  const results = [
    { trackId: 111, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Awaken', trackTimeMillis: 289100, trackExplicitness: 'explicit' },
    { trackId: 222, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Awaken (Clean)', trackTimeMillis: 289100, trackExplicitness: 'cleaned' },
  ];
  eq(findEditions(song, 'Awaken', results), { explicitId: '111', cleanId: '222' }, 'explicit+clean pair found; "(Clean)" album matched cosmetically');
}

// remix rejected — comparableTitle disagreement (recording markers must agree).
{
  const results = [
    { trackId: 333, trackName: 'Late Night (Club Mix)', artistName: 'Childish Gambino', collectionName: 'Awaken', trackTimeMillis: 289100, trackExplicitness: 'explicit' },
  ];
  eq(findEditions(song, 'Awaken', results), { explicitId: null, cleanId: null }, 'remix rejected (comparableTitle disagreement)');
}

// duration gate: >7 s off (or unknown) rejects the candidate.
{
  const results = [
    { trackId: 444, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Awaken', trackTimeMillis: 289000 + 8000, trackExplicitness: 'explicit' },
    { trackId: 555, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Awaken', trackExplicitness: 'cleaned' }, // no duration
  ];
  eq(findEditions(song, 'Awaken', results), { explicitId: null, cleanId: null }, 'duration gate rejects >7s and unknown durations');
}

// artist containment passes (feat. spillover).
{
  const results = [
    { trackId: 666, trackName: 'Late Night', artistName: 'Childish Gambino feat. Jaden', collectionName: 'Awaken', trackTimeMillis: 289100, trackExplicitness: 'explicit' },
  ];
  eq(findEditions(song, 'Awaken', results), { explicitId: '666', cleanId: null }, 'artist containment passes');
}

// class-internal scoring: album match (+25) beats a same-class row without it.
{
  const results = [
    { trackId: 777, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Greatest Hits', trackTimeMillis: 289100, trackExplicitness: 'explicit' },
    { trackId: 888, trackName: 'Late Night', artistName: 'Childish Gambino', collectionName: 'Awaken', trackTimeMillis: 289100, trackExplicitness: 'explicit' },
  ];
  eq(findEditions(song, 'Awaken', results), { explicitId: '888', cleanId: null }, 'album-title match wins its class');
}

// ---------------- am-match: boolean Explicit parse + edition-aware findInLibrary ----------------
console.log('am-match edition awareness');
const xml = `<?xml version="1.0"?>
<plist><dict><key>Tracks</key><dict>
<key>100</key>
<dict>
\t<key>Name</key><string>Late Night</string>
\t<key>Artist</key><string>Childish Gambino</string>
\t<key>Album</key><string>Awaken</string>
\t<key>Persistent ID</key><string>AAAA1111</string>
\t<key>Total Time</key><integer>289000</integer>
\t<key>Explicit</key><true/>
</dict>
<key>101</key>
<dict>
\t<key>Name</key><string>Late Night</string>
\t<key>Artist</key><string>Childish Gambino</string>
\t<key>Album</key><string>Awaken (Clean)</string>
\t<key>Persistent ID</key><string>BBBB2222</string>
\t<key>Total Time</key><integer>289000</integer>
</dict>
<key>102</key>
<dict>
\t<key>Name</key><string>Solo Cut</string>
\t<key>Artist</key><string>Aria</string>
\t<key>Persistent ID</key><string>CCCC3333</string>
\t<key>Explicit</key><false/>
</dict>
<key>103</key>
<dict>
\t<key>Name</key><string>Heat</string>
\t<key>Artist</key><string>Vex</string>
\t<key>Persistent ID</key><string>DDDD4444</string>
\t<key>Explicit</key><true/>
</dict>
</dict></dict></plist>`;
const xmlPath = join(tmpdir(), `pdj-test-lib-${process.pid}.xml`);
writeFileSync(xmlPath, xml);
const entries = loadLibraryXML(xmlPath);
rmSync(xmlPath, { force: true });

eq(entries.length, 4, 'XML fixture parses 4 entries');
eq(entries[0].explicit, true, '<key>Explicit</key><true/> parsed');
eq(entries[1].explicit, undefined, 'entry without the tag stays undefined');
eq(entries[2].explicit, false, '<key>Explicit</key><false/> parsed');

const lib = indexLibrary(entries);
// Back-compat: no opts returns the FIRST-inserted entry (old single-entry behavior).
eq(findInLibrary(lib, 'Childish Gambino', 'Late Night').hit?.persistentID, 'AAAA1111', 'no-opts call returns first-inserted (back-compat)');
eq(findInLibrary(lib, 'Childish Gambino', 'Late Night').match, 'exact', 'no-opts match class unchanged');
// Edition-required: pick the right entry from the two-edition set.
eq(findInLibrary(lib, 'Childish Gambino', 'Late Night', { explicitness: 'explicit' }).hit?.persistentID, 'AAAA1111', 'explicitness explicit picks the explicit entry');
eq(findInLibrary(lib, 'Childish Gambino', 'Late Night', { explicitness: 'clean' }).hit?.persistentID, 'BBBB2222', 'explicitness clean picks the clean entry');
// Required edition ABSENT → match MUST be 'none', hit null. NOT merely "not exact":
// the loose matcher never inspects `explicit`, and the rip caller captures any match
// !== 'none' — a loose fall-through would capture wrong-edition audio under the
// variant key (child-safety case). The edition gate is a hard stop.
{
  const r = findInLibrary(lib, 'Aria', 'Solo Cut', { explicitness: 'explicit' });
  eq(r.match, 'none', 'required edition absent -> match none (no loose fall-through)');
  eq(r.hit, null, 'required edition absent -> hit null');
}
// The child-safety direction: library holds ONLY the explicit edition, 'clean' required.
{
  const r = findInLibrary(lib, 'Vex', 'Heat', { explicitness: 'clean' });
  eq(r.match, 'none', 'clean required, only explicit in library -> match none');
  eq(r.hit, null, 'clean required, only explicit in library -> hit null');
}
eq(findInLibrary(lib, 'Aria', 'Solo Cut', { explicitness: 'clean' }).hit?.persistentID, 'CCCC3333', 'clean requirement satisfied by explicit=false entry');
// No-opts loose diagnostics still work (only edition-required lookups hard-stop).
{
  const r = findInLibrary(lib, 'Vex feat. Someone', 'Heat (Live)');
  eq(r.match, 'loose', 'no-opts loose diagnostics unaffected');
}

// ---------------- collection scoping walk ----------------
console.log('collectionSongIds');
{
  const doc = {
    pockets: [
      { id: 'pkt_a', songIds: ['sng_1'], albumIds: ['alb_1'], childPocketIds: ['pkt_b'], songRepeats: { sng_9: 2 } },
      { id: 'pkt_b', songIds: ['sng_2'], childPocketIds: ['pkt_a'] },   // cycle back — must not loop
    ],
    playlists: [
      { id: 'pls_1', sequences: [
        { kind: 'sequence', children: [
          { kind: 'song', songId: 'sng_3' },
          { kind: 'album', albumId: 'alb_2' },
          { kind: 'pocket', pocketId: 'pkt_b' },
          { kind: 'sequence', children: [{ kind: 'song', songId: 'sng_4' }] },
        ] },
      ] },
    ],
    setlists: [{ id: 'set_1', tracks: [{ songId: 'sng_5' }, { songId: '' }] }],
  };
  const albums = new Map([['alb_1', ['sng_6']], ['alb_2', ['sng_7']]]);
  const got = [...collectionSongIds(doc, albums)].filter(Boolean).sort();
  eq(got, ['sng_1', 'sng_2', 'sng_3', 'sng_4', 'sng_5', 'sng_6', 'sng_7', 'sng_9'], 'pocket DAG + playlist walk + setlist tracks, cycle-guarded');
}

// ---------------- am-merge-catalog-ids: variant ids survive a full rebuild ----------------
// The variant crawl stamps appleMusicIdExplicit/Clean into the COMMITTED index only (its
// ndjson cache is gitignored), so the full-rebuild ship path (am-sync-agent / am-sync-deploy)
// MUST forward-merge them or the first changeset ship after the crawl wipes every variant id.
console.log('am-merge-catalog-ids variant carry-forward');
{
  const dir = tmpdir();
  const oldP = join(dir, `pdj-test-merge-old-${process.pid}.json`);
  const newP = join(dir, `pdj-test-merge-new-${process.pid}.json`);
  const outP = join(dir, `pdj-test-merge-out-${process.pid}.json`);
  // OLD (committed) index: crawl output present. NEW (rebuilt): variant fields stripped,
  // one song carries its own fresh values (present-on-new must win — idempotency).
  writeFileSync(oldP, JSON.stringify({ songs: [
    { id: 'sng_1', appleMusicId: '10', appleMusicIdExplicit: '11', appleMusicIdClean: '12', explicit: true },
    { id: 'sng_2', appleMusicId: '20', appleMusicIdClean: '22' },
    { id: 'sng_3' },
  ] }));
  writeFileSync(newP, JSON.stringify({ songs: [
    { id: 'sng_1' },
    { id: 'sng_2', appleMusicIdClean: 'NEW22' },
    { id: 'sng_3' },
    { id: 'sng_4' },
  ], manifest: { counts: {} } }));
  const script = join(dirname(fileURLToPath(import.meta.url)), 'am-merge-catalog-ids.mjs');
  execFileSync(process.execPath, [script, '--old', oldP, '--new', newP, '--out', outP], { stdio: ['ignore', 'ignore', 'ignore'] });
  const merged = JSON.parse(readFileSync(outP, 'utf8'));
  const by = new Map(merged.songs.map((s) => [s.id, s]));
  eq(by.get('sng_1').appleMusicId, '10', 'appleMusicId carried forward');
  eq(by.get('sng_1').appleMusicIdExplicit, '11', 'appleMusicIdExplicit carried forward');
  eq(by.get('sng_1').appleMusicIdClean, '12', 'appleMusicIdClean carried forward');
  eq(by.get('sng_1').explicit, true, 'explicit flag carried forward');
  eq(by.get('sng_2').appleMusicIdClean, 'NEW22', 'present-on-new wins (idempotent)');
  eq(by.get('sng_3').appleMusicIdExplicit, undefined, 'no variant id invented');
  eq(merged.manifest.counts.songsWithExplicitVariant, 1, 'manifest explicit-variant count refreshed');
  eq(merged.manifest.counts.songsWithCleanVariant, 2, 'manifest clean-variant count refreshed');
  rmSync(oldP, { force: true }); rmSync(newP, { force: true }); rmSync(outP, { force: true });
}

if (failures) { console.error(`\n${failures} failure(s)`); process.exit(1); }
console.log('\nall explicit-variant tests passed');
