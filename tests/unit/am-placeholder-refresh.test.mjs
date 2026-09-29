import { describe, it, expect } from 'vitest';
import {
  isPlaceholderTitle, isPlaceholderAlbum, placeholderCandidates, mergeRefreshed, fillCatalogIds,
} from '../../scripts/lib/am-placeholder-refresh.mjs';

const song = (id, albumId, name, trackNumber, extra = {}) =>
  ({ id, albumId, artist: 'FLO', name, trackNumber, pointer: { disc: 1, track: trackNumber, timestamps: null }, ...extra });

describe('placeholder detection', () => {
  it('matches Apple pre-release placeholders only', () => {
    expect(isPlaceholderTitle('Track 16')).toBe(true);
    expect(isPlaceholderTitle('track 3 ')).toBe(true);
    expect(isPlaceholderTitle('Track 16 (Remix)')).toBe(false);
    expect(isPlaceholderTitle('Haterbooth')).toBe(false);
    expect(isPlaceholderAlbum("Sorry, we don't have an album title yet ...")).toBe(true);
    expect(isPlaceholderAlbum('Sorry, we don’t have an album title yet')).toBe(true);
    expect(isPlaceholderAlbum('THERAPY AT THE CLUB')).toBe(false);
  });

  it('selects every song on an album that is still partly placeholder', () => {
    const albums = [{ id: 'a1', name: 'THERAPY AT THE CLUB' }, { id: 'a2', name: "Sorry, we don't have an album title yet ..." }, { id: 'a3', name: 'Done' }];
    const songs = [
      song('s1', 'a1', 'Track 1', 1), song('s2', 'a1', 'Leak It', 4),
      song('s3', 'a2', 'Witch Doctor', 4),
      song('s4', 'a3', 'Real', 1),
    ];
    expect([...placeholderCandidates(songs, albums)].sort()).toEqual(['s1', 's2', 's3']);
  });
});

describe('mergeRefreshed', () => {
  it('takes fresh metadata, keeps enrichment, and clears title-derived fields on a retitle', () => {
    const old = song('s1', 'a1', 'Track 16', 16, { explicit: true, bpm: 120, appleMusicId: null, spotifyUrl: 'x', lyricsStatus: 'none' });
    const { updated, renamed, touchedAlbums } = mergeRefreshed({
      oldById: new Map([[old.id, old]]),
      refreshedSongs: [song('s1', 'a1', 'Haterbooth', 16, { explicit: false, bpm: null })],
    });
    const s = updated.get('s1');
    expect(s.name).toBe('Haterbooth');
    expect(s.explicit).toBe(true);      // not from the re-read (AppleScript can't see it)
    expect(s.bpm).toBe(120);            // audio analysis survives a retitle
    expect(s.spotifyUrl).toBeUndefined();
    expect(s.lyricsStatus).toBeUndefined();
    expect([...renamed]).toEqual(['s1']);
    expect([...touchedAlbums]).toEqual(['a1']);
  });

  it('is a no-op when the re-read matches (so an unchanged night stays byte-identical)', () => {
    const old = song('s1', 'a1', 'Leak It', 4);
    const r = mergeRefreshed({ oldById: new Map([[old.id, old]]), refreshedSongs: [song('s1', 'a1', 'Leak It', 4)] });
    expect(r.updated.size).toBe(0);
    expect(r.renamed.size).toBe(0);
  });

  it('records both albums when a retitled album moves a song to a new album id', () => {
    const old = song('s1', 'a_old', 'Track 1', 1);
    const { touchedAlbums } = mergeRefreshed({ oldById: new Map([[old.id, old]]), refreshedSongs: [song('s1', 'a_new', 'Echos', 1)] });
    expect([...touchedAlbums].sort()).toEqual(['a_new', 'a_old']);
  });
});

describe('fillCatalogIds', () => {
  const tracks = [
    { trackId: 6790801803, trackName: 'Haterbooth', trackNumber: 16, discNumber: 1 },
    { trackId: 6790801581, trackName: 'Pose (Remix)', trackNumber: 10, discNumber: 1 },
  ];
  it('fills only when disc+track number AND the comparable title agree', () => {
    const { songs, filled } = fillCatalogIds([
      song('s16', 'a1', 'Haterbooth', 16),
      song('s10', 'a1', 'Pose', 10),               // version marker disagrees → no id
      song('s3', 'a1', 'Cry Ugly', 3),             // no lookup row at that position
      song('s9', 'a1', 'Track 9', 9),              // still a placeholder → never guessed
      song('sx', 'a1', 'Haterbooth', 16, { appleMusicId: '1' }),  // already has one
    ], tracks);
    expect(filled).toBe(1);
    expect(songs.map((s) => s.appleMusicId)).toEqual(['6790801803', undefined, undefined, undefined, '1']);
  });
});
