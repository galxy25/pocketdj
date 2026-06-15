// Filter engine: eq / neq / in / between, AND-composed. Pure functions over the
// field registry accessors. `between` only applies to numeric fields.
import type { FilterClause, FilterState } from '../types/filter';
import type { MusicItem } from '../types/model';
import { getField } from './fieldRegistry';
import { txn } from '../lib/log';

function norm(v: unknown): string {
  return String(v ?? '').trim().toLowerCase();
}

/**
 * A half-built clause (one the user added but hasn't given an operand to yet)
 * must NOT silently exclude the whole catalog. Treat it as a no-op so an empty
 * filter row never zeroes the results. The signal is `value === undefined`
 * (a freshly-added clause carries no `value`); an explicit empty string ('')
 * is a real "match missing/empty" query and is intentionally NOT incomplete.
 */
function isIncomplete(clause: FilterClause): boolean {
  switch (clause.op) {
    case 'eq':
    case 'neq':
      return clause.value === undefined || clause.value === null;
    case 'in':
      return !clause.values || clause.values.length === 0;
    case 'between':
      return clause.min == null && clause.max == null;
    default:
      return false;
  }
}

function matchClause(item: MusicItem, clause: FilterClause): boolean {
  const field = getField(clause.field);
  if (!field) return true; // unknown field -> don't exclude
  // A half-built clause (no operand yet) is a no-op, not an exclude-all.
  if (isIncomplete(clause)) return true;
  // A clause whose field doesn't apply to this item type passes through.
  if (!field.appliesTo.includes(item.type)) return true;

  const raw = field.get(item);

  // string[] fields (sentimentKeywords)
  if (field.kind === 'string[]') {
    const arr = Array.isArray(raw) ? (raw as string[]).map(norm) : [];
    switch (clause.op) {
      case 'in': {
        const vals = (clause.values ?? []).map(norm);
        return vals.length === 0 ? true : vals.some((v) => arr.includes(v));
      }
      case 'eq':
        return arr.includes(norm(clause.value));
      case 'neq':
        return !arr.includes(norm(clause.value));
      default:
        return true;
    }
  }

  if (field.kind === 'boolean') {
    const b = Boolean(raw);
    if (clause.op === 'eq') return b === Boolean(clause.value);
    return true;
  }

  if (field.numeric) {
    const n = raw == null ? null : Number(raw);
    switch (clause.op) {
      case 'eq':
        return n != null && n === Number(clause.value);
      case 'neq':
        return n == null || n !== Number(clause.value);
      case 'in':
        return n != null && (clause.values ?? []).map(Number).includes(n);
      case 'between': {
        if (n == null) return false;
        const min = clause.min ?? -Infinity;
        const max = clause.max ?? Infinity;
        return n >= min && n <= max;
      }
      default:
        return true;
    }
  }

  // string fields
  const s = norm(raw);
  switch (clause.op) {
    case 'eq':
      return s === norm(clause.value);
    case 'neq':
      return s !== norm(clause.value);
    case 'in':
      return (clause.values ?? []).map(norm).includes(s);
    default:
      return true;
  }
}

/** Apply all clauses (AND). Emits a transcript line with in/out counts. */
export function applyFilters(items: MusicItem[], state: FilterState): MusicItem[] {
  if (!state.clauses.length) return items;
  const out = items.filter((it) => state.clauses.every((c) => matchClause(it, c)));
  txn('filter.apply', {
    clauses: state.clauses.map((c) => ({ field: c.field, op: c.op })),
    in: items.length,
    out: out.length,
  });
  return out;
}

/** Stable hash of a filter state for memoization. */
export function filterHash(state: FilterState): string {
  return JSON.stringify(state.clauses);
}
