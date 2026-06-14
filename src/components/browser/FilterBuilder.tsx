// The filter builder: a stack of FilterRows (AND-composed) + add/clear controls.
import { useBrowserStore } from '../../store/useBrowserStore';
import { useAppStore } from '../../store/useAppStore';
import { fieldsFor } from '../../engine/fieldRegistry';
import { FilterRow } from './FilterRow';

export function FilterBuilder() {
  const itemType = useAppStore((s) => s.itemType);
  const clauses = useBrowserStore((s) => s.filter.clauses);
  const addClause = useBrowserStore((s) => s.addClause);
  const clearFilter = useBrowserStore((s) => s.clearFilter);

  const defaultField = fieldsFor(itemType)[0];

  return (
    <div className="pdj-filter-builder" data-testid="filter-builder">
      <div className="pdj-filter-builder__head">
        <span className="pdj-field__label">Filters {clauses.length > 0 ? `(${clauses.length})` : ''}</span>
        <div className="pdj-filter-builder__actions">
          <button
            className="pdj-btn pdj-btn--sm"
            data-testid="filter-add"
            onClick={() => defaultField && addClause(defaultField.id, defaultField.ops[0])}
          >
            + Filter
          </button>
          {clauses.length > 0 && (
            <button className="pdj-btn pdj-btn--sm pdj-btn--ghost" data-testid="filter-clear" onClick={clearFilter}>
              Clear
            </button>
          )}
        </div>
      </div>
      {clauses.length > 0 && (
        <div className="pdj-filter-rows">
          {clauses.map((c, i) => (
            <FilterRow key={c.id} clause={c} index={i} />
          ))}
        </div>
      )}
    </div>
  );
}
