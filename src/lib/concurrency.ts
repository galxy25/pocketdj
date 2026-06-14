// Bounded-concurrency map — used to download cover art without flooding the
// network. Resolves results in input order; never rejects (failures captured).

export interface PoolResult<T> {
  ok: boolean;
  value?: T;
  error?: unknown;
}

export async function pMap<I, O>(
  items: I[],
  worker: (item: I, index: number) => Promise<O>,
  concurrency = 6,
  onProgress?: (done: number, total: number) => void,
): Promise<PoolResult<O>[]> {
  const results: PoolResult<O>[] = new Array(items.length);
  let next = 0;
  let done = 0;

  async function run(): Promise<void> {
    while (next < items.length) {
      const i = next++;
      try {
        results[i] = { ok: true, value: await worker(items[i], i) };
      } catch (error) {
        results[i] = { ok: false, error };
      }
      done++;
      onProgress?.(done, items.length);
    }
  }

  const runners = Array.from({ length: Math.min(concurrency, items.length) }, () => run());
  await Promise.all(runners);
  return results;
}
