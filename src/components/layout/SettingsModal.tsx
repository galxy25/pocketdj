// Settings panel: catalog info + a FORCE REFRESH that clears this device's cached app
// shell + data and re-pulls the latest seed (fixes "stale data/UI on my phone").
import { useEffect, useState } from 'react';
import { Modal } from '../common/Modal';
import { forceRefreshCatalog } from '../../lib/dataActions';
import { countItems, getSources } from '../../storage/repo';
import { CURRENT_DATA_VERSION, getDataVersion, runMigrations } from '../../storage/migrations';

export function SettingsModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [counts, setCounts] = useState<{ albums: number; songs: number } | null>(null);
  const [source, setSource] = useState('—');
  const [busy, setBusy] = useState(false);
  const [dataVersion, setDataVersion] = useState<number | null>(null);
  const [migrating, setMigrating] = useState(false);
  const [migrateMsg, setMigrateMsg] = useState('');

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const [c, srcs, dv] = await Promise.all([countItems(), getSources(), getDataVersion()]);
      if (cancelled) return;
      setCounts(c);
      setSource(srcs[0]?.name ?? '—');
      setDataVersion(dv);
    })();
    return () => {
      cancelled = true;
    };
  }, [open]);

  const refresh = async () => {
    setBusy(true);
    await forceRefreshCatalog(); // clears caches + DB, then reloads the page
  };

  const migrate = async () => {
    setMigrating(true);
    setMigrateMsg('');
    try {
      const r = await runMigrations();
      setDataVersion(r.to);
      setMigrateMsg(
        r.ran.length ? `Migrated v${r.from} → v${r.to}: ${r.ran.join(', ')}` : `Already current (v${r.to}).`,
      );
    } finally {
      setMigrating(false);
    }
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

        <hr className="pdj-settings__rule" />

        <div className="pdj-settings__stat">
          <span>Data version</span>
          <strong data-testid="settings-data-version">
            {dataVersion == null ? '…' : `v${dataVersion}`}
            {dataVersion != null && dataVersion < CURRENT_DATA_VERSION && ` → v${CURRENT_DATA_VERSION}`}
          </strong>
        </div>
        <p className="pdj-settings__hint">
          Run migrations to bring your pockets &amp; playlists up to the current data version
          when syncing across devices. This is non-destructive — unlike Force refresh, it
          keeps your data.
        </p>
        <button
          type="button"
          className="pdj-btn pdj-btn--ghost"
          data-testid="settings-migrate"
          disabled={migrating}
          onClick={() => void migrate()}
        >
          {migrating ? 'Migrating…' : '⬆ Run migrations'}
        </button>
        {migrateMsg && (
          <p className="pdj-settings__hint" data-testid="settings-migrate-msg">
            {migrateMsg}
          </p>
        )}
      </div>
    </Modal>
  );
}
