// Song metadata popup shown when a track is clicked in the browser or solar system.
// Reuses the shared Modal (top-right ✕, Escape, backdrop close). LAZY-loads lyrics: the
// lean seed ships without lyrics, so when this card opens for a song whose lyricsStatus
// is "found" but whose lyrics aren't stored yet, we fetch /lyrics/<songId>.txt and cache
// it in IndexedDB — so an install only ever stores the lyrics you actually look at.
import { useEffect, useState, type ReactNode } from 'react';
import { isSong, isAlbum, type SongItem } from '../../types/model';
import { getItem, putItem } from '../../storage/repo';
import { Modal } from '../common/Modal';
import { Thumbnail } from '../common/Thumbnail';
import { AddToCollectionButton } from '../common/AddToCollectionButton';
import { msToClock } from '../../lib/format';
import './songDetailActions.css';

/** Guard against a missing lyrics file falling through to the SPA index.html (the old
 *  "page-dump" bug): never treat markup as lyrics — whether it came from storage or the network. */
const looksLikeMarkup = (t?: string | null): boolean =>
  /^<(?:!doctype|html|\?xml|head|body|script|div)\b/i.test((t ?? '').trim());

interface Props {
  song: SongItem | null;
  albumName: string;
  onClose: () => void;
  /** Show the album cover art. Off for the solar/star-map view (it IS the album art). */
  showCoverArt?: boolean;
}

export function SongDetailModal({ song, albumName, onClose, showCoverArt = true }: Props) {
  const [lyrics, setLyrics] = useState<string | undefined>(undefined);
  const [lyricsStatus, setLyricsStatus] = useState<string | undefined>(undefined);
  const [coverArtKey, setCoverArtKey] = useState<string | undefined>(undefined);

  // Resolve the owning album's cover art (song.albumId → album.coverArtKey).
  useEffect(() => {
    setCoverArtKey(undefined);
    if (!showCoverArt || !song?.albumId) return;
    let live = true;
    (async () => {
      const a = await getItem(song.albumId as string);
      if (live && a && isAlbum(a)) setCoverArtKey(a.coverArtKey);
    })();
    return () => {
      live = false;
    };
  }, [song, showCoverArt]);

  const albumHref = song?.albumId ? `${import.meta.env.BASE_URL}album/${song.albumId}` : undefined;

  useEffect(() => {
    if (!song) {
      setLyrics(undefined);
      setLyricsStatus(undefined);
      return;
    }
    const storedLyrics = song.lyrics && !looksLikeMarkup(song.lyrics) ? song.lyrics : undefined;
    setLyrics(storedLyrics);
    // A record poisoned with markup by the old bug reports lyricsStatus:'found' — don't trust it.
    setLyricsStatus(storedLyrics ? song.lyricsStatus : song.lyricsStatus === 'found' ? undefined : song.lyricsStatus);
    if (storedLyrics) return; // already have valid lyrics
    if (!storedLyrics && song.lyricsStatus && song.lyricsStatus !== 'found' && !song.lyrics) return; // known: none to fetch
    let live = true;
    (async () => {
      // 1) cached in IndexedDB from a previous view?
      const cached = await getItem(song.id);
      if (!live) return;
      if (cached && isSong(cached) && cached.lyrics && !looksLikeMarkup(cached.lyrics)) {
        setLyrics(cached.lyrics);
        return;
      }
      // Scrub a previously-poisoned record (markup saved as lyrics) so it isn't shown again.
      if (song.lyrics && looksLikeMarkup(song.lyrics)) {
        const base = cached && isSong(cached) ? cached : song;
        const { lyrics: _poisoned, ...rest } = base;
        void _poisoned;
        await putItem({ ...rest, lyricsStatus: 'notfound' });
      }
      // 2) lazy-fetch from the lyrics CDN, then store so it's cached + offline-durable
      try {
        const res = await fetch(`${import.meta.env.BASE_URL}lyrics/${song.id}.txt`);
        if (!live) return;
        const ctype = res.headers.get('content-type') || '';
        // A missing lyrics file falls through to the SPA index.html (often HTTP 200) on both
        // the Vite dev server and the S3/CloudFront site — so a plain !res.ok check isn't enough.
        // Reject html content-types AND bodies that look like markup, so we never render the
        // app's own HTML as "lyrics".
        if (!res.ok || ctype.includes('text/html')) {
          setLyricsStatus('notfound');
          return;
        }
        const text = (await res.text()).trim();
        if (!live) return;
        if (!text || /^<(?:!doctype|html|\?xml|head|body|script|div)\b/i.test(text)) {
          setLyricsStatus('notfound');
          return;
        }
        setLyrics(text);
        setLyricsStatus('found');
        const base = cached && isSong(cached) ? cached : song;
        await putItem({ ...base, lyrics: text, lyricsStatus: 'found' });
      } catch {
        /* offline or missing — leave as-is */
      }
    })();
    return () => {
      live = false;
    };
  }, [song]);

  return (
    <Modal open={song != null} onClose={onClose} title={song ? song.name : 'Song'} testId="song-modal">
      {song && (
        <div className="pdj-songdetail" data-testid="song-detail">
          {showCoverArt && (
            <div className="pdj-songdetail__cover" data-testid="song-detail-cover">
              <Thumbnail artKey={coverArtKey} alt={albumName || song.name} size={120} />
            </div>
          )}
          <Row label="Track">{song.trackNumber ?? '—'}</Row>
          <Row label="Artist">{song.artist}</Row>
          <Row label="Album">
            {albumHref ? (
              <a
                className="pdj-songdetail__albumlink"
                href={albumHref}
                target="_blank"
                rel="noreferrer"
                data-testid="song-detail-album-link"
                title="Open album in a new tab"
              >
                {albumName || '(album)'} ↗
              </a>
            ) : (
              albumName || '—'
            )}
          </Row>
          <Row label="Genre">{song.genre ?? '—'}</Row>
          <Row label="Year">{song.year ?? '—'}</Row>
          <Row label="Length">{msToClock(song.lengthMs) || '—'}</Row>
          <Row label="Explicit">{song.explicit ? 'Yes' : 'No'}</Row>
          <Row label="BPM">{song.bpm ?? '— (pending audio)'}</Row>
          <Row label="Key">{song.key ?? '— (pending audio)'}</Row>
          <Row label="Camelot">{song.camelot ?? '— (pending audio)'}</Row>
          <Row label="Sentiment">
            {song.sentimentKeywords.length ? (
              <span className="pdj-songdetail__tags">
                {song.sentimentKeywords.map((k) => (
                  <span key={k} className="pdj-tag">
                    {k}
                  </span>
                ))}
              </span>
            ) : (
              '—'
            )}
          </Row>
          {song.pointer && (
            <Row label="Plug in">
              <span className="pdj-songdetail__plug">
                {song.pointer.location && <>📦 {song.pointer.location} </>}
                {song.pointer.disc != null && <>· disc {song.pointer.disc} </>}
                {song.pointer.track != null && <>· track {song.pointer.track}</>}
                {song.pointer.filename && (
                  <>
                    <br />
                    <code>{song.pointer.filename}</code>
                  </>
                )}
              </span>
            </Row>
          )}
          {lyrics ? (
            <div className="pdj-songdetail__lyrics">
              <div className="pdj-songdetail__lyrics-head">Lyrics</div>
              <pre>{lyrics}</pre>
            </div>
          ) : (
            <Row label="Lyrics">
              {lyricsStatus === 'notfound' ? 'Not found' : lyricsStatus === 'found' ? 'Loading…' : '—'}
            </Row>
          )}
          <div className="pdj-songdetail__actions">
            <AddToCollectionButton item={{ kind: 'song', id: song.id, name: song.name }} />
            <button
              type="button"
              className="pdj-songdetail__close"
              data-testid="song-detail-close"
              onClick={onClose}
            >
              Close
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="pdj-songdetail__row">
      <span className="pdj-songdetail__label">{label}</span>
      <span className="pdj-songdetail__value">{children}</span>
    </div>
  );
}
