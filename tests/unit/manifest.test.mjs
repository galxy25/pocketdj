// Tests for the MANIFEST builder (manifest.mjs) — the critical, bug-prone module.
//
// buildFromStages overlays the streaming stage files (enriched, google, web,
// lyrics, sentiment). The invariants under test:
//   - metadata + RECOVERY stages (google/web) OWN album-level fields/status;
//   - lyrics/sentiment are TRACK-ONLY: they must NOT downgrade a recovered
//     album's matched status NOR wipe the tracks the recovery supplied.
// We build a tiny temp shard dir on disk (os.tmpdir) and assert the result.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  buildFromStages,
  statusReport,
  pendingForStage,
  resetStage,
  STAGES,
} from '../../.claude/skills/analog-indexer/lib/manifest.mjs';

let dir;
const writeJsonl = (name, recs) =>
  writeFileSync(join(dir, name), recs.map((r) => JSON.stringify(r)).join('\n') + '\n');

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'pdj-manifest-'));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

// Two albums:
//   ci 0 — UNMATCHED in enriched.jsonl, RECOVERED (matched + tracks) by web.jsonl.
//   ci 1 — normally matched in enriched.jsonl with one track.
// lyrics.jsonl + sentiment.jsonl carry data for BOTH: for ci 0 they are the
// STALE trackless pass-throughs that were written while it was still unmatched
// (they must not clobber the recovery); for ci 1 they layer real lyrics/keywords.
function seedStages() {
  writeJsonl('enriched.jsonl', [
    {
      candidateIndex: 0,
      status: 'unmatched',
      artist: '',
      name: 'MysterySingleBlob',
      tracks: [],
    },
    {
      candidateIndex: 1,
      status: 'matched',
      artist: 'ABBA',
      name: 'Greatest Hits',
      year: 1976,
      genre: 'Pop',
      tracks: [{ discNumber: 1, trackNumber: 1, name: 'Dancing Queen' }],
    },
  ]);

  // web recovery for ci 0: now matched with a real album + tracks.
  writeJsonl('web.jsonl', [
    {
      candidateIndex: 0,
      status: 'matched',
      artist: 'The Real Artist',
      name: 'The Real Album',
      year: 1981,
      tracks: [
        { discNumber: 1, trackNumber: 1, name: 'Recovered Song A' },
        { discNumber: 1, trackNumber: 2, name: 'Recovered Song B' },
      ],
    },
  ]);

  // lyrics: ci 0 is a STALE trackless pass-through (no tracks); ci 1 gets lyrics.
  writeJsonl('lyrics.jsonl', [
    { candidateIndex: 0, status: 'unmatched', artist: '', name: 'MysterySingleBlob', tracks: [] },
    {
      candidateIndex: 1,
      status: 'matched',
      artist: 'ABBA',
      name: 'Greatest Hits',
      tracks: [
        { discNumber: 1, trackNumber: 1, name: 'Dancing Queen', lyrics: 'la la', lyricsStatus: 'found' },
      ],
    },
  ]);

  // sentiment: ci 0 again stale trackless; ci 1 gets keywords.
  writeJsonl('sentiment.jsonl', [
    { candidateIndex: 0, status: 'unmatched', artist: '', name: 'MysterySingleBlob', tracks: [] },
    {
      candidateIndex: 1,
      status: 'matched',
      artist: 'ABBA',
      name: 'Greatest Hits',
      tracks: [
        {
          discNumber: 1,
          trackNumber: 1,
          name: 'Dancing Queen',
          lyrics: 'la la',
          lyricsStatus: 'found',
          sentimentKeywords: ['joy', 'dance'],
          sentimentSource: 'lyrics',
        },
      ],
    },
  ]);
}

describe('buildFromStages — recovery is not downgraded by lyrics/sentiment', () => {
  beforeEach(seedStages);

  it('keeps the web-recovered album matched with its recovery metadata', () => {
    const map = buildFromStages(dir);
    const rec = map.get(0);
    expect(rec.status).toBe('matched');
    expect(rec.artist).toBe('The Real Artist');
    expect(rec.name).toBe('The Real Album');
    expect(rec.year).toBe(1981);
    expect(rec.stages.metadata).toEqual({ status: 'done', source: 'web-lookup' });
  });

  it('preserves the recovery tracks (stale trackless lyrics/sentiment do NOT wipe them)', () => {
    const map = buildFromStages(dir);
    const rec = map.get(0);
    expect(rec.tracks).toHaveLength(2);
    expect(rec.tracks.map((t) => t.name)).toEqual(['Recovered Song A', 'Recovered Song B']);
  });

  it('flows the normal album through metadata -> lyrics -> sentiment', () => {
    const map = buildFromStages(dir);
    const rec = map.get(1);
    expect(rec.status).toBe('matched');
    expect(rec.stages.metadata.status).toBe('done');
    expect(rec.stages.lyrics).toEqual({ status: 'done', found: 1 });
    expect(rec.stages.sentiment).toEqual({ status: 'done', tagged: 1 });
    expect(rec.tracks[0].sentimentKeywords).toEqual(['joy', 'dance']);
    expect(rec.tracks[0].lyricsStatus).toBe('found');
  });

  it('stamps lyrics/sentiment stages on the recovered album too (zero counts, no crash)', () => {
    const map = buildFromStages(dir);
    const rec = map.get(0);
    // lyrics/sentiment files contained ci 0 (trackless) -> their stages get stamped done with 0
    expect(rec.stages.lyrics).toEqual({ status: 'done', found: 0 });
    expect(rec.stages.sentiment).toEqual({ status: 'done', tagged: 0 });
  });
});

describe('buildFromStages — metadata-only & google recovery', () => {
  it('marks an unmatched metadata record metadata:unmatched', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 5, status: 'unmatched', artist: '', name: 'Foo', tracks: [] },
    ]);
    const map = buildFromStages(dir);
    expect(map.get(5).stages.metadata).toEqual({ status: 'unmatched' });
    expect(map.get(5).status).toBe('unmatched');
  });

  it('marks a matched metadata record metadata:done', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 5, status: 'matched', artist: 'A', name: 'B', tracks: [] },
    ]);
    expect(buildFromStages(dir).get(5).stages.metadata).toEqual({ status: 'done' });
  });

  it('applies google-fallback recovery as a done metadata source', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 7, status: 'unmatched', artist: '', name: 'X', tracks: [] },
    ]);
    writeJsonl('google.jsonl', [
      {
        candidateIndex: 7,
        status: 'matched',
        artist: 'Found Artist',
        name: 'Found Album',
        tracks: [{ discNumber: 1, trackNumber: 1, name: 'T1' }],
      },
    ]);
    const rec = buildFromStages(dir).get(7);
    expect(rec.status).toBe('matched');
    expect(rec.artist).toBe('Found Artist');
    expect(rec.stages.metadata).toEqual({ status: 'done', source: 'google-fallback' });
    expect(rec.tracks).toHaveLength(1);
  });

  it('ignores records missing a candidateIndex', () => {
    writeJsonl('enriched.jsonl', [{ status: 'matched', name: 'No CI' }]);
    expect(buildFromStages(dir).size).toBe(0);
  });

  it('returns an empty map for an empty / missing dir', () => {
    expect(buildFromStages(dir).size).toBe(0);
  });
});

describe('statusReport', () => {
  beforeEach(seedStages);

  it('counts matched albums, songs and tagged/lyric coverage from the built map', () => {
    const map = buildFromStages(dir);
    const rep = statusReport(map);
    expect(rep.total).toBe(2);
    expect(rep.albumsMatched).toBe(2); // ci0 recovered + ci1 matched
    // ci0 has 2 recovery tracks (no lyrics/sentiment) + ci1 has 1 tagged track
    expect(rep.songs).toBe(3);
    expect(rep.songsWithLyrics).toBe(1);
    expect(rep.songsTagged).toBe(1);
  });

  it('reports per-stage done/pending counts', () => {
    const map = buildFromStages(dir);
    const rep = statusReport(map);
    expect(STAGES).toEqual(['metadata', 'lyrics', 'sentiment', 'audio']);
    expect(rep.perStage.metadata.done).toBe(2);
    expect(rep.perStage.lyrics.done).toBe(2);
    expect(rep.perStage.sentiment.done).toBe(2);
    // audio stage is never stamped -> all pending
    expect(rep.perStage.audio.pending).toBe(2);
  });
});

describe('pendingForStage / resetStage', () => {
  it('lists items whose stage is not done (excluding metadata-unmatched by default)', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'matched', name: 'M', tracks: [] },
      { candidateIndex: 1, status: 'unmatched', name: 'U', tracks: [] },
    ]);
    const map = buildFromStages(dir);
    // lyrics stage never ran -> both pending for lyrics
    expect(pendingForStage(map, 'lyrics').map((r) => r.candidateIndex).sort()).toEqual([0, 1]);
    // metadata: ci0 done (skip), ci1 unmatched (excluded by default)
    expect(pendingForStage(map, 'metadata')).toEqual([]);
    // include unmatched -> ci1 shows up
    expect(pendingForStage(map, 'metadata', { includeUnmatched: true }).map((r) => r.candidateIndex)).toEqual([1]);
  });

  it('resetStage clears a stage so the item becomes pending again', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'matched', name: 'M', tracks: [] },
    ]);
    const map = buildFromStages(dir);
    expect(map.get(0).stages.metadata).toBeDefined();
    const n = resetStage(map, 'metadata');
    expect(n).toBe(1);
    expect(map.get(0).stages.metadata).toBeUndefined();
  });

  it('resetStage honors a predicate', () => {
    writeJsonl('enriched.jsonl', [
      { candidateIndex: 0, status: 'matched', name: 'Keep', tracks: [] },
      { candidateIndex: 1, status: 'matched', name: 'Reset', tracks: [] },
    ]);
    const map = buildFromStages(dir);
    const n = resetStage(map, 'metadata', (rec) => rec.candidateIndex === 1);
    expect(n).toBe(1);
    expect(map.get(0).stages.metadata).toBeDefined();
    expect(map.get(1).stages.metadata).toBeUndefined();
  });
});
