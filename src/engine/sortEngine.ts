// Sort engine. Stable sort over a field-registry accessor; nulls sort last.
import type { SortState } from '../types/filter';
import type { MusicItem } from '../types/model';
import { getField } from './fieldRegistry';

export function sortItems(items: MusicItem[], sort: SortState | null): MusicItem[] {
  if (!sort) return items;
  const field = getField(sort.field);
  if (!field) return items;
  const dir = sort.dir === 'desc' ? -1 : 1;

  const decorated = items.map((item, i) => ({ item, i, v: field.get(item) }));
  decorated.sort((a, b) => {
    const av = a.v;
    const bv = b.v;
    const aNull = av == null || av === '';
    const bNull = bv == null || bv === '';
    if (aNull && bNull) return a.i - b.i;
    if (aNull) return 1; // nulls last regardless of dir
    if (bNull) return -1;
    let cmp: number;
    if (field.numeric) cmp = Number(av) - Number(bv);
    else if (field.kind === 'boolean') cmp = (av ? 1 : 0) - (bv ? 1 : 0);
    else cmp = String(av).localeCompare(String(bv), undefined, { sensitivity: 'base' });
    return cmp !== 0 ? cmp * dir : a.i - b.i; // stable tiebreak
  });
  return decorated.map((d) => d.item);
}

export function sortHash(sort: SortState | null): string {
  return sort ? `${sort.field}:${sort.dir}` : '';
}
