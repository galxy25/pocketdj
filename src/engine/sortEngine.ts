// Multi-key stable sort over field-registry accessors. Keys apply in order
// (index 0 = primary). Per key: nulls/'' sort LAST regardless of that key's
// direction; on a key both items null => fall through to the next key; first
// non-zero typed comparison wins; final tiebreak is the original input index (stable).
import type { SortState } from '../types/filter';
import type { MusicItem } from '../types/model';
import { getField } from './fieldRegistry';
import { camelotRank } from '../lib/camelot';

export function sortItems(items: MusicItem[], sorts: SortState[] | null): MusicItem[] {
  // Defensive normalization (survives a botched/pre-hydration value that isn't an array).
  // This is NOT a public union — the type stays SortState[] | null.
  const chain = Array.isArray(sorts) ? sorts : sorts ? [sorts] : [];
  if (chain.length === 0) return items; // SAME REFERENCE

  // Resolve each key once, dropping unknown fields. EVERY per-key flag lives on the
  // resolved record so the comparator can NEVER hoist one key's flags onto another.
  const valid = chain
    .map((s) => {
      const field = getField(s.field);
      if (!field) return null;
      const isCamelot = field.id === 'camelot';
      return {
        field,
        dir: s.dir === 'desc' ? -1 : 1,
        isCamelot,
        // camelot is numeric:false in the registry but its decorated value is a NUMBER
        // (camelotRank) and MUST use Number-diff, not localeCompare, in EVERY position.
        numeric: field.numeric || isCamelot,
      };
    })
    .filter((v): v is NonNullable<typeof v> => v !== null);

  if (valid.length === 0) return items; // all keys unknown -> SAME REFERENCE (before any allocation)

  // Decorate each item ONCE in original input order. `i` is the pre-sort index used for the
  // stable final tiebreak. `vs[k]` aligns to valid[k]; camelot slots store camelotRank(raw).
  const decorated = items.map((item, i) => ({
    item,
    i,
    vs: valid.map((k) => {
      const raw = k.field.get(item);
      return k.isCamelot ? camelotRank(raw as string | null | undefined) : raw;
    }),
  }));

  decorated.sort((a, b) => {
    for (let k = 0; k < valid.length; k++) {
      const av = a.vs[k];
      const bv = b.vs[k];
      const aNull = av == null || av === '';
      const bNull = bv == null || bv === '';
      if (aNull && bNull) continue; // EQUAL on this key -> fall through to next key
      if (aNull) return 1; // nulls LAST, independent of this key's dir
      if (bNull) return -1;
      let cmp: number;
      if (valid[k].numeric) cmp = Number(av) - Number(bv);
      else if (valid[k].field.kind === 'boolean') cmp = (av ? 1 : 0) - (bv ? 1 : 0);
      else cmp = String(av).localeCompare(String(bv), undefined, { sensitivity: 'base' });
      if (cmp !== 0) return cmp * valid[k].dir; // null returns above are OUTSIDE this *dir
    }
    return a.i - b.i; // stable: all keys equal -> original input order
  });

  return decorated.map((d) => d.item);
}

export function sortHash(sorts: SortState[] | null): string {
  const chain = Array.isArray(sorts) ? sorts : sorts ? [sorts] : [];
  // Hashes the RAW chain (unknown/dropped keys INCLUDED) — intentionally a superset memo
  // key, so it can over-key (a no-op recompute returning the same ref) but NEVER under-keys
  // a real change. Do NOT resolve fields here. Field ids are a closed registry with no
  // commas/colons, so the `,`/`:` separators never collide.
  return chain.length === 0 ? '' : chain.map((s) => `${s.field}:${s.dir}`).join(',');
}
