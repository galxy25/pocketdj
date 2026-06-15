// Filter & sort specification (the browser's query model).
//
// Operators required this iteration: equal, not-equal, in-list, between.
// `between` only applies to numeric fields (year, bpm, lengthMs, trackNumber).
// Clauses compose with AND. The shape leaves room for future OR groups without
// a breaking change (a clause could later nest a sub-FilterState).

import type { ItemType } from './model';

export type FilterOp = 'eq' | 'neq' | 'in' | 'between';

export type FieldKind = 'string' | 'number' | 'boolean' | 'string[]';

export interface FilterClause {
  id: string;
  /** FieldId from the field registry. */
  field: string;
  op: FilterOp;
  /** eq / neq value. */
  value?: string | number | boolean;
  /** in-list values. */
  values?: (string | number)[];
  /** between bounds (numeric only). */
  min?: number;
  max?: number;
}

export interface FilterState {
  /** AND-composed. */
  clauses: FilterClause[];
}

export type SortDir = 'asc' | 'desc';

export interface SortState {
  field: string;
  dir: SortDir;
}

/** Metadata describing one filterable/sortable field. Drives the FilterBuilder UI. */
export interface FieldDef {
  id: string;
  label: string;
  appliesTo: ItemType[];
  kind: FieldKind;
  /** between-capable. */
  numeric: boolean;
  /** Operators offered in the UI for this field. */
  ops: FilterOp[];
  /** Whether the field can be used as a sort key. */
  sortable: boolean;
  /** Closed value set — drives a single-select (eq/neq) or multi-select (in) dropdown in
   *  the FilterBuilder instead of a free-text input (genre, key, Camelot). */
  options?: string[];
}

export const EMPTY_FILTER: FilterState = { clauses: [] };
