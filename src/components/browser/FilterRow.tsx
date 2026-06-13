// One filter clause: field + operator + an operator-specific value editor.
//   eq/neq -> single input (text/number/bool)
//   in     -> comma-separated multi values
//   between-> min + max (numeric only)
import type { FilterClause, FilterOp } from '../../types/filter';
import { getField, fieldsFor } from '../../engine/fieldRegistry';
import { useBrowserStore } from '../../store/useBrowserStore';
import { useAppStore } from '../../store/useAppStore';
import { clockToMs, msToClock } from '../../lib/format';

const OP_LABEL: Record<FilterOp, string> = {
  eq: 'is',
  neq: 'is not',
  in: 'in list',
  between: 'between',
};

interface Props {
  clause: FilterClause;
  index: number;
}

export function FilterRow({ clause, index }: Props) {
  const itemType = useAppStore((s) => s.itemType);
  const update = useBrowserStore((s) => s.updateClause);
  const remove = useBrowserStore((s) => s.removeClause);

  const fields = fieldsFor(itemType);
  const field = getField(clause.field);
  const isLength = clause.field === 'lengthMs';

  const onField = (id: string) => {
    const f = getField(id);
    const op = f && f.ops.includes(clause.op) ? clause.op : (f?.ops[0] ?? 'eq');
    update(clause.id, { field: id, op, value: undefined, values: undefined, min: undefined, max: undefined });
  };

  return (
    <div className="pdj-filter-row" data-testid={`filter-row-${index}`}>
      <select
        data-testid="filter-field"
        value={clause.field}
        onChange={(e) => onField(e.target.value)}
      >
        {fields.map((f) => (
          <option key={f.id} value={f.id}>
            {f.label}
          </option>
        ))}
      </select>

      <select
        data-testid="filter-op"
        value={clause.op}
        onChange={(e) => update(clause.id, { op: e.target.value as FilterOp })}
      >
        {(field?.ops ?? ['eq']).map((op) => (
          <option key={op} value={op}>
            {OP_LABEL[op]}
          </option>
        ))}
      </select>

      {/* value editor by op */}
      {clause.op === 'between' ? (
        <span className="pdj-filter-between">
          <input
            data-testid="filter-min"
            type={isLength ? 'text' : 'number'}
            placeholder={isLength ? 'm:ss' : 'min'}
            value={isLength ? (clause.min != null ? msToClock(clause.min) : '') : (clause.min ?? '')}
            onChange={(e) =>
              update(clause.id, { min: isLength ? clockToMs(e.target.value) : numOrUndef(e.target.value) })
            }
          />
          <span>–</span>
          <input
            data-testid="filter-max"
            type={isLength ? 'text' : 'number'}
            placeholder={isLength ? 'm:ss' : 'max'}
            value={isLength ? (clause.max != null ? msToClock(clause.max) : '') : (clause.max ?? '')}
            onChange={(e) =>
              update(clause.id, { max: isLength ? clockToMs(e.target.value) : numOrUndef(e.target.value) })
            }
          />
        </span>
      ) : clause.op === 'in' ? (
        <input
          data-testid="filter-value"
          className="pdj-filter-value"
          placeholder="comma,separated,values"
          value={(clause.values ?? []).join(', ')}
          onChange={(e) =>
            update(clause.id, {
              values: e.target.value
                .split(',')
                .map((v) => v.trim())
                .filter(Boolean),
            })
          }
        />
      ) : field?.kind === 'boolean' ? (
        <select
          data-testid="filter-value"
          value={String(clause.value ?? 'true')}
          onChange={(e) => update(clause.id, { value: e.target.value === 'true' })}
        >
          <option value="true">true</option>
          <option value="false">false</option>
        </select>
      ) : (
        <input
          data-testid="filter-value"
          className="pdj-filter-value"
          type={field?.numeric && !isLength ? 'number' : 'text'}
          placeholder={isLength ? 'm:ss' : 'value'}
          value={
            isLength && typeof clause.value === 'number' ? msToClock(clause.value) : (clause.value as string | number) ?? ''
          }
          onChange={(e) =>
            update(clause.id, {
              value: isLength
                ? clockToMs(e.target.value)
                : field?.numeric
                  ? numOrUndef(e.target.value)
                  : e.target.value,
            })
          }
        />
      )}

      <button className="pdj-iconbtn" data-testid={`filter-remove-${index}`} onClick={() => remove(clause.id)} aria-label="Remove filter">
        ✕
      </button>
    </div>
  );
}

function numOrUndef(s: string): number | undefined {
  if (s.trim() === '') return undefined;
  const n = Number(s);
  return isFinite(n) ? n : undefined;
}
