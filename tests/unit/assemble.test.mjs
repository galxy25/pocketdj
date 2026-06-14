// Tests for assembleShard: enriched albums -> canonical {albums, songs, log}.
import { describe, it, expect } from 'vitest';
import { assembleShard } from '../../.claude/skills/analog-indexer/lib/assemble.js';
import { albumId, songId } from '../../.claude/skills/analog-indexer/lib/ids.js';

const enriched = (over = {}) => ({
  candidateIndex: 0,
  originalFilename: 'ABBAGreatestHitsRaw.mp3',
  fileLocation: '/crate/A',
  fileType: 'mp3',
  dupIndex: null,
  status: 'matched',
  matchConfidence: 'strong',
  score: 0.9,
  itunesCollectionId: 111,
  sources: ['itunes'],
  artist: 'ABBA',
  name: 'Greatest Hits',
  coverArt: 'https://cdn/cover.jpg',
  genre: 'Pop',
  year: 1976,
  country: 'SE',
  tracks: [
    {
      discNumber: 1,
      trackNumber: 1,
      name: 'Dancing Queen',
      lyrics: 'la la',
      lyricsStatus: 'found',
      sentimentKeywords: ['joy'],
      sentimentSource: 'lyrics',
      explicit: false,
      lengthMs: 230000,
    },
  ],
  ...over,
});

describe('assembleShard', () => {
  it('returns empty collections for empty / nullish input', () => {
    expect(assembleShard([])).toEqual({ albums: [], songs: [], log: [] });
    expect(assembleShard(null)).toEqual({ albums: [], songs: [], log: [] });
  });

  it('builds an album record with content-derived id and copied fields', () => {
    const { albums } = assembleShard([enriched()]);
    expect(albums).toHaveLength(1);
    const a = albums[0];
    expect(a.id).toBe(albumId('ABBA', 'Greatest Hits', null));
    expect(a.artist).toBe('ABBA');
    expect(a.name).toBe('Greatest Hits');
    expect(a.coverArt).toBe('https://cdn/cover.jpg');
    expect(a.genre).toBe('Pop');
    expect(a.year).toBe(1976);
    expect(a.country).toBe('SE');
    expect(a.fileType).toBe('mp3');
    expect(a.enrichment.status).toBe('matched');
    expect(a.enrichment.matchConfidence).toBe('strong');
    expect(a.enrichment.itunesCollectionId).toBe(111);
  });

  it('builds song records linked to the album and the trackList', () => {
    const { albums, songs } = assembleShard([enriched()]);
    const aid = albums[0].id;
    expect(songs).toHaveLength(1);
    const s = songs[0];
    expect(s.id).toBe(songId(aid, 1, 1));
    expect(s.albumId).toBe(aid);
    expect(s.name).toBe('Dancing Queen');
    expect(s.lyricsStatus).toBe('found');
    expect(s.sentimentKeywords).toEqual(['joy']);
    expect(s.sentimentSource).toBe('lyrics');
    expect(s.length).toBe(230000);
    expect(albums[0].trackList).toEqual([s.id]);
  });

  it('inherits artist/year from the album when the track omits them', () => {
    const { songs } = assembleShard([
      enriched({
        tracks: [{ discNumber: 1, trackNumber: 2, name: 'SOS' }],
      }),
    ]);
    expect(songs[0].artist).toBe('ABBA');
    expect(songs[0].year).toBe(1976);
  });

  it('skips tracks with no trackNumber', () => {
    const { albums, songs } = assembleShard([
      enriched({
        tracks: [
          { discNumber: 1, trackNumber: null, name: 'Hidden' },
          { discNumber: 1, trackNumber: 1, name: 'Real' },
        ],
      }),
    ]);
    expect(songs).toHaveLength(1);
    expect(songs[0].name).toBe('Real');
    expect(albums[0].trackList).toHaveLength(1);
  });

  it('downgrades any non-matched status to "unmatched"', () => {
    const { albums } = assembleShard([enriched({ status: 'weak-ish-typo' })]);
    expect(albums[0].enrichment.status).toBe('unmatched');
  });

  it('defaults lyricsStatus/sentimentSource from the data when omitted', () => {
    const { songs } = assembleShard([
      enriched({
        tracks: [
          { trackNumber: 1, name: 'has lyrics', lyrics: 'words' },
          { trackNumber: 2, name: 'no sentiment' },
        ],
      }),
    ]);
    expect(songs[0].lyricsStatus).toBe('found'); // lyrics present
    expect(songs[1].lyricsStatus).toBe('notfound'); // no lyrics
    expect(songs[1].sentimentSource).toBe('failed'); // no keywords
  });

  it('drops an unrecognized fileType to undefined', () => {
    const { albums } = assembleShard([enriched({ fileType: 'xyz' })]);
    expect(albums[0].fileType).toBeUndefined();
  });

  it('emits a log entry per album with track + lyrics counts', () => {
    const { log } = assembleShard([enriched()]);
    expect(log).toHaveLength(1);
    expect(log[0]).toMatchObject({
      candidateIndex: 0,
      originalFilename: 'ABBAGreatestHitsRaw.mp3',
      status: 'matched',
      trackCount: 1,
      lyricsFound: 1,
    });
  });

  it('gives duplicate pressings distinct album ids via dupIndex', () => {
    const { albums } = assembleShard([
      enriched({ candidateIndex: 0, dupIndex: null }),
      enriched({ candidateIndex: 1, dupIndex: 2 }),
    ]);
    expect(albums[0].id).not.toBe(albums[1].id);
  });
});
