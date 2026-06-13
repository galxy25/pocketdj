// Portability + demo-data controls: load mock data, import an index.json or
// .pocketdj.zip, export everything to a zip.
import { useRef, useState } from 'react';
import { loadMockData, importUserFile, exportData } from '../../lib/dataActions';

export function ImportExportBar() {
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);

  async function withBusy(label: string, fn: () => Promise<unknown>) {
    setBusy(label);
    setProgress(null);
    try {
      await fn();
    } catch (e) {
      // eslint-disable-next-line no-alert
      alert(`${label} failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(null);
      setProgress(null);
    }
  }

  return (
    <div className="pdj-iebar" data-testid="import-export-bar">
      <button
        className="pdj-btn pdj-btn--sm"
        data-testid="load-mock"
        disabled={!!busy}
        onClick={() =>
          withBusy('Load demo', () => loadMockData((done, total) => setProgress({ done, total })))
        }
      >
        Load demo data
      </button>

      <button
        className="pdj-btn pdj-btn--sm pdj-btn--ghost"
        data-testid="import-open"
        disabled={!!busy}
        onClick={() => fileRef.current?.click()}
      >
        Import…
      </button>
      <input
        ref={fileRef}
        type="file"
        accept=".json,.zip"
        data-testid="import-input"
        style={{ display: 'none' }}
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) withBusy('Import', () => importUserFile(f, (done, total) => setProgress({ done, total })));
          e.target.value = '';
        }}
      />

      <button
        className="pdj-btn pdj-btn--sm pdj-btn--ghost"
        data-testid="export-button"
        disabled={!!busy}
        onClick={() => withBusy('Export', () => exportData())}
      >
        Export
      </button>

      {busy && (
        <span className="pdj-iebar__status" data-testid="import-progress">
          {busy}
          {progress ? ` ${progress.done}/${progress.total}` : '…'}
        </span>
      )}
    </div>
  );
}
