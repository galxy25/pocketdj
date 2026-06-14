import { describe, it, expect } from 'vitest';
import { audioRollup } from './importIndex';
import type { AudioTrack } from '../types/model';

function track(over: Partial<AudioTrack>): AudioTrack {
  return {
    trackNumber: 1,
    startMs: 0,
    endMs: 1000,
    durationMs: 1000,
    bpm: 120,
    key: 'A minor',
    camelot: '8A',
    ...over,
  };
}

describe('audioRollup', () => {
  it('returns all null for empty / missing tracks', () => {
    expect(audioRollup(undefined)).toEqual({ audioBpm: null, audioCamelot: null, audioKey: null });
    expect(audioRollup(null)).toEqual({ audioBpm: null, audioCamelot: null, audioKey: null });
    expect(audioRollup([])).toEqual({ audioBpm: null, audioCamelot: null, audioKey: null });
  });

  it('audioBpm is the rounded median of segment BPMs', () => {
    // odd count -> middle value
    expect(audioRollup([track({ bpm: 100 }), track({ bpm: 120 }), track({ bpm: 140 })]).audioBpm).toBe(120);
    // even count -> mean of the two middle, rounded
    expect(audioRollup([track({ bpm: 100 }), track({ bpm: 121 })]).audioBpm).toBe(111);
    // median is robust to an outlier (would skew a mean)
    expect(audioRollup([track({ bpm: 90 }), track({ bpm: 92 }), track({ bpm: 300 })]).audioBpm).toBe(92);
  });

  it('audioCamelot / audioKey are the most-common values', () => {
    const tracks = [
      track({ camelot: '8A', key: 'A minor' }),
      track({ camelot: '8A', key: 'A minor' }),
      track({ camelot: '5A', key: 'D minor' }),
    ];
    const r = audioRollup(tracks);
    expect(r.audioCamelot).toBe('8A');
    expect(r.audioKey).toBe('A minor');
  });

  it('breaks ties by first appearance (deterministic / idempotent)', () => {
    const tracks = [track({ camelot: '5A' }), track({ camelot: '8A' })];
    expect(audioRollup(tracks).audioCamelot).toBe('5A');
  });

  it('ignores empty / non-finite values when rolling up', () => {
    const tracks = [
      track({ bpm: NaN, camelot: '', key: '' }),
      track({ bpm: 128, camelot: '9B', key: 'E major' }),
    ];
    const r = audioRollup(tracks);
    expect(r.audioBpm).toBe(128);
    expect(r.audioCamelot).toBe('9B');
    expect(r.audioKey).toBe('E major');
  });
});
