// Settings panel: catalog info, full client-data backup/restore (export + import all
// data, so you can load an offline app from an export), a collections-preserving Force
// Refresh, data-version migrations, and a separate nuclear Reset.
import { useEffect, useRef, useState } from 'react';
import { Modal } from '../common/Modal';
import { forceRefreshCatalog, resetEverything } from '../../lib/dataActions';
import { downloadExportZip } from '../../storage/exportZip';
import { importFile } from '../../storage/importZip';
import { countItems, getSources } from '../../storage/repo';
import { CURRENT_DATA_VERSION, getDataVersion, runMigrations } from '../../storage/migrations';

export function SettingsModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [counts, setCounts] = useState<{ albums: number; songs: number } | null>(null);
  const [source, setSource] = useState('—');
  const [busy, setBusy] = useState(false);
  const [dataVersion, setDataVersion] = useState<number | null>(null);
  const [migrating, setMigrating] = useState(false);
  const [migrateMsg, setMigrateMsg] = useState('');
  const [transfer, setTransfer] = useState<'idle' | 'export' | 'import'>('idle');
  const [transferMsg, setTransferMsg] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

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
    await forceRefreshCatalog(); // catalog only — keeps pockets/playlists/setlists, then reloads
  };

  const resetAll = async () => {
    if (!window.confirm('Reset EVERYTHING on this device, including your pockets, playlists & set lists? This cannot be undone.')) return;
    setBusy(true);
    await resetEverything();
  };

  const doExport = async () => {
    setTransfer('export');
    setTransferMsg('');
    try {
      const m = await downloadExportZip('pocketdj-all-data.zip');
      setTransferMsg(
        `Exported ${m.counts.items} items, ${m.counts.playlists} playlists, ${m.counts.pockets} pockets, ${m.counts.art} covers.`,
      );
    } catch (e) {
      setTransferMsg(`Export failed: ${(e as Error).message}`);
    } finally {
      setTransfer('idle');
    }
  };

  const onImportFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setTransfer('import');
    setTransferMsg('');
    try {
      const r = await importFile(file);
      setTransferMsg(`Imported ${r.summary}. Reloading…`);
      setTimeout(() => window.location.reload(), 700);
    } catch (err) {
      setTransferMsg(`Import failed: ${(err as Error).message}`);
      setTransfer('idle');
    }
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

        <hr className="pdj-settings__rule" />

        <p className="pdj-settings__hint">
          Back up <em>everything</em> on this device — catalog, cover art, pockets, playlists
          &amp; set lists — to a single file. Import it on another device (or a fresh /
          offline install) to restore it all without a network.
        </p>
        <div className="pdj-settings__row">
          <input
            ref={fileRef}
            type="file"
            accept=".zip,.json"
            style={{ display: 'none' }}
            data-testid="settings-import-input"
            onChange={(e) => void onImportFile(e)}
          />
          <button
            type="button"
            className="pdj-btn"
            data-testid="settings-export-all"
            disabled={transfer !== 'idle'}
            onClick={() => void doExport()}
          >
            {transfer === 'export' ? 'Exporting…' : '⤓ Export all data'}
          </button>
          <button
            type="button"
            className="pdj-btn pdj-btn--ghost"
            data-testid="settings-import-all"
            disabled={transfer !== 'idle'}
            onClick={() => fileRef.current?.click()}
          >
            {transfer === 'import' ? 'Importing…' : '⤒ Import data'}
          </button>
        </div>
        {transferMsg && (
          <p className="pdj-settings__hint" data-testid="settings-transfer-msg">
            {transferMsg}
          </p>
        )}

        <hr className="pdj-settings__rule" />

        <p className="pdj-settings__hint">
          Seeing old data or a stale layout? Force a refresh to re-pull the latest app +
          catalog. <strong>Your pockets, playlists &amp; set lists are kept.</strong>
        </p>
        <button
          type="button"
          className="pdj-btn"
          data-testid="settings-refresh"
          disabled={busy}
          onClick={refresh}
        >
          {busy ? 'Working…' : '↻ Force refresh & re-pull catalog'}
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
          when syncing across devices. Non-destructive — it keeps your data.
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

        <hr className="pdj-settings__rule" />
        <button
          type="button"
          className="pdj-btn pdj-btn--danger"
          data-testid="settings-reset-all"
          disabled={busy}
          onClick={() => void resetAll()}
        >
          ⚠ Reset everything (deletes pockets &amp; playlists too)
        </button>
      </div>
    </Modal>
  );
}
