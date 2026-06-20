// Export / import a SINGLE pocket as a self-contained `.pocket.pocketdj.zip`. A
// pocket is the reusable, nestable harmonic grouping (the DAG node); this transfer
// moves one pocket — plus every child pocket it transitively references — between
// devices and clients. It is the symmetric counterpart of playlistTransfer.ts and
// mirrors the native PocketZip exactly so a pocket round-trips both ways:
//
//   • manifest.json — { app:"pocketdj", kind:"pocket", schemaVersion:1, portable:false,
//                       exportedAt, pocketName, counts:{ pockets, art } }
//     `pockets` counts the EXPORTED pocket plus every DAG-expanded child.
//   • pocket.json    — the root Pocket being exported.
//   • pockets.json   — its child pockets, DAG-expanded (cycle-guarded). The root is
//                      NOT duplicated here. May be [].
//
// Like the native PocketZip (and the SLIM playlist export), songs/albums stay
// referenced by catalog id — the same auto-seeded index resolves them on both ends —
// so neither items.json nor art/ is bundled (portable:false).
import { zip, unzip, strToU8, strFromU8, type AsyncZippable } from 'fflate';
import type { Pocket } from '../types/collections';
import { newPocketId } from '../types/collections';
import { getPocket, bulkPutPockets } from './repo';
import { txn } from '../lib/log';

interface PocketManifest {
  app: 'pocketdj';
  kind: 'pocket';
  schemaVersion: 1;
  portable?: boolean;
  exportedAt: string;
  pocketName: string;
  counts: { pockets: number; art: number };
}

function inflate(buf: Uint8Array): Promise<Record<string, Uint8Array>> {
  return new Promise((resolve, reject) => unzip(buf, (err, data) => (err ? reject(err) : resolve(data))));
}
function deflate(files: AsyncZippable): Promise<Uint8Array> {
  return new Promise((resolve, reject) => zip(files, { level: 6 }, (err, data) => (err ? reject(err) : resolve(data))));
}

/** The child pockets a pocket references, DAG-expanded (grandchildren too). Cycle-guarded; root excluded. */
async function referencedChildren(root: Pocket): Promise<Pocket[]> {
  const out: Pocket[] = [];
  const seen = new Set<string>([root.id]);
  const queue = [...root.childPocketIds];
  while (queue.length) {
    const pid = queue.pop() as string;
    if (seen.has(pid)) continue;
    seen.add(pid);
    const p = await getPocket(pid);
    if (!p) continue;
    out.push(p);
    queue.push(...p.childPocketIds);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------
export async function buildPocketZip(
  pocketId: string,
): Promise<{ blob: Blob; manifest: PocketManifest } | null> {
  const root = await getPocket(pocketId);
  if (!root) return null;
  const children = await referencedChildren(root);

  const files: AsyncZippable = {};
  files['pocket.json'] = [strToU8(JSON.stringify(root)), { level: 6 }];
  files['pockets.json'] = [strToU8(JSON.stringify(children)), { level: 6 }];

  const manifest: PocketManifest = {
    app: 'pocketdj',
    kind: 'pocket',
    schemaVersion: 1,
    portable: false,
    exportedAt: new Date().toISOString(),
    pocketName: root.name,
    counts: { pockets: children.length + 1, art: 0 },
  };
  files['manifest.json'] = strToU8(JSON.stringify(manifest));

  const bytes = await deflate(files);
  const blob = new Blob([bytes as BlobPart], { type: 'application/zip' });
  txn('export.pocket', { pocketId, ...manifest.counts, bytes: blob.size });
  return { blob, manifest };
}

export async function downloadPocketZip(pocketId: string): Promise<PocketManifest | null> {
  const built = await buildPocketZip(pocketId);
  if (!built) return null;
  const base = built.manifest.pocketName.replace(/[\\/:*?"<>|]+/g, '').trim() || 'pocket';
  const url = URL.createObjectURL(built.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${base}.pocket.pocketdj.zip`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return built.manifest;
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------
export interface ImportPocketResult {
  pocketId: string;
  name: string;
  pockets: number;
}

/**
 * Mint fresh ids for the imported root + every child pocket, remapping child refs
 * (childPocketIds) to the new ids. Refs to pockets NOT in the bundle are left as-is.
 * Mirrors the native PocketZip.remintBundle.
 */
export function remintBundle(root: Pocket, children: Pocket[]): { root: Pocket; children: Pocket[] } {
  const now = Date.now();
  const idMap = new Map<string, string>();
  idMap.set(root.id, newPocketId());
  for (const c of children) idMap.set(c.id, newPocketId());

  const remint = (p: Pocket): Pocket => ({
    ...p,
    id: idMap.get(p.id) ?? newPocketId(),
    childPocketIds: p.childPocketIds.map((c) => idMap.get(c) ?? c),
    createdAt: now,
    updatedAt: now,
  });

  return { root: remint(root), children: children.map(remint) };
}

/**
 * Import a single-pocket zip. The root pocket + its child pockets are added under
 * FRESH ids (so they can never clobber an existing pocket of the same id), with
 * child references remapped to the new ids. Songs/albums stay referenced by catalog
 * id. Version-tolerant: a missing manifest is allowed (pocket.json is enough).
 */
export async function importPocketZip(buf: ArrayBuffer): Promise<ImportPocketResult> {
  const files = await inflate(new Uint8Array(buf));
  const manRaw = files['manifest.json'];
  const rootRaw = files['pocket.json'];
  if (!rootRaw) throw new Error('Not a PocketDJ pocket export (missing pocket.json)');
  if (manRaw) {
    const man = JSON.parse(strFromU8(manRaw)) as Partial<PocketManifest>;
    if (man.app !== 'pocketdj' || man.kind !== 'pocket') throw new Error('Not a PocketDJ pocket export');
  }

  const srcRoot = JSON.parse(strFromU8(rootRaw)) as Pocket;
  const srcChildren = JSON.parse(strFromU8(files['pockets.json'] ?? strToU8('[]'))) as Pocket[];

  const { root, children } = remintBundle(srcRoot, srcChildren);
  await bulkPutPockets([root, ...children]);

  txn('import.pocket', { pocketId: root.id, pockets: children.length + 1 });
  return { pocketId: root.id, name: root.name, pockets: children.length + 1 };
}
