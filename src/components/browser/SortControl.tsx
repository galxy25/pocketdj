// Multi-key sort builder: a stack of sort rows (primary -> secondary -> …) mirroring
// FilterBuilder/FilterRow. The primary row (row 0) is ALWAYS rendered; rows 1..n appear
// only once added. Sortable fields come from the field registry, scoped to the item type.
import { useBrowserStore } from '../../store/useBrowserStore';
import { useAppStore } from '../../store/useAppStore';
import { fieldsFor } from '../../engine/fieldRegistry';

export function SortControl() {
  const itemType = useAppStore((s) => s.itemType);
  const sort = useBrowserStore((s) => s.sort);
  const setSort = useBrowserStore((s) => s.setSort);
  const addSort = useBrowserStore((s) => s.addSort);
  const removeSort = useBrowserStore((s) => s.removeSort);
  const clearSort = useBrowserStore((s) => s.clearSort);
  const fields = fieldsFor(itemType).filter((f) => f.sortable);

  const usedFields = new Set(sort.map((s) => s.field));
  // first sortable field not already used (for the add button); undefined when all used:
  const nextUnused = fields.find((f) => !usedFields.has(f.id));

  return (
    <div className="pdj-sort-stack" data-testid="sort-builder">
      {/* primary row ALWAYS present */}
      <div className="pdj-sort-row" data-testid="sort-row-0">
        <span className="pdj-field__label">Sort by</span>
        <select
          data-testid="sort-field"
          value={sort[0]?.field ?? ''}
          onChange={(e) => {
            const v = e.target.value;
            if (!v) clearSort(); // "— none —" clears the WHOLE chain
            else if (sort.length) setSort(0, { field: v }); // existing primary -> update in place
            else addSort(v, 'asc'); // no primary yet -> create it (dir asc)
          }}
        >
          <option value="">— none —</option>
          {/* out-of-range guard: if the current primary field isn't in this itemType's list
              (e.g. switched Songs->Albums with bpm selected), render a disabled option so the
              controlled select doesn't silently show the wrong first option. */}
          {sort[0] && !fields.some((f) => f.id === sort[0].field) && (
            <option value={sort[0].field} disabled>
              {sort[0].field}
            </option>
          )}
          {fields.map((f) => (
            <option key={f.id} value={f.id}>
              {f.label}
            </option>
          ))}
        </select>
        <button
          className="pdj-iconbtn"
          data-testid="sort-dir"
          disabled={sort.length === 0}
          title={sort[0]?.dir === 'desc' ? 'Descending' : 'Ascending'}
          onClick={() => sort[0] && setSort(0, { dir: sort[0].dir === 'asc' ? 'desc' : 'asc' })}
        >
          {sort[0]?.dir === 'desc' ? '↓' : '↑'}
        </button>
      </div>

      {/* secondary+ rows */}
      {sort.slice(1).map((_, idx) => {
        const i = idx + 1;
        return (
          <div className="pdj-sort-row" data-testid={`sort-row-${i}`} key={i}>
            <span className="pdj-field__label">then by</span>
            <select
              data-testid={`sort-field-${i}`}
              value={sort[i].field}
              onChange={(e) => setSort(i, { field: e.target.value })}
            >
              {/* same out-of-range guard for itemType switches */}
              {!fields.some((f) => f.id === sort[i].field) && (
                <option value={sort[i].field} disabled>
                  {sort[i].field}
                </option>
              )}
              {fields
                .filter((f) => f.id === sort[i].field || !usedFields.has(f.id))
                .map((f) => (
                  <option key={f.id} value={f.id}>
                    {f.label}
                  </option>
                ))}
            </select>
            <button
              className="pdj-iconbtn"
              data-testid={`sort-dir-${i}`}
              title={sort[i].dir === 'desc' ? 'Descending' : 'Ascending'}
              onClick={() => setSort(i, { dir: sort[i].dir === 'asc' ? 'desc' : 'asc' })}
            >
              {sort[i].dir === 'desc' ? '↓' : '↑'}
            </button>
            <button
              className="pdj-iconbtn"
              data-testid={`sort-remove-${i}`}
              aria-label="Remove sort key"
              onClick={() => removeSort(i)}
            >
              ✕
            </button>
          </div>
        );
      })}

      {/* add button */}
      <button
        className="pdj-btn pdj-btn--sm"
        data-testid="sort-add"
        disabled={sort.length === 0 || !nextUnused}
        title={
          sort.length === 0
            ? 'Pick a sort field first'
            : !nextUnused
              ? 'All fields in use'
              : 'Add another sort key'
        }
        onClick={() => nextUnused && addSort(nextUnused.id, 'asc')}
      >
        + Sort
      </button>
    </div>
  );
}
