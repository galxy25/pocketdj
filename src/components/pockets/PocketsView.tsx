// Pockets mode — top-level list. Create a pocket (then jump into it) and browse
// existing pockets. Pockets are cross-source harmonic groupings; counts roll up
// direct songs + albums + nested child pockets.
import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useCollectionsStore } from '../../store/useCollectionsStore';
import './pockets.css';

export function PocketsView(): JSX.Element {
  const navigate = useNavigate();
  const load = useCollectionsStore((s) => s.load);
  const createPocket = useCollectionsStore((s) => s.createPocket);
  // Subscribe to pockets + rev so the list re-renders after any write.
  const pockets = useCollectionsStore((s) => s.pockets);
  useCollectionsStore((s) => s.rev);

  const [name, setName] = useState('');

  useEffect(() => {
    void load();
  }, [load]);

  const create = async () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    const created = await createPocket(trimmed);
    setName('');
    navigate(`/pockets/${created.id}`);
  };

  return (
    <div className="pdj-pockets" data-testid="pockets-view">
      <div className="pdj-pockets__head">
        <h1 className="pdj-pockets__title">Pockets</h1>
        <span className="pdj-pockets__sub">Reusable harmonic groupings</span>
      </div>

      <div className="pdj-pockets__create">
        <input
          type="text"
          value={name}
          placeholder="New pocket name…"
          aria-label="New pocket name"
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void create();
          }}
        />
        <button
          type="button"
          className="pdj-btn"
          data-testid="pocket-create"
          disabled={!name.trim()}
          onClick={() => void create()}
        >
          ＋ Create
        </button>
      </div>

      {pockets.length === 0 ? (
        <div className="pdj-pockets__empty">
          No pockets yet. Create one above, or add songs and albums to a pocket from the browser.
        </div>
      ) : (
        <div className="pdj-pockets__list">
          {pockets.map((p) => {
            return (
              <Link
                key={p.id}
                to={`/pockets/${p.id}`}
                className="pdj-pockets__row"
                data-testid={`pocket-row-${p.id}`}
              >
                <span className="pdj-pockets__row-main">
                  <span className="pdj-pockets__kind">{p.kind}</span>
                  <span className="pdj-pockets__row-name">{p.name}</span>
                </span>
                <span className="pdj-pockets__row-meta">
                  {p.songIds.length} songs · {p.albumIds.length} albums · {p.childPocketIds.length} pockets
                </span>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
