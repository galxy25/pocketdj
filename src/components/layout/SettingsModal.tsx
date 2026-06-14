// Settings panel: catalog info + a FORCE REFRESH that clears this device's cached app
// shell + data and re-pulls the latest seed (fixes "stale data/UI on my phone").
import { useEffect, useState } from 'react';
import { Modal } from '../common/Modal';
import { forceRefreshCatalog } from '../../lib/dataActions';
import { countItems, getSources } from '../../storage/repo';

export function SettingsModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [counts, setCounts] = useState<{ albums: number; songs: number } | null>(null);
  const [source, setSource] = useState('—');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const [c, srcs] = await Promise.all([countItems(), getSources()]);
      if (cancelled) return;
      setCounts(c);
      setSource(srcs[0]?.name ?? '—');
    })();
    return () => {
      cancelled = true;
    };
  }, [open]);

  const refresh = async () => {
    setBusy(true);
    await forceRefreshCatalog(); // clears caches + DB, then reloads the page
  };

  return (
    <Modal open={open} onClose={onClose} title="Settings" testId="settings-modal">
      <div className="pdj-settings">
        <div className="pdj-settings__stat">
          <span>Catalog</span>
          <strong>{counts ? `${counts.albums} albums · ${counts.songs} songs` : '…'}</strong>
        </div>
        <div className="pdj-settings__stat">
          <span>Source</span>
          <strong>{source}</strong>
        </div>
        <p className="pdj-settings__hint">
          Seeing old data or a stale layout? Force a refresh to clear this device's cached
          app + data and re-pull the latest catalog from the server.
        </p>
        <button
          type="button"
          className="pdj-btn"
          data-testid="settings-refresh"
          disabled={busy}
          onClick={refresh}
        >
          {busy ? 'Refreshing…' : '↻ Force refresh & re-pull catalog'}
        </button>
      </div>
    </Modal>
  );
}
