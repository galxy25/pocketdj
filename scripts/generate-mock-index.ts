// Mock index generator — emits a valid index.json (same schema as the real
// indexer) so we can exercise the browser, filters, sort, edit, and star map at
// scale immediately, without waiting for the background indexer. Includes
// deliberate EDGE CASES.
//
//   npm run gen:mock -- --albums 300 --out public/mock-index.json [--seed 7]
//
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { mulberry32, fnv1a } from '../src/lib/prng';
import type { IndexJson, IndexAlbum, IndexSong } from '../src/types/index-json';
import { INDEX_SCHEMA_VERSION } from '../src/types/index-json';

function arg(flag: string, def: string): string {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : def;
}

const N = parseInt(arg('--albums', '300'), 10);
const OUT = arg('--out', 'public/mock-index.json');
const SEED = parseInt(arg('--seed', '7'), 10);
const rng = mulberry32(SEED);
const pick = <T>(arr: T[]): T => arr[Math.floor(rng() * arr.length)];
const chance = (p: number) => rng() < p;
const range = (lo: number, hi: number) => lo + Math.floor(rng() * (hi - lo + 1));

const GENRES = [
  'Soul', 'Funk', 'Disco', 'Hip-Hop/Rap', 'R&B/Soul', 'Rock', 'Pop', 'Jazz',
  'Reggae', 'Country', 'Electronic', 'Gospel', 'Latin', 'Blues', 'New Wave', 'Classical',
];
const COUNTRIES = ['United States', 'United Kingdom', 'Jamaica', 'France', 'Germany', 'Brazil', 'Nigeria', 'Canada'];
const ARTIST_A = ['Cosmic', 'Midnight', 'Velvet', 'Electric', 'Golden', 'Silver', 'Royal', 'Lunar', 'Crimson', 'Neon', 'Solar', 'Mystic', 'Smooth', 'Wild', 'Atomic', 'Disco'];
const ARTIST_B = ['Brothers', 'Express', 'Connection', 'Orchestra', 'Sisters', 'Crew', 'Band', 'Collective', 'Section', 'Allstars', 'Players', 'Tones', 'Machine', 'Sound', 'Project', 'Family'];
const ALBUM_W = ['Love', 'Night', 'Fire', 'Dream', 'City', 'Heart', 'Groove', 'Light', 'Rain', 'Gold', 'Moon', 'Soul', 'Dance', 'Heat', 'Sky', 'Time', 'Magic', 'Funk', 'Street', 'Paradise'];
const SONG_W = ['Stay', 'Tonight', 'Forever', 'Burning', 'Falling', 'Shine', 'Move', 'Closer', 'Higher', 'Wonder', 'Believe', 'Runaway', 'Sweet', 'Lonely', 'Together', 'Free', 'Lost', 'Alive', 'Dancing', 'Golden'];
const SENTIMENTS = ['romantic', 'upbeat', 'melancholy', 'nostalgic', 'euphoric', 'smooth', 'gritty', 'hopeful', 'sensual', 'celebratory', 'reflective', 'driving', 'tender', 'defiant', 'dreamy', 'groovy', 'somber', 'playful', 'yearning', 'triumphant'];
const FILETYPES = ['mp3', 'aiff', 'm4a'];

const id = (prefix: string, s: string) => prefix + fnv1a(s).toString(16).padStart(8, '0') + (fnv1a('x' + s) % 9973).toString(16);

const albums: IndexAlbum[] = [];
const songs: IndexSong[] = [];
let withLyrics = 0;
let fromLyrics = 0;
let inferred = 0;

function makeAlbum(i: number, opts: { unmatched?: boolean; various?: boolean; dupOf?: string } = {}): void {
  const artist = opts.various ? 'Various Artists' : `${pick(ARTIST_A)} ${pick(ARTIST_B)}`;
  const name = `${pick(ALBUM_W)} ${pick(ALBUM_W)}${chance(0.25) ? ' ' + pick(ALBUM_W) : ''}`;
  const dupSuffix = opts.dupOf ? '|dup2' : '';
  const albumId = id('alb_', `${artist}|${name}${dupSuffix}|${i}`);
  const fileType = pick(FILETYPES);
  // Edge cases: ~8% missing genre, ~8% missing year, ~12% missing country, extreme years.
  const genre = chance(0.08) ? undefined : pick(GENRES);
  let year: number | undefined = chance(0.08) ? undefined : range(1962, 2024);
  if (chance(0.02)) year = pick([1948, 1955, 2025]); // extremes
  const country = chance(0.12) ? undefined : pick(COUNTRIES);

  const trackList: string[] = [];
  if (!opts.unmatched) {
    const count = range(6, 14);
    for (let t = 1; t <= count; t++) {
      const sName = `${pick(SONG_W)}${chance(0.4) ? ' ' + pick(SONG_W) : ''}`;
      const songIdStr = id('sng_', `${albumId}|1|${t}`);
      trackList.push(songIdStr);
      const hasLyrics = chance(0.45);
      if (hasLyrics) withLyrics++;
      const kw: string[] = [];
      const kwn = chance(0.05) ? 0 : range(3, 6); // a few with empty sentiment
      for (let k = 0; k < kwn; k++) kw.push(pick(SENTIMENTS));
      const sentSource = kwn === 0 ? 'failed' : hasLyrics ? 'lyrics' : 'inferred';
      if (sentSource === 'lyrics') fromLyrics++;
      else if (sentSource === 'inferred') inferred++;
      // very short / very long edge lengths occasionally
      let lengthMs = range(95, 380) * 1000;
      if (chance(0.02)) lengthMs = pick([38000, 1080000]);
      songs.push({
        id: songIdStr,
        albumId,
        artist: opts.various ? `${pick(ARTIST_A)} ${pick(ARTIST_B)}` : artist,
        name: sName,
        trackNumber: t,
        year,
        lyrics: hasLyrics ? `[mock lyrics for ${sName}] ${pick(SENTIMENTS)} ${pick(SENTIMENTS)}…` : null,
        lyricsStatus: hasLyrics ? 'found' : 'notfound',
        sentimentKeywords: kw,
        sentimentSource: sentSource as IndexSong['sentimentSource'],
        explicit: chance(0.15),
        bpm: null,
        key: null,
        length: lengthMs,
        fileType,
        pointer: { fileLocation: 'Vinyl crate M', filename: `${artist}${name}Raw.${fileType}`.replace(/\s/g, ''), disc: 1, track: t, timestamps: null },
      });
    }
  }

  albums.push({
    id: albumId,
    artist,
    name,
    coverArt: undefined, // app generates a deterministic placeholder from id
    genre,
    year,
    country,
    trackList,
    fileType,
    pointer: { fileLocation: 'Vinyl crate M', originalFilename: `${artist}${name}Raw.${fileType}`.replace(/\s/g, '') },
    enrichment: {
      status: opts.unmatched ? 'unmatched' : 'matched',
      matchConfidence: opts.unmatched ? undefined : chance(0.8) ? 'strong' : 'weak',
      score: opts.unmatched ? 0.2 : Number((0.6 + rng() * 0.4).toFixed(2)),
      sources: opts.unmatched ? ['wikipedia'] : ['itunes', 'musicbrainz'],
    },
  });
}

for (let i = 0; i < N; i++) {
  const unmatched = chance(0.04); // ~4% unmatched (no songs)
  const various = chance(0.05);
  makeAlbum(i, { unmatched, various });
}
// guaranteed Raw-duplicate pair (same artist+album, distinct ids)
makeAlbum(N, {});
makeAlbum(N, { dupOf: 'pair' });

const index: IndexJson = {
  manifest: {
    source: 'MOCK',
    generatedAt: new Date().toISOString(),
    schemaVersion: INDEX_SCHEMA_VERSION,
    sourceType: 'analog',
    sourceName: 'Mock Vinyl',
    counts: {
      lines: N,
      vinylLines: N,
      albums: albums.length,
      songs: songs.length,
      albumsMatched: albums.filter((a) => a.enrichment?.status === 'matched').length,
      albumsUnmatched: albums.filter((a) => a.enrichment?.status === 'unmatched').length,
      songsWithLyrics: withLyrics,
      sentimentFromLyrics: fromLyrics,
      sentimentInferred: inferred,
    },
    deferredFields: ['song.bpm', 'song.key', 'song.pointer.timestamps'],
  },
  albums,
  songs,
};

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify(index));
process.stderr.write(`wrote ${OUT}: ${albums.length} albums, ${songs.length} songs (seed ${SEED})\n`);
