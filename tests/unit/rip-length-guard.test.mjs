// Capture LENGTH GUARD — the pure rule (scripts/lib/rip-length-guard.mjs) plus the real
// ffprobe/ffmpeg measure-and-trim path on synthesized audio.
//
// The incident: a macOS playback cascade stopped Music.app mid-song, the capture read that as
// "track ended", and 54 s of a 221 s song (sng_62bf34d1ac4d) was uploaded as `ok` — with stems,
// beat grid, waveform, lyrics and timbre all computed from the fragment.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  LENGTH_GUARD_DEFAULTS as D, lengthGuardConfig, underToleranceMs, resolveExpectedLength,
  judgeCaptureLength, parseSilences, trailingTrimMs, auditManifestLengths, repairTargetsFor,
  dropPreRepairRows, guardCaptureFile, probeDurationMs, describeVerdict,
} from '../../scripts/lib/rip-length-guard.mjs';

describe('judgeCaptureLength — the decision', () => {
  it('UNDER: the three real partial captures are short-capture', () => {
    for (const [m, e] of [[54_300, 221_043], [39_400, 377_920], [63_700, 249_613]]) {
      const v = judgeCaptureLength({ measuredMs: m, expectedMs: e });
      expect(v.verdict).toBe('short');
      expect(v.reason).toBe('short-capture');
      expect(v.deltaMs).toBe(m - e);
    }
  });

  it('UNDER tolerance is the MORE lenient of 5 % and 5 s', () => {
    expect(underToleranceMs(60_000)).toBe(5_000);          // 5 % = 3 s → 5 s wins
    expect(underToleranceMs(300_000)).toBeCloseTo(15_000);  // 5 % = 15 s wins
    // 60 s song, 4.9 s short → ok; 5.1 s short → short
    expect(judgeCaptureLength({ measuredMs: 55_100, expectedMs: 60_000 }).verdict).toBe('ok');
    expect(judgeCaptureLength({ measuredMs: 54_900, expectedMs: 60_000 }).verdict).toBe('short');
    // 300 s song, 14 s short → ok (ratio is more lenient than the 5 s slack)
    expect(judgeCaptureLength({ measuredMs: 286_000, expectedMs: 300_000 }).verdict).toBe('ok');
    expect(judgeCaptureLength({ measuredMs: 284_000, expectedMs: 300_000 }).verdict).toBe('short');
  });

  it('OK: the healthy +12–13 s overruns (168 vs 155, 148 vs 136, 182 vs 171) pass', () => {
    for (const [m, e] of [[168_000, 155_000], [148_000, 136_000], [182_000, 171_000], [222_900, 221_043]]) {
      const v = judgeCaptureLength({ measuredMs: m, expectedMs: e });
      expect(v.verdict).toBe('ok');
      expect(v.overrunMs).toBe(m - e);
    }
  });

  it('OVER: more than 20 s past expected is long-capture', () => {
    expect(judgeCaptureLength({ measuredMs: 210_500, expectedMs: 90_673 })).toMatchObject({ verdict: 'long', reason: 'long-capture' });
    expect(judgeCaptureLength({ measuredMs: 120_001, expectedMs: 100_000 }).verdict).toBe('long');
    expect(judgeCaptureLength({ measuredMs: 120_000, expectedMs: 100_000 }).verdict).toBe('ok');
  });

  it('SKIP: no expected length, no measurement, guard disabled — never a rejection', () => {
    expect(judgeCaptureLength({ measuredMs: 10_000, expectedMs: null })).toMatchObject({ verdict: 'skip', reason: 'no-expected-length' });
    expect(judgeCaptureLength({ measuredMs: 10_000, expectedMs: 0 })).toMatchObject({ verdict: 'skip', reason: 'no-expected-length' });
    expect(judgeCaptureLength({ measuredMs: null, expectedMs: 200_000 })).toMatchObject({ verdict: 'skip', reason: 'no-measurement' });
    expect(judgeCaptureLength({ measuredMs: 1_000, expectedMs: 200_000, cfg: { ...D, enabled: false } }))
      .toMatchObject({ verdict: 'skip', reason: 'disabled' });
  });

  it('ANALOG: exempt unless the expected length is reliably known', () => {
    // vinyl catalog length is NOT trusted for an Apple Music capture of an analog song
    const noMusic = resolveExpectedLength({ catalogMs: 200_000, sourceType: 'analog' });
    expect(noMusic).toEqual({ expectedMs: null, source: null, analog: true });
    expect(judgeCaptureLength({ measuredMs: 30_000, expectedMs: noMusic.expectedMs, analog: true }))
      .toMatchObject({ verdict: 'skip', reason: 'analog-exempt' });
    // Music.app's own duration for the track it played IS reliable → the rule applies
    const withMusic = resolveExpectedLength({ catalogMs: 200_000, musicMs: 180_000, sourceType: 'analog' });
    expect(withMusic).toMatchObject({ expectedMs: 180_000, source: 'music', analog: true });
    expect(judgeCaptureLength({ measuredMs: 30_000, expectedMs: withMusic.expectedMs, analog: true }).verdict).toBe('short');
  });

  it('expected length precedence: catalog → adhoc → Music.app → none', () => {
    expect(resolveExpectedLength({ catalogMs: 1000, adhocMs: 2000, musicMs: 3000 })).toMatchObject({ expectedMs: 1000, source: 'catalog' });
    expect(resolveExpectedLength({ catalogMs: 0, adhocMs: 2000, musicMs: 3000 })).toMatchObject({ expectedMs: 2000, source: 'adhoc' });
    expect(resolveExpectedLength({ musicMs: 3000 })).toMatchObject({ expectedMs: 3000, source: 'music' });
    expect(resolveExpectedLength({})).toMatchObject({ expectedMs: null, source: null });
  });

  it('every threshold is an env knob', () => {
    const c = lengthGuardConfig({ RIP_LENGTH_UNDER_RATIO: '0.9', RIP_LENGTH_UNDER_SLACK_MS: '7000',
      RIP_LENGTH_OVER_SLACK_MS: '30000', RIP_LENGTH_SILENCE_DB: '-55', RIP_LENGTH_GUARD: '0' });
    expect(c).toMatchObject({ enabled: false, underRatio: 0.9, underSlackMs: 7000, overSlackMs: 30000, silenceDb: -55 });
    expect(lengthGuardConfig({})).toMatchObject({ enabled: true, underRatio: 0.95, underSlackMs: 5000, overSlackMs: 20000 });
  });

  it('describeVerdict prints both lengths on one line', () => {
    const line = describeVerdict('sng_62bf34d1ac4d', judgeCaptureLength({ measuredMs: 54_300, expectedMs: 221_043 }), 'catalog');
    expect(line).toContain('short-capture');
    expect(line).toContain('54.3s');
    expect(line).toContain('221.0s');
  });
});

describe('judgeCaptureLength — Apple Music editions (Music.app duration)', () => {
  it('ACCEPTS a complete capture of a shorter edition: Music.app agrees with the capture', () => {
    // Real repair-queue cases: catalog 266.0 s, Music.app 227.2 s, captured 229.4 s (and two more).
    for (const [m, e, music] of [[229_376, 266_000, 227_227], [128_672, 142_560, 126_520], [197_621, 217_600, 196_075]]) {
      const v = judgeCaptureLength({ measuredMs: m, expectedMs: e, musicMs: music });
      expect(v.verdict).toBe('ok');
      expect(v.reason).toBe('shorter-edition');
      expect(v.editionMs).toBe(music);
      expect(v.expectedMs).toBe(e);
    }
  });

  it('STILL REJECTS a partial: 54 s captured while Music.app reports the full 221 s', () => {
    const v = judgeCaptureLength({ measuredMs: 54_300, expectedMs: 221_043, musicMs: 221_043 });
    expect(v.verdict).toBe('short');
    expect(v.reason).toBe('short-capture');
    // and a partial of a shorter edition is short against the edition too
    expect(judgeCaptureLength({ measuredMs: 60_000, expectedMs: 266_000, musicMs: 227_227 }).verdict).toBe('short');
  });

  it('no Music.app duration → the catalog rule alone (old behaviour)', () => {
    for (const musicMs of [null, undefined, 0, NaN]) {
      const v = judgeCaptureLength({ measuredMs: 229_376, expectedMs: 266_000, musicMs });
      expect(v.verdict).toBe('short');
      expect(v.reason).toBe('short-capture');
      expect(v.editionMs).toBeUndefined();
    }
  });

  it('a Music.app duration LONGER than catalog never rescues a short capture (and vice versa)', () => {
    expect(judgeCaptureLength({ measuredMs: 229_376, expectedMs: 266_000, musicMs: 280_000 }).verdict).toBe('short');
    expect(judgeCaptureLength({ measuredMs: 120_000, expectedMs: 90_000, musicMs: 80_000 }).verdict).toBe('long');
  });

  it('ACCEPTS a complete capture of a longer edition', () => {
    const v = judgeCaptureLength({ measuredMs: 140_000, expectedMs: 100_000, musicMs: 138_000 });
    expect(v).toMatchObject({ verdict: 'ok', reason: 'longer-edition', editionMs: 138_000 });
  });

  it('describeVerdict names both lengths and says accepted', () => {
    const v = judgeCaptureLength({ measuredMs: 229_376, expectedMs: 266_000, musicMs: 227_227 });
    expect(describeVerdict('sng_cb4c627fcae5', v, 'catalog'))
      .toBe('LENGTH-GUARD sng_cb4c627fcae5 shorter-edition: measured 229.4s ≈ Music.app 227.2s vs catalog 266.0s — accepted');
  });

  it('audit honours a recorded editionMs (no re-flag of an accepted edition)', () => {
    const manifest = { sng_ed: { source: 'digital', key: 'rips/sng_ed.mp3', durationMs: 229_376, editionMs: 227_227 } };
    const a = auditManifestLengths(manifest, () => ({ length: 266_000, sourceType: 'digital' }));
    expect(a.violations).toEqual([]);
    expect(a.ok).toBe(1);
  });
});

describe('trailing-silence trim decision', () => {
  it('trims only a silent run that reaches the end, never below expected', () => {
    // sng_f2369436e930: expected 248.1 s, file 261.5 s, silence 249.5 → end
    const s = parseSilences('silence_start: 0\nsilence_end: 1.141\nsilence_start: 249.508208\nsilence_end: 261.504');
    expect(s).toEqual([{ startMs: 0, endMs: 1141 }, { startMs: 249508, endMs: 261504 }]);
    expect(trailingTrimMs({ durationMs: 261_504, expectedMs: 248_133, silences: s })).toBe(249_758);
    // silence starts BEFORE expected → cut at expected (music is never trimmed — it's silent there)
    expect(trailingTrimMs({ durationMs: 230_000, expectedMs: 225_000, silences: [{ startMs: 220_000, endMs: 230_000 }] })).toBe(225_000);
  });
  it('does not trim when the tail is music (silence ended before EOF) or there is no overrun', () => {
    expect(trailingTrimMs({ durationMs: 276_352, expectedMs: 264_487, silences: [{ startMs: 233_657, endMs: 234_306 }] })).toBeNull();
    expect(trailingTrimMs({ durationMs: 200_000, expectedMs: 200_000, silences: [{ startMs: 190_000, endMs: null }] })).toBeNull();
    expect(trailingTrimMs({ durationMs: 210_000, expectedMs: 200_000, silences: [] })).toBeNull();
  });
  it('an open-ended silence (no silence_end) counts as reaching EOF', () => {
    expect(parseSilences('silence_start: 12.5')).toEqual([{ startMs: 12500, endMs: null }]);
    expect(trailingTrimMs({ durationMs: 20_000, expectedMs: 10_000, silences: [{ startMs: 12_500, endMs: null }] })).toBe(12_750);
  });
});

describe('repair bookkeeping (pure)', () => {
  const catalog = {
    sng_62bf34d1ac4d: { length: 221_043, sourceType: 'digital' },
    sng_4daf33a6456b: { length: 377_920, sourceType: 'digital' },
    sng_75219d713df3: { length: 249_613, sourceType: 'digital' },
    sng_healthy00001: { length: 155_000, sourceType: 'digital' },
    sng_toolong00001: { length: 90_673, sourceType: 'digital' },
    sng_vinyl0000001: { length: 200_000, sourceType: 'analog' },
  };
  const manifest = {
    sng_62bf34d1ac4d: { source: 'digital', key: 'rips/sng_62bf34d1ac4d.mp3', durationMs: 54_300, analyzed: true },
    sng_4daf33a6456b: { source: 'digital', key: 'rips/sng_4daf33a6456b.mp3', durationMs: 39_400 },
    sng_75219d713df3: { source: 'digital', key: 'rips/sng_75219d713df3.mp3', durationMs: 63_700 },
    sng_healthy00001: { source: 'digital', key: 'rips/sng_healthy00001.mp3', durationMs: 168_000 },
    sng_toolong00001: { source: 'digital', key: 'rips/sng_toolong00001.mp3', durationMs: 210_500 },
    sng_vinyl0000001: { source: 'digital', key: 'rips/sng_vinyl0000001.mp3', durationMs: 30_000 },  // cloud rip of a vinyl song
    sng_albumsong001: { source: 'analog', key: 'rips/alb_x.mp3', durationMs: 10 },                  // album entry
    amrec_1234: { source: 'digital', key: 'rips/amrec_1234.mp3', durationMs: 5_000 },              // ad-hoc, no catalog
  };
  const lookup = (id) => catalog[id] || null;

  it('audit lists exactly the short + long per-song captures, with both lengths', () => {
    const a = auditManifestLengths(manifest, lookup);
    expect(a.violations.map((v) => v.songId).sort()).toEqual(['sng_4daf33a6456b', 'sng_62bf34d1ac4d', 'sng_75219d713df3', 'sng_toolong00001']);
    expect(a.violations.find((v) => v.songId === 'sng_62bf34d1ac4d')).toMatchObject({ verdict: 'short', measuredMs: 54_300, expectedMs: 221_043, expectedSource: 'catalog' });
    expect(a.violations.find((v) => v.songId === 'sng_toolong00001').reason).toBe('long-capture');
    expect(a.ok).toBe(1);
    expect(a.skipped).toMatchObject({ analogExempt: 1, notPerSong: 1, noExpectedLength: 1 });
  });

  it('audit can be narrowed to songIds', () => {
    const a = auditManifestLengths(manifest, lookup, { songIds: ['sng_62bf34d1ac4d', 'sng_healthy00001', 'sng_nope'] });
    expect(a.violations.map((v) => v.songId)).toEqual(['sng_62bf34d1ac4d']);
    expect(a.skipped.missing).toBe(1);
  });

  it('repair targets: the rip + every derived artifact, and nothing that is not this song', () => {
    const e = {
      key: 'rips/sng_62bf34d1ac4d.mp3', waveform: 'rips/waveforms/sng_62bf34d1ac4d.png',
      beatgrid: 'rips/analysis/sng_62bf34d1ac4d.json', lyrics: 'rips/lyrics/sng_62bf34d1ac4d.json',
      timbre: 'rips/timbre/v1/sng_62bf34d1ac4d.json',
      stems: { vocals: 'rips/stems/sng_62bf34d1ac4d/vocals.mp3' },
      // a corrupt entry pointing at shared/other objects must never steer a delete
      bogus: 'x', cutKey: 'rips/alb_x.mp3',
    };
    const t = repairTargetsFor('sng_62bf34d1ac4d', { ...e, waveform: 'rips/waveforms/OTHER.png' }, { timbreVersions: [1, 2] });
    expect(t.objects).toEqual([
      'rips/analysis/sng_62bf34d1ac4d.json', 'rips/lyrics/sng_62bf34d1ac4d.json', 'rips/sng_62bf34d1ac4d.mp3',
      'rips/timbre/v1/sng_62bf34d1ac4d.json', 'rips/timbre/v2/sng_62bf34d1ac4d.json', 'rips/waveforms/sng_62bf34d1ac4d.png',
    ]);
    expect(t.prefixes).toEqual(['rips/stems/sng_62bf34d1ac4d/']);
    expect(t.objects.every((k) => k.includes('sng_62bf34d1ac4d'))).toBe(true);
    // a base id never matches its variant's objects
    expect(repairTargetsFor('sng_aaaaaaaaaaaa', { key: 'rips/sng_aaaaaaaaaaaa_clean.mp3' }).objects)
      .not.toContain('rips/sng_aaaaaaaaaaaa_clean.mp3');
  });

  it('pre-repair timbre rows are dropped; post-repair rows are kept', () => {
    const rows = new Map([['a', { atMs: 100 }], ['b', { atMs: 900 }], ['c', { atMs: 100 }]]);
    expect(dropPreRepairRows(rows, { a: { at: 500 }, b: { at: 500 } })).toBe(1);
    expect([...rows.keys()].sort()).toEqual(['b', 'c']);
  });
});

// ── the real measure → trim → judge path on synthesized audio (ffmpeg on PATH) ──
const hasFfmpeg = spawnSync('ffmpeg', ['-version']).status === 0 && spawnSync('ffprobe', ['-version']).status === 0;
describe.skipIf(!hasFfmpeg)('guardCaptureFile (ffprobe + ffmpeg)', () => {
  let dir;
  const tone = (name, toneS, silenceS = 0) => {
    const f = join(dir, name);
    const filter = silenceS
      ? `sine=frequency=440:duration=${toneS}[a];anullsrc=r=44100:cl=stereo,atrim=duration=${silenceS}[s];[a]aformat=channel_layouts=stereo[a2];[a2][s]concat=n=2:v=0:a=1`
      : `sine=frequency=440:duration=${toneS}`;
    execFileSync('ffmpeg', ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=44100:cl=stereo',
      '-filter_complex', filter, '-t', String(toneS + silenceS), '-codec:a', 'libmp3lame', '-b:a', '128k', f]);
    return f;
  };
  beforeAll(() => { dir = mkdtempSync(join(tmpdir(), 'pdj-lenguard-')); });
  afterAll(() => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ } });

  it('a short capture is rejected and the file left untouched', () => {
    const f = tone('short.mp3', 4);
    const v = guardCaptureFile(f, { expectedMs: 20_000 });
    expect(v.verdict).toBe('short');
    expect(probeDurationMs(f)).toBeGreaterThan(3_900);
  });

  it('a small overrun with a SILENT tail is trimmed down to just past the music', () => {
    const f = tone('tail.mp3', 10, 6);
    const before = probeDurationMs(f);
    expect(before).toBeGreaterThan(15_900);
    const v = guardCaptureFile(f, { expectedMs: 10_000 });
    expect(v.verdict).toBe('ok');
    expect(v.trimmedFromMs).toBe(before);
    expect(v.measuredMs).toBeLessThan(11_000);
    expect(v.measuredMs).toBeGreaterThanOrEqual(10_000);
    expect(probeDurationMs(f)).toBe(v.measuredMs);
  });

  it('an overrun of MUSIC is never trimmed', () => {
    const f = tone('music.mp3', 14);
    const v = guardCaptureFile(f, { expectedMs: 10_000 });
    expect(v.verdict).toBe('ok');
    expect(v.trimmedFromMs).toBeUndefined();
    expect(v.measuredMs).toBeGreaterThan(13_900);
  });

  it('a long capture whose excess is music is long-capture; a long SILENT tail is trimmed to ok', () => {
    expect(guardCaptureFile(tone('long.mp3', 33), { expectedMs: 10_000 }).verdict).toBe('long');
    const v = guardCaptureFile(tone('longsilent.mp3', 10, 25), { expectedMs: 10_000 });
    expect(v.verdict).toBe('ok');
    expect(v.measuredMs).toBeLessThan(11_000);
  });

  it('no expected length → skip (accepted), and the skip says why', () => {
    const v = guardCaptureFile(tone('noexp.mp3', 2), { expectedMs: null });
    expect(v).toMatchObject({ verdict: 'skip', reason: 'no-expected-length' });
  });
});
