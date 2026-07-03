// Shared Music.app AppleScript driving + iTunes-plist writing, used by BOTH the full
// headless export (dump-apple-music-library.mjs) and the incremental append sync
// (am-incremental-sync.mjs). One source of truth for: how we read enriched per-track
// fields over AppleScript, how we read playlists, and how we serialise an indexer-
// compatible Library.xml (single-line fields per FIELD_RE, <date> Date Added, file://
// Locations, per-line Playlist Item Track IDs).
//
// The ONE field Music does NOT expose over AppleScript is `explicit` ("descriptor type
// mismatch") — it's carried forward from the committed index by am-merge-catalog-ids.mjs.

import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

// Tab-separated column layout (v3) for the intermediate per-track rows. mediaKind is
// appended LAST so a v2 TSV (13 cols) still parses — it just reads back as ''.
export const COLS = ['persistentID', 'artist', 'title', 'album', 'albumArtist', 'genre', 'year',
  'trackNumber', 'discNumber', 'totalTime', 'dateAdded', 'location', 'kind', 'mediaKind'];
export const TSV_HEADER = COLS.join('\t');

// AppleScript handlers: text sanitiser (strip tab/CR/LF so a value can't break the row
// layout) + ISO date builder (local "YYYY-MM-DDTHH:MM:SS", read back as local wall-clock).
export const HANDLERS = `
on padN(n)
  set n to n as integer
  if n < 10 then return "0" & (n as text)
  return n as text
end padN
on isoDate(d)
  try
    return ((year of d) as text) & "-" & (my padN((month of d) as integer)) & "-" & (my padN(day of d)) & "T" & (my padN(hours of d)) & ":" & (my padN(minutes of d)) & ":" & (my padN(seconds of d))
  on error
    return ""
  end try
end isoDate
on clean(s)
  try
    set s to s as text
  on error
    return ""
  end try
  set AppleScript's text item delimiters to {tab, return, (ASCII character 10)}
  set ps to text items of s
  set AppleScript's text item delimiters to " "
  set s to ps as text
  set AppleScript's text item delimiters to ""
  return s
end clean
`;

// The per-track field reads + row assembly (shared between selector and position modes).
// `t` must already be bound to a track inside a `tell application "Music"` block.
const TRACK_BODY = `
        set pid to ""
        set nm to ""
        set ar to ""
        set al to ""
        set aa to ""
        set gn to ""
        set yr to ""
        set tn to ""
        set dn to ""
        set tt to ""
        set da to ""
        set lo to ""
        set kd to ""
        set mk to ""
        try
          set pid to (persistent ID of t) as text
        end try
        try
          set nm to (my clean(name of t))
        end try
        try
          set ar to (my clean(artist of t))
        end try
        try
          set al to (my clean(album of t))
        end try
        try
          set aa to (my clean(album artist of t))
        end try
        try
          set gn to (my clean(genre of t))
        end try
        try
          set yr to ((year of t) as text)
        end try
        try
          set tn to ((track number of t) as text)
        end try
        try
          set dn to ((disc number of t) as text)
        end try
        try
          set tt to ((round ((duration of t) * 1000)) as text)
        end try
        try
          set da to (my isoDate(date added of t))
        end try
        try
          set lo to (POSIX path of (location of t))
        end try
        try
          set kd to ((kind of t) as text)
        end try
        try
          set mk to ((media kind of t) as text)
        end try
        set end of buf to pid & tab & ar & tab & nm & tab & al & tab & aa & tab & gn & tab & yr & tab & tn & tab & dn & tab & tt & tab & da & tab & lo & tab & kd & tab & mk`;

const asPath = (p) => p.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

// Build the enriched-track AppleScript. Two modes:
//   { selector }  — iterate `item k of (<selector>)` (full library / incremental / limit)
//   { positions } — iterate `item (item x of {positions}) of (every track)` (1-based indices)
// Writes 2000-row chunks to rawPath so a long run can't lose progress.
export function buildTrackScript({ rawPath, timeoutSec, selector, positions }) {
  const setup = positions
    ? `  tell application "Music"
    set tks to (every track of library playlist 1)
  end tell
  set poss to {${positions.join(',')}}
  set total to (count of poss)`
    : `  tell application "Music"
    set tks to ${selector}
  end tell
  set total to (count of tks)`;
  // positions mode indexes into a SECOND library snapshot (line above) — if the library
  // shrank between snapshots an out-of-range pick must yield an empty row (dropped at
  // parse), not abort the whole run with an uncaught AppleScript error.
  const pick = positions
    ? `set t to missing value
        try
          set t to item (item k of poss) of tks
        end try`
    : `set t to item k of tks`;
  return `${HANDLERS}
set outPath to "${asPath(rawPath)}"
set fh to open for access (POSIX file outPath) with write permission
set eof of fh to 0
with timeout of ${timeoutSec} seconds
${setup}
  set i to 1
  repeat while i is less than or equal to total
    set j to i + 1999
    if j is greater than total then set j to total
    set buf to {}
    tell application "Music"
      repeat with k from i to j
        ${pick}${TRACK_BODY}
      end repeat
    end tell
    set text item delimiters to linefeed
    write ((buf as text) & linefeed) to fh as «class utf8»
    set i to j + 1
  end repeat
end timeout
close access fh
return total`;
}

// Build the playlist AppleScript: one row per regular user playlist —
//   persistentID<TAB>name<TAB>comma-joined track persistent IDs
// skipping folders + special playlists (special kind ≠ none). A failed track read
// emits "!ERR" as the membership column — never mistakable for a real (empty) list.
export function buildPlaylistScript({ rawPath, timeoutSec }) {
  return `${HANDLERS}
set outPath to "${asPath(rawPath)}"
set fh to open for access (POSIX file outPath) with write permission
set eof of fh to 0
with timeout of ${timeoutSec} seconds
  tell application "Music"
    set pls to (every user playlist)
  end tell
  set pc to (count of pls)
  repeat with pidx from 1 to pc
    set lineOut to ""
    tell application "Music"
      set p to item pidx of pls
      set sk to "none"
      try
        set sk to ((special kind of p) as text)
      end try
      set isFolder to false
      try
        if (class of p) is folder playlist then set isFolder to true
      end try
      if (sk is "none") and (not isFolder) then
        set pn to ""
        set ppid to ""
        try
          set pn to (my clean(name of p))
        end try
        try
          set ppid to ((persistent ID of p) as text)
        end try
        set tids to {}
        set tidsOk to true
        set tcount to -1
        try
          set tcount to (count of tracks of p)
        end try
        if tcount is -1 then
          set tidsOk to false
        else if tcount > 0 then
          -- NB: this read ERRORS (-1728) on an EMPTY playlist, hence the count gate above.
          try
            set tids to (get persistent ID of every track of p)
          on error
            set tidsOk to false
          end try
        end if
        set AppleScript's text item delimiters to ","
        set tidStr to (tids as text)
        set AppleScript's text item delimiters to ""
        if not tidsOk then set tidStr to "!ERR"
        set lineOut to ppid & tab & pn & tab & tidStr
      end if
    end tell
    if lineOut is not "" then write (lineOut & linefeed) to fh as «class utf8»
  end repeat
end timeout
close access fh
return pc`;
}

// Run an AppleScript; returns { ok, out, err }.
export function runOsascript(script, timeoutMs) {
  const r = spawnSync('osascript', ['-e', script], { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024 });
  if (r.error || r.status !== 0) return { ok: false, out: '', err: (r.stderr || r.error?.message || '').trim() };
  return { ok: true, out: (r.stdout || '').trim(), err: '' };
}

// Parse the enriched per-track raw TSV into row objects (missing-value guarded).
const nz = (v) => (v === 'missing value' ? '' : (v || ''));
export function parseTrackRows(text) {
  const rows = [];
  for (const ln of text.split('\n')) {
    if (!ln || ln === TSV_HEADER) continue;
    const c = ln.split('\t');
    const e = {};
    COLS.forEach((col, i) => { e[col] = nz(c[i]); });
    if (!e.title && !e.artist) continue;
    rows.push(e);
  }
  return rows;
}

// Parse the playlist raw TSV: persistentID<TAB>name<TAB>pid,pid,…
// A "!ERR" membership marker means the track read failed in Music (readError: true) —
// callers must treat that as "membership unknown", NOT as an empty playlist.
export function parsePlaylistRows(text) {
  const out = [];
  for (const ln of text.split('\n')) {
    if (!ln) continue;
    const [ppid = '', name = '', tidStr = ''] = ln.split('\t');
    if (tidStr === '!ERR') { out.push({ ppid, name, pids: [], readError: true }); continue; }
    const pids = tidStr ? tidStr.split(',').map((s) => s.trim()).filter(Boolean) : [];
    out.push({ ppid, name, pids });
  }
  return out;
}

// Serialise rows (+ optional playlists) to an indexer-compatible Library.xml plist.
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const numOf = (s) => { const n = parseInt(s, 10); return Number.isFinite(n) ? n : 0; };
export function writeLibraryXml({ rows, playlists = [], runStart, out }) {
  const pidToTid = new Map();
  rows.forEach((e, i) => { if (e.persistentID) pidToTid.set(e.persistentID, i + 1); });
  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">', '<dict>',
    '\t<key>Application</key><string>PocketDJ dump-apple-music-library</string>',
    `\t<key>Date</key><string>${new Date(runStart).toISOString()}</string>`,
    '\t<key>Tracks</key>', '\t<dict>',
  ];
  rows.forEach((e, i) => {
    const tid = i + 1;
    xml.push(`\t\t<key>${tid}</key>`, '\t\t<dict>', `\t\t\t<key>Track ID</key><integer>${tid}</integer>`);
    if (e.title) xml.push(`\t\t\t<key>Name</key><string>${esc(e.title)}</string>`);
    if (e.artist) xml.push(`\t\t\t<key>Artist</key><string>${esc(e.artist)}</string>`);
    if (e.albumArtist) xml.push(`\t\t\t<key>Album Artist</key><string>${esc(e.albumArtist)}</string>`);
    if (e.album) xml.push(`\t\t\t<key>Album</key><string>${esc(e.album)}</string>`);
    if (e.genre) xml.push(`\t\t\t<key>Genre</key><string>${esc(e.genre)}</string>`);
    if (numOf(e.year) > 0) xml.push(`\t\t\t<key>Year</key><integer>${numOf(e.year)}</integer>`);
    if (numOf(e.totalTime) > 0) xml.push(`\t\t\t<key>Total Time</key><integer>${numOf(e.totalTime)}</integer>`);
    if (numOf(e.trackNumber) > 0) xml.push(`\t\t\t<key>Track Number</key><integer>${numOf(e.trackNumber)}</integer>`);
    if (numOf(e.discNumber) > 0) xml.push(`\t\t\t<key>Disc Number</key><integer>${numOf(e.discNumber)}</integer>`);
    if (e.dateAdded) xml.push(`\t\t\t<key>Date Added</key><date>${esc(e.dateAdded)}</date>`);
    if (e.location) xml.push(`\t\t\t<key>Location</key><string>${esc('file://' + encodeURI(e.location))}</string>`);
    if (e.kind) xml.push(`\t\t\t<key>Kind</key><string>${esc(e.kind)}</string>`);
    // Non-music flags so the indexer's music-only filter can fire on AppleScript-sourced
    // rows exactly as it does on a native Library.xml (media kind first, Kind as fallback
    // for pre-v3 TSVs that lack the column).
    const mk = (e.mediaKind || '').toLowerCase();
    if (mk === 'music video' || mk === 'home video' || (!mk && /video|movie/i.test(e.kind || ''))) xml.push('\t\t\t<key>Has Video</key><true/>');
    else if (mk === 'movie') xml.push('\t\t\t<key>Movie</key><true/>');
    else if (mk === 'tv show') xml.push('\t\t\t<key>TV Show</key><true/>');
    else if (mk === 'podcast') xml.push('\t\t\t<key>Podcast</key><true/>');
    else if (mk === 'audiobook') xml.push('\t\t\t<key>Audiobook</key><true/>');
    if (e.persistentID) xml.push(`\t\t\t<key>Persistent ID</key><string>${esc(e.persistentID)}</string>`);
    xml.push('\t\t</dict>');
  });
  xml.push('\t</dict>'); // close Tracks

  let plEmitted = 0;
  xml.push('\t<key>Playlists</key>', '\t<array>');
  for (const pl of playlists) {
    const items = (pl.pids || []).map((pid) => pidToTid.get(pid)).filter(Boolean);
    if (items.length === 0) continue;
    plEmitted++;
    xml.push('\t\t<dict>');
    xml.push(`\t\t\t<key>Name</key><string>${esc(pl.name || 'Untitled Playlist')}</string>`);
    if (pl.ppid) xml.push(`\t\t\t<key>Playlist Persistent ID</key><string>${esc(pl.ppid)}</string>`);
    xml.push('\t\t\t<key>Playlist Items</key>', '\t\t\t<array>');
    for (const t of items) {
      xml.push('\t\t\t\t<dict>', `\t\t\t\t\t<key>Track ID</key><integer>${t}</integer>`, '\t\t\t\t</dict>');
    }
    xml.push('\t\t\t</array>', '\t\t</dict>');
  }
  xml.push('\t</array>');
  xml.push('</dict>', '</plist>', '');
  fs.writeFileSync(out, xml.join('\n'));
  return { tracks: rows.length, playlists: plEmitted };
}
