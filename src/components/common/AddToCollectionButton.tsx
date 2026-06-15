// Drop-in trigger for the shared "Add to…" affordance. Manages its own open
// state and mounts <AddToCollectionPicker />. Mounted by the four detail
// surfaces (song/album/pocket/playlist) wherever an item can be collected.
import { useState } from 'react';
import { AddToCollectionPicker } from './AddToCollectionPicker';

interface Props {
  item: { kind: 'song' | 'album'; id: string; name: string };
  className?: string;
  label?: string;
}

export function AddToCollectionButton(props: Props): JSX.Element {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        data-testid={`add-to-collection-${props.item.id}`}
        className={props.className ?? 'pdj-btn pdj-btn--sm'}
        onClick={() => setOpen(true)}
      >
        {props.label ?? '＋ Add to…'}
      </button>
      <AddToCollectionPicker open={open} onClose={() => setOpen(false)} item={props.item} />
    </>
  );
}
