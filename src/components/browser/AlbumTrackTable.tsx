// Single-album browser view: open an album from the browser to see its TRACKS as a
// table (one row per track, same row as song-browser mode — bpm/key/Camelot, click for
// the detail card), with the album's AUDIO metadata (the solar-system sun-click info) in
// the footer. Reached at /album/:albumId (AlbumCard navigates here).
import { useCallback, useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { getItem, getAlbumSongs } from '../../storage/repo';
import { isAlbum, type AlbumItem, type SongItem } from '../../types/model';
import { Thumbnail } from '../common/Thumbnail';
import { SongRow } from './ItemCard';
import { EditItemModal } from './EditItemModal';
import { SongDetailModal } from '../starmap/SongDetailModal';
import { AudioTracksTable } from '../starmap/AudioTracksTable';
import { AudioEditModal } from '../starmap/AudioEditModal';
import { AddToCollectionButton } from '../common/AddToCollectionButton';
import './albumTrackTableActions.css';

export function AlbumTrackTable() {
  const { albumId } = useParams<{ albumId: string }>();
  const navigate = useNavigate();
  const [album, setAlbum] = useState<AlbumItem | null>(null);
  const [songs, setSongs] = useState<SongItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [editId, setEditId] = useState<string | null>(null);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [audioEditOpen, setAudioEditOpen] = useState(false);

  const load = useCallback(async () => {
    if (!albumId) {
      setLoading(false);
      return;
    }
    const item = await getItem(albumId);
    const found = item && isAlbum(item) ? item : null;
    const s = found ? await getAlbumSongs(albumId) : [];
    setAlbum(found);
    setSongs(s);
    setLoading(false);
  }, [albumId]);

  useEffect(() => {
    let live = true;
    setLoading(true);
    void load().finally(() => {
      if (!live) return;
    });
    return () => {
      live = false;
    };
  }, [load]);

  const detailSong = detailId ? songs.find((s) => s.id === detailId) ?? null : null;

  if (loading) {
    return (
      <div className="pdj-albumtable">
        <div className="pdj-grid__empty">Loading…</div>
      </div>
    );
  }
  if (!album) {
    return (
      <div className="pdj-albumtable">
        <button className="pdj-btn pdj-btn--sm pdj-btn--ghost" onClick={() => navigate(-1)}>
          ← Back
        </button>
        <div className="pdj-grid__empty">Album not found.</div>
      </div>
    );
  }

  const meta = [album.year, album.genre, `${songs.length} tracks`].filter(Boolean).join(' · ');

  return (
    <div className="pdj-albumtable" data-testid="album-track-table">
      <div className="pdj-albumtable__head">
        <button
          className="pdj-btn pdj-btn--sm pdj-btn--ghost"
          data-testid="album-back"
          onClick={() => navigate(-1)}
        >
          ← Back
        </button>
        <Thumbnail
          artKey={album.coverArtKey}
          alt={`${album.artist} – ${album.name}`}
          size={72}
          className="pdj-albumtable__art"
        />
        <div className="pdj-albumtable__title">
          <div className="pdj-albumtable__name" title={album.name}>
            {album.name}
          </div>
          <div className="pdj-albumtable__artist" title={album.artist}>
            {album.artist}
          </div>
          <div className="pdj-albumtable__meta">{meta || '—'}</div>
        </div>
        <button
          className="pdj-btn pdj-btn--sm pdj-btn--ghost"
          data-testid="album-solar"
          onClick={() => navigate('/map/' + album.id)}
          title="View as solar system"
        >
          ◎ Solar
        </button>
      </div>

      <div className="pdj-albumtable__tracks" data-testid="album-tracks">
        {songs.length === 0 ? (
          <div className="pdj-grid__empty">No tracks for this album.</div>
        ) : (
          songs.map((s) => <SongRow key={s.id} song={s} onEdit={setEditId} onOpen={setDetailId} />)
        )}
      </div>

      <div className="pdj-albumtable__editbar">
        <button
          className="pdj-btn pdj-btn--sm pdj-btn--ghost"
          data-testid="edit-album"
          onClick={() => setEditId(album.id)}
        >
          ✎ Edit album info
        </button>
        <AddToCollectionButton item={{ kind: 'album', id: album.id, name: album.name }} />
      </div>

      <div className="pdj-albumtable__audio" data-testid="album-audio-footer">
        <h3 className="pdj-albumtable__audiohead">Album audio analysis</h3>
        <AudioTracksTable album={album} />
        <div className="pdj-albumtable__editbar">
          <button
            className="pdj-btn pdj-btn--sm pdj-btn--ghost"
            data-testid="edit-audio"
            onClick={() => setAudioEditOpen(true)}
          >
            ✎ Edit audio analysis
          </button>
        </div>
      </div>

      <EditItemModal itemId={editId} onClose={() => setEditId(null)} onSaved={load} />
      <AudioEditModal album={album} open={audioEditOpen} onClose={() => setAudioEditOpen(false)} onSaved={load} />
      <SongDetailModal song={detailSong} albumName={album.name} onClose={() => setDetailId(null)} />
    </div>
  );
}
