// Album AUDIO track-by-track popup, shown when the central "sun" (album cover) is
// clicked in the solar system. Reuses the shared Modal (top-right ✕, Escape,
// backdrop close). Renders album.audioTracks AS-IS — the AUDIO ground truth from
// the analog-indexer audio stage. IMPORTANT: this segmentation is independent of
// the metadata tracklist, so the row count may differ from the song list by
// design; we never zip 1:1 against songs here.
import type { AlbumItem } from '../../types/model';
import { Modal } from '../common/Modal';
import { AudioTracksTable } from './AudioTracksTable';

interface Props {
  album: AlbumItem | null;
  open: boolean;
  onClose: () => void;
}

export function AudioTracksModal({ album, open, onClose }: Props) {
  const title = album ? `${album.name} — Audio` : 'Audio';
  return (
    <Modal open={open} onClose={onClose} title={title} testId="audio-tracks-modal">
      {album && <AudioTracksTable album={album} />}
    </Modal>
  );
}
