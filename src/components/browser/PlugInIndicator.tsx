// "Plug in this data source" indicator for ANALOG items the app can't play
// directly. Tapping reveals where to physically cue the record (crate/disc/side),
// reflecting the 2-channel-mixer workflow: fade to channel 2 to play it.
import { useState } from 'react';
import type { Pointer } from '../../types/model';

interface Props {
  pointer?: Pointer;
  id: string;
}

export function PlugInIndicator({ pointer, id }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <span className="pdj-plugin">
      <button
        className="pdj-plugin__badge"
        data-testid={`plug-in-indicator-${id}`}
        title="Analog source — fade to channel 2 to play"
        onClick={(e) => {
          e.stopPropagation();
          setOpen((o) => !o);
        }}
      >
        ⏚ plug in
      </button>
      {open && (
        <span className="pdj-plugin__pop" role="tooltip">
          Analog — can't play in-app. Cue it & fade to <b>channel 2</b>.
          <br />
          {pointer?.location && <>📦 {pointer.location} </>}
          {pointer?.disc != null && <>· disc {pointer.disc} </>}
          {pointer?.track != null && <>· track {pointer.track}</>}
          {pointer?.filename && (
            <>
              <br />
              <code>{pointer.filename}</code>
            </>
          )}
        </span>
      )}
    </span>
  );
}
