// IndexedDB schema for PocketDJ (via idb). One DB, four stores. All access goes
// through repo.ts — components never open the DB directly.
import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import type { DataSource, MusicItem } from '../types/model';
import type { Pocket, Playlist, Setlist } from '../types/collections';
import { txn } from '../lib/log';

export const DB_NAME = 'pocketdj';
// v2 adds the cross-source collection stores: pockets, playlists, setlists.
export const DB_VERSION = 2;

export interface ArtRecord {
  key: string;
  thumb?: Blob;
  full?: Blob;
  url?: string;
  status: 'ok' | 'missing' | 'pending' | 'url';
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
  // --- v2: cross-source user collections ---
  pockets: {
    key: string;
    value: Pocket;
  };
  playlists: {
    key: string;
    value: Playlist;
  };
  setlists: {
    key: string;
    value: Setlist;
    indexes: {
      by_playlist: string;
    };
  };
}

let _db: Promise<IDBPDatabase<PocketDJDB>> | null = null;

export function getDB(): Promise<IDBPDatabase<PocketDJDB>> {
  if (!_db) {
    _db = openDB<PocketDJDB>(DB_NAME, DB_VERSION, {
      // oldVersion-gated so existing v1 DBs upgrade additively (each block runs
      // once, only when crossing that version) — never re-creates an extant store.
      upgrade(db, oldVersion) {
        if (oldVersion < 1) {
          db.createObjectStore('sources', { keyPath: 'id' });

          const items = db.createObjectStore('items', { keyPath: 'id' });
          items.createIndex('by_source', 'sourceId');
          items.createIndex('by_source_type', ['sourceId', 'type']);
          // albumId is only present on songs; sparse index is fine.
          items.createIndex('by_album', 'albumId');
          items.createIndex('by_type', 'type');

          db.createObjectStore('art', { keyPath: 'key' });
          db.createObjectStore('meta', { keyPath: 'key' });
        }
        if (oldVersion < 2) {
          db.createObjectStore('pockets', { keyPath: 'id' });
          db.createObjectStore('playlists', { keyPath: 'id' });
          const setlists = db.createObjectStore('setlists', { keyPath: 'id' });
          setlists.createIndex('by_playlist', 'playlistId');
        }
      },
    });
    txn('db.open', { name: DB_NAME, version: DB_VERSION });
  }
  return _db;
}

/** Test/dev helper: wipe everything. */
export async function clearAllStores(): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(
    ['sources', 'items', 'art', 'meta', 'pockets', 'playlists', 'setlists'],
    'readwrite',
  );
  await Promise.all([
    tx.objectStore('sources').clear(),
    tx.objectStore('items').clear(),
    tx.objectStore('art').clear(),
    tx.objectStore('meta').clear(),
    tx.objectStore('pockets').clear(),
    tx.objectStore('playlists').clear(),
    tx.objectStore('setlists').clear(),
  ]);
  await tx.done;
}

export type { PocketDJDB };
