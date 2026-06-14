// Virtualized list/grid of items (handles ~15k songs / ~1.4k albums smoothly).
// Album mode = responsive card grid; Song mode = dense rows. Uses
// @tanstack/react-virtual with a measured scroll container.
import { useRef } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import type { MusicItem, AlbumItem, SongItem } from '../../types/model';
import { AlbumCard, SongRow } from './ItemCard';

const ALBUM_ROW_H = 300; // fixed card height (284) + row gap (16)
const SONG_ROW_H = 44;

interface Props {
  items: MusicItem[];
  itemType: 'album' | 'song';
  onEdit: (id: string) => void;
  /** Open the read-only detail modal for a song (row click / Enter). */
  onOpen: (id: string) => void;
  /** album cards per row, computed from container width */
  columns: number;
}

export function ItemGrid({ items, itemType, onEdit, onOpen, columns }: Props) {
  const parentRef = useRef<HTMLDivElement>(null);
  const isAlbum = itemType === 'album';
  const perRow = isAlbum ? Math.max(1, columns) : 1;
  const rowCount = Math.ceil(items.length / perRow);

  const virtualizer = useVirtualizer({
    count: rowCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => (isAlbum ? ALBUM_ROW_H : SONG_ROW_H),
    overscan: 6,
  });

  if (items.length === 0) {
    return (
      <div className="pdj-grid__empty" data-testid="item-grid-empty">
        No items match. Try clearing filters or loading data.
      </div>
    );
  }

  return (
    <div className="pdj-grid__scroll" ref={parentRef} data-testid="item-grid">
      <div style={{ height: virtualizer.getTotalSize(), position: 'relative', width: '100%' }}>
        {virtualizer.getVirtualItems().map((vrow) => {
          const start = vrow.index * perRow;
          const rowItems = items.slice(start, start + perRow);
          return (
            <div
              key={vrow.key}
              className={isAlbum ? 'pdj-grid__row' : 'pdj-list__row'}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                transform: `translateY(${vrow.start}px)`,
                ...(isAlbum ? { gridTemplateColumns: `repeat(${perRow}, 1fr)` } : {}),
              }}
            >
              {rowItems.map((it) =>
                isAlbum ? (
                  <AlbumCard key={it.id} album={it as AlbumItem} onEdit={onEdit} />
                ) : (
                  <SongRow key={it.id} song={it as SongItem} onEdit={onEdit} onOpen={onOpen} />
                ),
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
