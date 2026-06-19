// Settings panel: catalog info, full client-data backup/restore (export + import all
// data, so you can load an offline app from an export), a collections-preserving Force
// Refresh, data-version migrations, and a separate nuclear Reset.
import { useEffect, useRef, useState } from 'react';
import { Modal } from '../common/Modal';
import { forceRefreshCatalog, resetEverything, loadAppleMusicLibrary, removeSource } from '../../lib/dataActions';
import { downloadExportZip } from '../../storage/exportZip';
import { importFile } from '../../storage/importZip';
import { countItems } from '../../storage/repo';
import { useAppStore } from '../../store/useAppStore';
import { useSearchStore } from '../../store/useSearchStore';
import { useRipsStore } from '../../store/useRipsStore';
import { CURRENT_DATA_VERSION, getDataVersion, runMigrations } from '../../storage/migrations';

export function SettingsModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [counts, setCounts] = useState<{ albums: number; songs: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [dataVersion, setDataVersion] = useState<number | null>(null);
  const [migrating, setMigrating] = useState(false);
  const [migrateMsg, setMigrateMsg] = useState('');
  const [transfer, setTransfer] = useState<'idle' | 'export' | 'import'>('idle');
  const [transferMsg, setTransferMsg] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

  // Sources + multi-source selection (shared with the browser via useAppStore).
  const sources = useAppStore((s) => s.sources);
  const sourceMode = useAppStore((s) => s.sourceMode);
  const selectedSourceIds = useAppStore((s) => s.selectedSourceIds);
  const selectAllSources = useAppStore((s) => s.selectAllSources);
  const selectNoSources = useAppStore((s) => s.selectNoSources);
  const toggleSource = useAppStore((s) => s.toggleSource);
  const refreshSources = useAppStore((s) => s.refreshSources);
  const [amBusy, setAmBusy] = useState(false);
  const [amMsg, setAmMsg] = useState('');

  // Online search (OpenSearch) credentials — the read-only djpocketsearch IAM key/secret.
  const searchCreds = useSearchStore((s) => s.creds);
  const setSearchCreds = useSearchStore((s) => s.setCreds);
  const clearSearchCreds = useSearchStore((s) => s.clearCreds);
  const [akid, setAkid] = useState('');
  const [secret, setSecret] = useState('');

  // Rip server (stream/download via the iMac rip-on-demand API).
  const ripUrl = useRipsStore((s) => s.serverUrl);
  const ripToken = useRipsStore((s) => s.token);
  const ripOk = useRipsStore((s) => s.serverOk);
  const ripInfo = useRipsStore((s) => s.serverInfo);
  const setRipConfig = useRipsStore((s) => s.setConfig);
  const checkRip = useRipsStore((s) => s.checkHealth);
  const [ripUrlDraft, setRipUrlDraft] = useState(ripUrl);
  const [ripTokenDraft, setRipTokenDraft] = useState(ripToken);

  const isAll = sourceMode === 'all';
  const checked = (id: string) => isAll || selectedSourceIds.includes(id);
  const hasAppleMusic = sources.some((s) => s.type === 'digital' && s.name === 'Apple Music (Local)');

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const [c, dv] = await Promise.all([countItems(), getDataVersion(), refreshSources()]);
      if (cancelled) return;
      setCounts(c);
      setDataVersion(dv);
      if (ripUrl) void checkRip(); // refresh rip-server status/ripped-count
    })();
    return () => {
      cancelled = true;
    };
  }, [open, refreshSources, ripUrl, checkRip]);

  const loadAppleMusic = async () => {
    setAmBusy(true);
    setAmMsg('');
    try {
      const c = await loadAppleMusicLibrary();
      setAmMsg(`Loaded ${c.albums} albums · ${c.songs} songs.`);
      setCounts(await countItems());
    } catch (e) {
      setAmMsg((e as Error).message);
    } finally {
      setAmBusy(false);
    }
  };

  const unloadSource = async (id: string, name: string) => {
    if (!window.confirm(`Remove "${name}" and its imported playlists from this device?`)) return;
    setAmBusy(true);
    try {
      await removeSource(id);
      setCounts(await countItems());
    } finally {
      setAmBusy(false);
    }
  };

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
        <div className="pdj-settings__sources" data-testid="settings-sources">
          <div className="pdj-settings__stat">
            <span>Sources</span>
            <strong>{isAll ? 'All shown' : `${selectedSourceIds.filter((id) => sources.some((s) => s.id === id)).length} of ${sources.length} shown`}</strong>
          </div>
          <p className="pdj-settings__hint">
            Choose which sources to show across the app (browser, map, counts).
          </p>
          <label className="pdj-srcrow pdj-srcrow--all">
            <input
              type="checkbox"
              checked={isAll}
              data-testid="settings-source-all"
              onChange={() => (isAll ? selectNoSources() : selectAllSources())}
            />
            <span>All sources <em>(incl. ones added later)</em></span>
          </label>
          {sources.map((s) => (
            <div className="pdj-srcrow" key={s.id}>
              <label className="pdj-srcrow__label">
                <input
                  type="checkbox"
                  checked={checked(s.id)}
                  data-testid={`settings-source-${s.id}`}
                  onChange={() => toggleSource(s.id)}
                />
                <span>
                  {s.type === 'digital' ? '♪' : '⬤'} {s.name}{' '}
                  <em>({s.itemCount.albums} · {s.itemCount.songs})</em>
                </span>
              </label>
              <button
                type="button"
                className="pdj-iconbtn"
                title={`Remove ${s.name}`}
                aria-label={`Remove ${s.name}`}
                data-testid={`settings-source-remove-${s.id}`}
                disabled={amBusy}
                onClick={() => void unloadSource(s.id, s.name)}
              >
                ✕
              </button>
            </div>
          ))}
          {!hasAppleMusic && (
            <button
              type="button"
              className="pdj-btn pdj-btn--ghost"
              data-testid="settings-load-apple-music"
              disabled={amBusy}
              onClick={() => void loadAppleMusic()}
            >
              {amBusy ? 'Loading…' : '＋ Load Apple Music (Local) library'}
            </button>
          )}
          {amMsg && (
            <p className="pdj-settings__hint" data-testid="settings-source-msg">
              {amMsg}
            </p>
          )}
        </div>

        <hr className="pdj-settings__rule" />

        <div className="pdj-settings__search" data-testid="settings-search">
          <div className="pdj-settings__stat">
            <span>Online search</span>
            <strong>{searchCreds ? 'connected' : 'off'}</strong>
          </div>
          <p className="pdj-settings__hint">
            Enter your read-only <code>djpocketsearch</code> IAM key &amp; secret to enable the
            <strong> Online</strong> search toggle in the browser (searches the full catalog via
            OpenSearch). Leave blank to stay fully offline.
          </p>
          {searchCreds ? (
            <div className="pdj-settings__row">
              <span className="pdj-settings__hint" style={{ flex: '1 1 auto', margin: 0 }}>
                Key <code>{searchCreds.accessKeyId.slice(0, 8)}…</code> saved on this device.
              </span>
              <button
                type="button"
                className="pdj-btn pdj-btn--ghost"
                data-testid="settings-search-clear"
                onClick={() => { clearSearchCreds(); setAkid(''); setSecret(''); }}
              >
                Disconnect
              </button>
            </div>
          ) : (
            <>
              <input
                className="pdj-input"
                placeholder="Access key ID"
                autoComplete="off"
                spellCheck={false}
                data-testid="settings-search-akid"
                value={akid}
                onChange={(e) => setAkid(e.target.value)}
              />
              <input
                className="pdj-input"
                type="password"
                placeholder="Secret access key"
                autoComplete="off"
                spellCheck={false}
                data-testid="settings-search-secret"
                value={secret}
                onChange={(e) => setSecret(e.target.value)}
              />
              <button
                type="button"
                className="pdj-btn"
                data-testid="settings-search-save"
                disabled={!akid.trim() || !secret.trim()}
                onClick={() => { setSearchCreds(akid, secret); setAkid(''); setSecret(''); }}
              >
                Save &amp; enable online search
              </button>
            </>
          )}
        </div>

        <hr className="pdj-settings__rule" />

        <div className="pdj-settings__rip" data-testid="settings-rip">
          <div className="pdj-settings__stat">
            <span>Rip server</span>
            <strong>{ripOk == null ? (ripUrl ? 'unchecked' : 'off') : ripOk ? 'online' : 'offline'}</strong>
          </div>
          <p className="pdj-settings__hint">
            Stream / download any song. Point this at the iMac running the rip server
            (its Tailscale HTTPS URL, e.g. <code>https://levis-imac.ts.net</code>, or
            <code>http://localhost:8787</code> on the same machine).
          </p>
          <input
            className="pdj-input"
            placeholder="Rip server URL"
            autoComplete="off"
            spellCheck={false}
            data-testid="settings-rip-url"
            value={ripUrlDraft}
            onChange={(e) => setRipUrlDraft(e.target.value)}
          />
          <input
            className="pdj-input"
            type="password"
            placeholder="Token (optional)"
            autoComplete="off"
            spellCheck={false}
            data-testid="settings-rip-token"
            value={ripTokenDraft}
            onChange={(e) => setRipTokenDraft(e.target.value)}
          />
          <div className="pdj-settings__row">
            <button
              type="button"
              className="pdj-btn"
              data-testid="settings-rip-save"
              onClick={() => setRipConfig(ripUrlDraft, ripTokenDraft)}
            >
              Save
            </button>
            <button
              type="button"
              className="pdj-btn pdj-btn--ghost"
              data-testid="settings-rip-test"
              disabled={!ripUrlDraft.trim()}
              onClick={() => { setRipConfig(ripUrlDraft, ripTokenDraft); void checkRip(); }}
            >
              Test connection
            </button>
          </div>
          {ripOk != null && (
            <p className="pdj-settings__hint" data-testid="settings-rip-status">
              {ripOk
                ? `Online · ${ripInfo?.catalog?.songs ?? '?'} songs · ${ripInfo?.cached ?? 0} ripped`
                : 'Offline — already-ripped songs still play; new rips need the server reachable.'}
            </p>
          )}
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
