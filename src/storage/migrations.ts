// Data-version migrations for the local PocketDJ collections (pockets + playlists).
//
// PocketDJ persists to IndexedDB with no server, so "syncing" data between
// devices happens via export/import (and, later, any remote sync). Whenever data
// is loaded or imported it may have been written by an OLDER app, so we version
// the SHAPE of the collections data and forward-migrate it to the current
// version. The version lives in the `meta` store under `dataVersion`.
//
// CURRENT_DATA_VERSION is the BASELINE — v0 — for the shapes shipping today. There
// are no migrations yet; future shape changes append a Migration with `to: N` and
// the version bumps as each runs. Migrations must be idempotent + safe to re-run.
import { getMeta, setMeta } from './repo';
import { txn } from '../lib/log';

/** Baseline data version for the collections shapes shipping today. */
export const CURRENT_DATA_VERSION = 0;
const META_KEY = 'dataVersion';

export interface Migration {
  /** Version this migration brings the data UP TO. */
  to: number;
  /** Human label (shown in the run summary + logged). */
  name: string;
  /** Idempotent transform over the persisted collections. */
  run: () => Promise<void>;
}

/**
 * Ordered migrations. EMPTY at v0 (current state is the baseline). Example future
 * entry:
 *   { to: 1, name: 'pocket: add color', run: async () => {
 *       for (const p of await getPockets()) if (p.color === undefined) await putPocket({ ...p, color: '#888' });
 *     } }
 */
export const MIGRATIONS: Migration[] = [];

/** The data version stored on this device (0 if never stamped). */
export async function getDataVersion(): Promise<number> {
  const v = await getMeta<number>(META_KEY);
  return typeof v === 'number' ? v : 0;
}

export interface MigrateResult {
  from: number;
  to: number;
  /** Names of migrations that ran this pass. */
  ran: string[];
}

/**
 * Bring this device's collections data up to CURRENT_DATA_VERSION, running each
 * pending migration in order. Stamps the new version. Safe to call on every boot
 * (a no-op once current). Returns what ran.
 */
export async function runMigrations(): Promise<MigrateResult> {
  const from = await getDataVersion();
  const ran: string[] = [];
  for (const m of MIGRATIONS.filter((m) => m.to > from).sort((a, b) => a.to - b.to)) {
    await m.run();
    ran.push(m.name);
  }
  // Stamp the version (also writes the baseline key the first time, so it's explicit).
  if (from !== CURRENT_DATA_VERSION || (await getMeta(META_KEY)) === undefined) {
    await setMeta(META_KEY, CURRENT_DATA_VERSION);
  }
  txn('migrate.run', { from, to: CURRENT_DATA_VERSION, ran: ran.length });
  return { from, to: CURRENT_DATA_VERSION, ran };
}
