// Album card (grid) and Song row (list) presentations for the browser.
import { useNavigate } from 'react-router-dom';
import type { AlbumItem, SongItem } from '../../types/model';
import { Thumbnail } from '../common/Thumbnail';
import { PlugInIndicator } from './PlugInIndicator';
import { msToClock } from '../../lib/format';

export function AlbumCard({ album, onEdit }: { album: AlbumItem; onEdit: (id: string) => void }) {
  const navigate = useNavigate();
  const meta = [album.year, album.genre, `${album.trackIds.length} tracks`].filter(Boolean).join(' · ');
  return (
    <div
      className="pdj-card"
      data-testid={`item-card-${album.id}`}
      role="button"
      tabIndex={0}
      onClick={() => navigate(`/map/${album.id}`)}
      onKeyDown={(e) => e.key === 'Enter' && navigate(`/map/${album.id}`)}
      title={`${album.artist} — ${album.name}`}
    >
      <Thumbnail artKey={album.coverArtKey} alt={`${album.artist} – ${album.name}`} size={150} className="pdj-card__art" />
      <div className="pdj-card__body">
        <div className="pdj-card__title" title={album.name}>{album.name}</div>
        <div className="pdj-card__artist" title={album.artist}>{album.artist}</div>
        <div className="pdj-card__meta">{meta || '—'}</div>
        {album.country && <div className="pdj-card__country">{album.country}</div>}
      </div>
      <div className="pdj-card__actions">
        <PlugInIndicator id={album.id} pointer={album.pointer} />
        <button
          className="pdj-iconbtn"
          data-testid={`edit-item-open-${album.id}`}
          onClick={(e) => {
            e.stopPropagation();
            onEdit(album.id);
          }}
          aria-label="Edit album"
        >
          ✎
        </button>
      </div>
      {album.enrichment?.status === 'unmatched' && <span className="pdj-card__flag" title="Not matched — fill metadata manually">unmatched</span>}
    </div>
  );
}

export function SongRow({
  song,
  onEdit,
  onOpen,
}: {
  song: SongItem;
  onEdit: (id: string) => void;
  onOpen: (id: string) => void;
}) {
  return (
    <div
      className="pdj-song"
      data-testid={`song-row-${song.id}`}
      role="button"
      tabIndex={0}
      onClick={() => onOpen(song.id)}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onOpen(song.id);
        }
      }}
      title={`${song.name} — view details`}
    >
      <span className="pdj-song__track">{song.trackNumber ?? '–'}</span>
      <span className="pdj-song__name" title={song.name}>
        {song.name}
        {song.explicit && <span className="pdj-song__explicit" title="Explicit">E</span>}
      </span>
      <span className="pdj-song__artist" title={song.artist}>{song.artist}</span>
      <span className="pdj-song__len">{msToClock(song.lengthMs)}</span>
      <span className="pdj-song__bpm" title="BPM">{song.bpm != null ? song.bpm : '–'}</span>
      <span className="pdj-song__key" title={song.key ?? 'Key'}>
        {song.key ? <span className="pdj-song__keyname">{song.key}</span> : <span className="pdj-song__keyname">–</span>}
        {song.camelot && <span className="pdj-song__camelot">{song.camelot}</span>}
      </span>
      <span className="pdj-song__tags">
        {(song.sentimentKeywords ?? []).slice(0, 3).map((k) => (
          <span key={k} className="pdj-tag">
            {k}
          </span>
        ))}
      </span>
      <span className="pdj-song__actions">
        <PlugInIndicator id={song.id} pointer={song.pointer} />
        <button
          className="pdj-iconbtn"
          data-testid={`edit-item-open-${song.id}`}
          onClick={(e) => {
            e.stopPropagation();
            onEdit(song.id);
          }}
          aria-label="Edit song"
        >
          ✎
        </button>
      </span>
    </div>
  );
}
