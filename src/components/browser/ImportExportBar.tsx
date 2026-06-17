// Dev-only "Load demo data" affordance. Full data Import/Export now lives in
// Settings (⤓ Export all data / ⤒ Import data), so the browser toolbar no longer
// duplicates it. In production this renders nothing.
import { useState } from 'react';
import { loadMockData } from '../../lib/dataActions';

export function ImportExportBar() {
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);

  // Demo data is a dev/test affordance; production ships a real seeded catalog and
  // does import/export from Settings.
  if (!import.meta.env.DEV) return null;

  const loadDemo = async () => {
    setBusy(true);
    setProgress(null);
    try {
      await loadMockData((done, total) => setProgress({ done, total }));
    } catch (e) {
      // eslint-disable-next-line no-alert
      alert(`Load demo failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      setProgress(null);
    }
  };

  return (
    <div className="pdj-iebar" data-testid="import-export-bar">
      <button className="pdj-btn pdj-btn--sm" data-testid="load-mock" disabled={busy} onClick={() => void loadDemo()}>
        Load demo data
      </button>
      {busy && (
        <span className="pdj-iebar__status" data-testid="import-progress">
          Load demo{progress ? ` ${progress.done}/${progress.total}` : '…'}
        </span>
      )}
    </div>
  );
}
