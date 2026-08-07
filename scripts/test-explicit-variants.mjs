#!/usr/bin/env node
// Self-test for the explicit-variant matcher (scripts/lib/explicit-variants.mjs) and the
// edition-aware am-match extensions. No deps, no network:  node scripts/test-explicit-variants.mjs
// Exits non-zero on any failure.
import { classifyExplicitness, findEditions } from './lib/explicit-variants.mjs';
import { loadLibraryXML, indexLibrary, findInLibrary } from './lib/am-match.mjs';
import { collectionSongIds } from './resolve-explicit-variants.mjs';
import { writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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
</dict></dict></plist>`;
const xmlPath = join(tmpdir(), `pdj-test-lib-${process.pid}.xml`);
writeFileSync(xmlPath, xml);
const entries = loadLibraryXML(xmlPath);
rmSync(xmlPath, { force: true });

eq(entries.length, 3, 'XML fixture parses 3 entries');
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
// Required edition ABSENT → NO exact hit (loose diagnostics may still fire; never 'exact').
{
  const r = findInLibrary(lib, 'Aria', 'Solo Cut', { explicitness: 'explicit' });
  eq(r.match === 'exact', false, 'required edition absent -> no exact hit');
}
eq(findInLibrary(lib, 'Aria', 'Solo Cut', { explicitness: 'clean' }).hit?.persistentID, 'CCCC3333', 'clean requirement satisfied by explicit=false entry');

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

if (failures) { console.error(`\n${failures} failure(s)`); process.exit(1); }
console.log('\nall explicit-variant tests passed');
