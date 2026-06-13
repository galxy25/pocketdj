// IndexedDB schema for PocketDJ (via idb). One DB, four stores. All access goes
// through repo.ts — components never open the DB directly.
import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import type { DataSource, MusicItem } from '../types/model';
import { txn } from '../lib/log';

export const DB_NAME = 'pocketdj';
export const DB_VERSION = 1;

export interface ArtRecord {
  key: string;
  thumb?: Blob;
  full?: Blob;
  url?: string;
  status: 'ok' | 'missing' | 'pending';
  w?: number;
  h?: number;
}

export interface MetaRecord {
  key: string;
  value: unknown;
}

interface PocketDJDB extends DBSchema {
  sources: {
    key: string;
    value: DataSource;
  };
  items: {
    key: string;
    value: MusicItem;
    indexes: {
      by_source: string;
      by_source_type: [string, string];
      by_album: string;
      by_type: string;
    };
  };
  art: {
    key: string;
    value: ArtRecord;
  };
  meta: {
    key: string;
    value: MetaRecord;
  };
}

let _db: Promise<IDBPDatabase<PocketDJDB>> | null = null;

export function getDB(): Promise<IDBPDatabase<PocketDJDB>> {
  if (!_db) {
    _db = openDB<PocketDJDB>(DB_NAME, DB_VERSION, {
      upgrade(db) {
        db.createObjectStore('sources', { keyPath: 'id' });

        const items = db.createObjectStore('items', { keyPath: 'id' });
        items.createIndex('by_source', 'sourceId');
        items.createIndex('by_source_type', ['sourceId', 'type']);
        // albumId is only present on songs; sparse index is fine.
        items.createIndex('by_album', 'albumId');
        items.createIndex('by_type', 'type');

        db.createObjectStore('art', { keyPath: 'key' });
        db.createObjectStore('meta', { keyPath: 'key' });
      },
    });
    txn('db.open', { name: DB_NAME, version: DB_VERSION });
  }
  return _db;
}

/** Test/dev helper: wipe everything. */
export async function clearAllStores(): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(['sources', 'items', 'art', 'meta'], 'readwrite');
  await Promise.all([
    tx.objectStore('sources').clear(),
    tx.objectStore('items').clear(),
    tx.objectStore('art').clear(),
    tx.objectStore('meta').clear(),
  ]);
  await tx.done;
}

export type { PocketDJDB };
