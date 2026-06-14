// Sort field + direction. Sortable fields come from the field registry, scoped
// to the current item type.
import { useBrowserStore } from '../../store/useBrowserStore';
import { useAppStore } from '../../store/useAppStore';
import { fieldsFor } from '../../engine/fieldRegistry';

export function SortControl() {
  const itemType = useAppStore((s) => s.itemType);
  const sort = useBrowserStore((s) => s.sort);
  const setSort = useBrowserStore((s) => s.setSort);
  const fields = fieldsFor(itemType).filter((f) => f.sortable);

  return (
    <div className="pdj-field pdj-sort">
      <span className="pdj-field__label">Sort</span>
      <select
        data-testid="sort-field"
        value={sort?.field ?? ''}
        onChange={(e) =>
          setSort(e.target.value ? { field: e.target.value, dir: sort?.dir ?? 'asc' } : null)
        }
      >
        <option value="">— none —</option>
        {fields.map((f) => (
          <option key={f.id} value={f.id}>
            {f.label}
          </option>
        ))}
      </select>
      <button
        className="pdj-iconbtn"
        data-testid="sort-dir"
        disabled={!sort}
        title={sort?.dir === 'desc' ? 'Descending' : 'Ascending'}
        onClick={() => sort && setSort({ ...sort, dir: sort.dir === 'asc' ? 'desc' : 'asc' })}
      >
        {sort?.dir === 'desc' ? '↓' : '↑'}
      </button>
    </div>
  );
}
