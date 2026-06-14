// Tests for mergeShards: per-batch shards -> index.json + coverage report.
import { describe, it, expect } from 'vitest';
import { mergeShards } from '../../.claude/skills/analog-indexer/lib/merge.js';
import { INDEX_SCHEMA_VERSION } from '../../.claude/skills/analog-indexer/lib/schema-version.js';

const album = (id, over = {}) => ({
  id,
  artist: 'ABBA',
  name: 'Greatest Hits',
  coverArt: 'https://cdn/c.jpg',
  genre: 'Pop',
  year: 1976,
  country: 'SE',
  trackList: [],
  enrichment: { status: 'matched', matchConfidence: 'strong' },
  ...over,
});

const song = (id, albumId, over = {}) => ({
  id,
  albumId,
  name: 'Track',
  lyricsStatus: 'notfound',
  sentimentSource: 'failed',
  ...over,
});

describe('mergeShards', () => {
  it('upserts albums/songs by id across shards (last write wins)', () => {
    const shards = [
      { albums: [album('alb_1')], songs: [song('sng_1', 'alb_1')] },
      // same album id again with a changed field -> dedups to one, latest kept
      { albums: [album('alb_1', { genre: 'Disco' })], songs: [] },
      { albums: [album('alb_2')], songs: [song('sng_2', 'alb_2')] },
    ];
    const { index } = mergeShards(shards);
    expect(index.albums).toHaveLength(2);
    expect(index.songs).toHaveLength(2);
    const a1 = index.albums.find((a) => a.id === 'alb_1');
    expect(a1.genre).toBe('Disco');
  });

  it('skips nullish shards', () => {
    const { index } = mergeShards([null, { albums: [album('alb_1')] }, undefined]);
    expect(index.albums).toHaveLength(1);
  });

  it('counts matched vs unmatched albums', () => {
    const shards = [
      {
        albums: [
          album('alb_1'),
          album('alb_2', { enrichment: { status: 'unmatched' } }),
        ],
        songs: [],
      },
    ];
    const { index } = mergeShards(shards);
    expect(index.manifest.counts.albumsMatched).toBe(1);
    expect(index.manifest.counts.albumsUnmatched).toBe(1);
  });

  it('counts lyrics and sentiment sources on songs', () => {
    const shards = [
      {
        albums: [album('alb_1')],
        songs: [
          song('s1', 'alb_1', { lyricsStatus: 'found', sentimentSource: 'lyrics' }),
          song('s2', 'alb_1', { sentimentSource: 'inferred' }),
          song('s3', 'alb_1', { sentimentSource: 'failed' }),
        ],
      },
    ];
    const { index, coverageReport } = mergeShards(shards);
    expect(index.manifest.counts.songsWithLyrics).toBe(1);
    expect(index.manifest.counts.sentimentFromLyrics).toBe(1);
    expect(index.manifest.counts.sentimentInferred).toBe(1);
    expect(coverageReport.songs.sentimentFailed).toBe(1);
  });

  it('stamps the schema version and analog source type', () => {
    const { index } = mergeShards([{ albums: [], songs: [] }]);
    expect(index.manifest.schemaVersion).toBe(INDEX_SCHEMA_VERSION);
    expect(index.manifest.sourceType).toBe('analog');
  });

  it('respects meta overrides and falls back to defaults', () => {
    const { index } = mergeShards([{ albums: [], songs: [] }], {
      source: 'MyCrate.md',
      sourceName: 'Crate One',
      generatedAt: '2026-01-01T00:00:00Z',
      parseLines: 50,
      parseVinyl: 40,
    });
    expect(index.manifest.source).toBe('MyCrate.md');
    expect(index.manifest.sourceName).toBe('Crate One');
    expect(index.manifest.generatedAt).toBe('2026-01-01T00:00:00Z');
    expect(index.manifest.counts.lines).toBe(50);
    expect(index.manifest.counts.vinylLines).toBe(40);
  });

  it('computes coverage match rate and confidence breakdown', () => {
    const shards = [
      {
        albums: [
          album('alb_1', { enrichment: { status: 'matched', matchConfidence: 'strong' } }),
          album('alb_2', { enrichment: { status: 'matched', matchConfidence: 'weak' } }),
          album('alb_3', { enrichment: { status: 'unmatched' } }),
        ],
        songs: [],
      },
    ];
    const { coverageReport } = mergeShards(shards);
    expect(coverageReport.albums.total).toBe(3);
    expect(coverageReport.albums.matchedStrong).toBe(1);
    expect(coverageReport.albums.matchedWeak).toBe(1);
    expect(coverageReport.albums.unmatched).toBe(1);
    expect(coverageReport.albums.matchRate).toBe(0.667); // 2/3 to 3dp
  });

  it('flags weak matches for review and lists their ids', () => {
    const shards = [
      {
        albums: [album('alb_weak', { enrichment: { status: 'matched', matchConfidence: 'weak' } })],
        songs: [],
      },
    ];
    const { coverageReport } = mergeShards(shards);
    expect(coverageReport.flags.weakMatchesToReview).toContain('alb_weak');
  });

  it('counts duplicate (artist|name) groups', () => {
    const shards = [
      {
        albums: [
          album('alb_1', { artist: 'ABBA', name: 'Arrival' }),
          album('alb_2', { artist: 'ABBA', name: 'Arrival' }), // dup group
          album('alb_3', { artist: 'ABBA', name: 'Voulez-Vous' }),
        ],
        songs: [],
      },
    ];
    const { coverageReport } = mergeShards(shards);
    expect(coverageReport.duplicates.rawDupGroups).toBe(1);
  });

  it('counts various-artists albums', () => {
    const shards = [
      {
        albums: [album('alb_1', { artist: 'Various Artists' }), album('alb_2', { artist: 'ABBA' })],
        songs: [],
      },
    ];
    const { coverageReport } = mergeShards(shards);
    expect(coverageReport.flags.variousArtists).toBe(1);
  });

  it('aggregates the run log across shards', () => {
    const { runLog } = mergeShards([
      { albums: [], songs: [], log: [{ candidateIndex: 0 }] },
      { albums: [], songs: [], log: [{ candidateIndex: 1 }] },
    ]);
    expect(runLog).toHaveLength(2);
  });

  it('reports per-field coverage (cover, year, genre, country)', () => {
    const shards = [
      {
        albums: [
          album('alb_1'),
          album('alb_2', { coverArt: undefined, year: null, genre: undefined, country: undefined }),
        ],
        songs: [],
      },
    ];
    const { coverageReport } = mergeShards(shards);
    expect(coverageReport.fields.withCover).toBe(1);
    expect(coverageReport.fields.withYear).toBe(1);
    expect(coverageReport.fields.withGenre).toBe(1);
    expect(coverageReport.fields.withCountry).toBe(1);
  });
});
