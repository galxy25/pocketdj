// Data-source picker: every source + the virtual "All". Drives the active scope.
import { useAppStore } from '../../store/useAppStore';
import { ALL_SOURCE_ID } from '../../types/model';

export function DataSourceSelector() {
  const sources = useAppStore((s) => s.sources);
  const activeSourceId = useAppStore((s) => s.activeSourceId);
  const setActiveSource = useAppStore((s) => s.setActiveSource);

  const totalAlbums = sources.reduce((n, s) => n + s.itemCount.albums, 0);
  const totalSongs = sources.reduce((n, s) => n + s.itemCount.songs, 0);

  return (
    <label className="pdj-field pdj-source">
      <span className="pdj-field__label">Source</span>
      <select
        data-testid="data-source-selector"
        value={activeSourceId}
        onChange={(e) => setActiveSource(e.target.value)}
      >
        <option data-testid="data-source-option-all" value={ALL_SOURCE_ID}>
          All sources ({totalAlbums} albums · {totalSongs} songs)
        </option>
        {sources.map((s) => (
          <option key={s.id} data-testid={`data-source-option-${s.id}`} value={s.id}>
            {s.name} ({s.itemCount.albums} · {s.itemCount.songs})
          </option>
        ))}
      </select>
    </label>
  );
}
