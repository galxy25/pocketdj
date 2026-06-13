// Pure batching helpers + agent-count math for the indexing workflow.
//
// The Workflow runtime caps total agent() calls at 1000 and runs <=16 concurrently.
// 1,366 albums one-agent-each would blow the cap, so we batch. With a 2-stage
// pipeline (enrich + sentiment), agent calls = 2 * ceil(N / batchSize).

export const DEFAULT_BATCH_SIZE = 10;

/** Split an array into chunks of `size`. */
export function chunk(arr, size = DEFAULT_BATCH_SIZE) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/** Agent-call budget for a 2-stage (enrich + sentiment) pipeline. */
export function planBatches(n, size = DEFAULT_BATCH_SIZE) {
  const batches = Math.ceil(n / size);
  return {
    albums: n,
    batchSize: size,
    batches,
    agentCalls: batches * 2, // enrich + sentiment per batch
    underCap: batches * 2 <= 1000,
  };
}
