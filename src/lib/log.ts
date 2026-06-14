// PocketDJ "API transcript" logger.
//
// A PWA's only backend is the client. To make data operations auditable and
// verifiable (Playwright proof-of-verification), every storage / import / export
// / filter operation emits ONE greppable JSON line with a stable prefix:
//
//   PDJ_API {"t":1718200000000,"op":"db.putItem","id":"alb_…","type":"album"}
//
// Tests capture console output and assert on these lines as the "API transcript".
// Keep the prefix and the single-line JSON shape stable.

export const PDJ_PREFIX = 'PDJ_API';

export type ApiOp =
  | 'db.open'
  | 'db.putSource'
  | 'db.putItem'
  | 'db.bulkPutItems'
  | 'db.getItemsBySource'
  | 'db.getAllItems'
  | 'db.deleteSource'
  | 'art.cache'
  | 'art.generate'
  | 'import.index'
  | 'import.zip'
  | 'export.zip'
  | 'filter.apply'
  | 'sort.apply'
  | 'starmap.layout'
  | 'starmap.tier'
  | 'mock.load';

/** Emit one transcript line. Always single-line JSON for easy grepping. */
export function txn(op: ApiOp, detail: Record<string, unknown> = {}): void {
  // Date.now is fine in app runtime (this restriction only applies to workflow scripts).
  const line = PDJ_PREFIX + ' ' + JSON.stringify({ t: Date.now(), op, ...detail });
  // eslint-disable-next-line no-console
  console.log(line);
}

/** Parse a captured transcript line back into an object (used by tests/helpers). */
export function parseTxn(line: string): { t: number; op: string; [k: string]: unknown } | null {
  if (!line.startsWith(PDJ_PREFIX + ' ')) return null;
  try {
    return JSON.parse(line.slice(PDJ_PREFIX.length + 1));
  } catch {
    return null;
  }
}
