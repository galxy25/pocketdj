import { describe, it, expect } from 'vitest';
import {
  addSequence,
  removeSequence,
  renameSequence,
  setSequenceTarget,
  addNode,
  addSong,
  addAlbum,
  addPocket,
  removeNode,
  moveNode,
  DEFAULT_SEQUENCE,
} from './playlistOps';
import {
  makePlaylist,
  type Playlist,
  type PlaylistNode,
  type SongNode,
  isSequenceNode,
} from '../types/collections';

// ---- fixtures -------------------------------------------------------------
// makePlaylist() ships with one sequence named 'Default' (sequences[0]).
function pl(): Playlist {
  return makePlaylist('Test');
}
function songNode(id: string): SongNode {
  return { nodeId: id, kind: 'song', songId: 's_' + id };
}
/** Deep snapshot for immutability assertions (structuredClone keeps it independent). */
function snap<T>(v: T): T {
  return structuredClone(v);
}
/** Collect every nodeId in the tree (depth-first). */
function allNodeIds(nodes: PlaylistNode[]): string[] {
  const out: string[] = [];
  for (const n of nodes) {
    out.push(n.nodeId);
    if (isSequenceNode(n)) out.push(...allNodeIds(n.children));
  }
  return out;
}

// ===========================================================================
// addSequence
// ===========================================================================
describe('addSequence', () => {
  it('appends a new sequence with the given name and empty children', () => {
    const before = pl();
    const input = snap(before);
    const out = addSequence(before, 'Chapter 2');
    expect(out.sequences).toHaveLength(2);
    expect(out.sequences[1].name).toBe('Chapter 2');
    expect(out.sequences[1].kind).toBe('sequence');
    expect(out.sequences[1].children).toEqual([]);
    // immutability: input untouched & a new object returned
    expect(before).toEqual(input);
    expect(out).not.toBe(before);
    expect(out.sequences).not.toBe(before.sequences);
  });

  it('gives the new sequence a fresh, unique nodeId', () => {
    const out = addSequence(pl(), 'X');
    expect(out.sequences[1].nodeId).not.toBe(out.sequences[0].nodeId);
  });
});

// ===========================================================================
// removeSequence
// ===========================================================================
describe('removeSequence', () => {
  it('removes the named top-level sequence', () => {
    const base = addSequence(pl(), 'Two');
    const targetId = base.sequences[1].nodeId;
    const input = snap(base);
    const out = removeSequence(base, targetId);
    expect(out.sequences).toHaveLength(1);
    expect(out.sequences[0].nodeId).toBe(base.sequences[0].nodeId);
    expect(base).toEqual(input); // input unchanged
  });

  it('REFUSES to remove the last remaining sequence (no-op, same reference)', () => {
    const base = pl();
    expect(base.sequences).toHaveLength(1);
    const out = removeSequence(base, base.sequences[0].nodeId);
    expect(out).toBe(base); // identity — nothing changed
    expect(out.sequences).toHaveLength(1);
  });

  it('is a no-op when the sequence id is unknown', () => {
    const base = addSequence(pl(), 'Two');
    const out = removeSequence(base, 'nope');
    expect(out).toBe(base);
    expect(out.sequences).toHaveLength(2);
  });
});

// ===========================================================================
// renameSequence
// ===========================================================================
describe('renameSequence', () => {
  it('renames the named sequence', () => {
    const base = pl();
    const id = base.sequences[0].nodeId;
    const input = snap(base);
    const out = renameSequence(base, id, 'Renamed');
    expect(out.sequences[0].name).toBe('Renamed');
    expect(out.sequences[0]).not.toBe(base.sequences[0]);
    expect(base).toEqual(input);
  });

  it('is a no-op when the sequence id is unknown', () => {
    const base = pl();
    const out = renameSequence(base, 'nope', 'X');
    expect(out).toBe(base);
  });
});

// ===========================================================================
// setSequenceTarget
// ===========================================================================
describe('setSequenceTarget', () => {
  it('sets a numeric time budget', () => {
    const base = pl();
    const id = base.sequences[0].nodeId;
    const input = snap(base);
    const out = setSequenceTarget(base, id, 600000);
    expect(out.sequences[0].targetMs).toBe(600000);
    expect(base).toEqual(input);
  });

  it('clears the budget with undefined', () => {
    const withTarget = setSequenceTarget(pl(), DEFAULT_SEQUENCE(pl()).nodeId, 1000);
    // use a real id from the same object
    const base = pl();
    const id = base.sequences[0].nodeId;
    const set = setSequenceTarget(base, id, 1000);
    const cleared = setSequenceTarget(set, id, undefined);
    expect(set.sequences[0].targetMs).toBe(1000);
    expect(cleared.sequences[0].targetMs).toBeUndefined();
    // unrelated sanity
    expect(withTarget.sequences[0].targetMs).toBeUndefined();
  });

  it('is a no-op when the sequence id is unknown', () => {
    const base = pl();
    const out = setSequenceTarget(base, 'nope', 5);
    expect(out).toBe(base);
  });
});

// ===========================================================================
// addNode + default-sequence fallback
// ===========================================================================
describe('addNode', () => {
  it('appends a node to the named sequence', () => {
    const base = addSequence(pl(), 'Two');
    const secondId = base.sequences[1].nodeId;
    const input = snap(base);
    const out = addNode(base, secondId, songNode('a'));
    expect(out.sequences[0].children).toHaveLength(0);
    expect(out.sequences[1].children).toHaveLength(1);
    expect((out.sequences[1].children[0] as SongNode).nodeId).toBe('a');
    expect(base).toEqual(input);
  });

  it('falls back to the DEFAULT sequence (sequences[0]) when the id is unknown', () => {
    const base = addSequence(pl(), 'Two');
    const out = addNode(base, 'does-not-exist', songNode('z'));
    expect(out.sequences[0].children.map((c) => c.nodeId)).toEqual(['z']);
    expect(out.sequences[1].children).toHaveLength(0);
  });

  it('preserves order on repeated appends', () => {
    const base = pl();
    const id = base.sequences[0].nodeId;
    const out = addNode(addNode(base, id, songNode('x')), id, songNode('y'));
    expect(out.sequences[0].children.map((c) => c.nodeId)).toEqual(['x', 'y']);
  });
});

// ===========================================================================
// addSong / addAlbum / addPocket convenience builders
// ===========================================================================
describe('addSong / addAlbum / addPocket', () => {
  it('addSong builds a SongNode with a fresh nodeId', () => {
    const base = pl();
    const id = base.sequences[0].nodeId;
    const out = addSong(base, id, 'sng_1');
    const node = out.sequences[0].children[0];
    expect(node.kind).toBe('song');
    expect((node as SongNode).songId).toBe('sng_1');
    expect(node.nodeId).toMatch(/^nd_/);
  });

  it('addAlbum builds an AlbumNode', () => {
    const base = pl();
    const out = addAlbum(base, base.sequences[0].nodeId, 'alb_1');
    const node = out.sequences[0].children[0];
    expect(node.kind).toBe('album');
    expect(node).toMatchObject({ kind: 'album', albumId: 'alb_1' });
  });

  it('addPocket builds a PocketNode', () => {
    const base = pl();
    const out = addPocket(base, base.sequences[0].nodeId, 'pkt_1');
    const node = out.sequences[0].children[0];
    expect(node.kind).toBe('pocket');
    expect(node).toMatchObject({ kind: 'pocket', pocketId: 'pkt_1' });
  });

  it('convenience builders fall back to the default sequence on unknown id', () => {
    const base = addSequence(pl(), 'Two');
    const out = addSong(base, 'unknown', 'sng_9');
    expect(out.sequences[0].children).toHaveLength(1);
    expect(out.sequences[1].children).toHaveLength(0);
  });
});

// ===========================================================================
// removeNode (recursive)
// ===========================================================================
describe('removeNode', () => {
  it('removes a top-level node from a sequence', () => {
    let base = pl();
    const id = base.sequences[0].nodeId;
    base = addNode(addNode(base, id, songNode('a')), id, songNode('b'));
    const input = snap(base);
    const out = removeNode(base, 'a');
    expect(out.sequences[0].children.map((c) => c.nodeId)).toEqual(['b']);
    expect(base).toEqual(input); // input unchanged
  });

  it('removes a node nested inside a sub-sequence', () => {
    // build: default seq contains a sub-sequence, which contains song 'deep'
    let base = pl();
    const topId = base.sequences[0].nodeId;
    const subSeq: PlaylistNode = {
      nodeId: 'sub',
      kind: 'sequence',
      name: 'Sub',
      children: [songNode('deep'), songNode('keep')],
    };
    base = addNode(base, topId, subSeq);
    const input = snap(base);
    const out = removeNode(base, 'deep');
    const outSub = out.sequences[0].children[0];
    expect(isSequenceNode(outSub) && outSub.children.map((c) => c.nodeId)).toEqual(['keep']);
    expect(base).toEqual(input); // deep removal did not mutate input
  });

  it('is a no-op (same reference) when the node id is unknown', () => {
    let base = pl();
    base = addNode(base, base.sequences[0].nodeId, songNode('a'));
    const out = removeNode(base, 'ghost');
    expect(out).toBe(base);
  });
});

// ===========================================================================
// moveNode
// ===========================================================================
describe('moveNode', () => {
  it('relocates a node to the END of another sequence', () => {
    let base = addSequence(pl(), 'Two');
    const firstId = base.sequences[0].nodeId;
    const secondId = base.sequences[1].nodeId;
    base = addNode(base, firstId, songNode('m'));
    base = addNode(base, secondId, songNode('existing'));
    const input = snap(base);

    const out = moveNode(base, 'm', secondId);
    expect(out.sequences[0].children).toHaveLength(0); // detached from source
    expect(out.sequences[1].children.map((c) => c.nodeId)).toEqual(['existing', 'm']); // appended last
    expect(base).toEqual(input); // input unchanged
  });

  it('moves a node out of a nested sub-sequence up to a top-level sequence', () => {
    let base = addSequence(pl(), 'Two');
    const topId = base.sequences[0].nodeId;
    const secondId = base.sequences[1].nodeId;
    const subSeq: PlaylistNode = {
      nodeId: 'sub',
      kind: 'sequence',
      name: 'Sub',
      children: [songNode('inner')],
    };
    base = addNode(base, topId, subSeq);

    const out = moveNode(base, 'inner', secondId);
    // 'inner' detached from the nested sub-sequence...
    const outSub = out.sequences[0].children[0];
    expect(isSequenceNode(outSub) && outSub.children).toEqual([]);
    // ...and now lives in the second top-level sequence
    expect(out.sequences[1].children.map((c) => c.nodeId)).toEqual(['inner']);
  });

  it('is a no-op when the destination sequence id is unknown', () => {
    let base = pl();
    base = addNode(base, base.sequences[0].nodeId, songNode('m'));
    const out = moveNode(base, 'm', 'nowhere');
    expect(out).toBe(base);
  });

  it('is a no-op when the node id is unknown', () => {
    const base = addSequence(pl(), 'Two');
    const out = moveNode(base, 'ghost', base.sequences[1].nodeId);
    expect(out).toBe(base);
  });

  it('refuses to move a sequence into its own subtree (would orphan it)', () => {
    // top-level seq 'sub' contains a deeper sequence 'inner'; moving 'sub' into 'inner' is illegal
    let base = pl();
    const topId = base.sequences[0].nodeId;
    const subSeq: PlaylistNode = {
      nodeId: 'sub',
      kind: 'sequence',
      name: 'Sub',
      children: [{ nodeId: 'inner', kind: 'sequence', name: 'Inner', children: [] }],
    };
    base = addNode(base, topId, subSeq);
    // promote 'sub' to a top-level sequence so it's a valid move source id-wise,
    // then attempt to move it into its own descendant 'inner'
    const out = moveNode(base, 'sub', 'inner');
    expect(out).toBe(base); // guarded no-op
  });

  it('refuses to move a node into itself', () => {
    const base = addSequence(pl(), 'Two');
    const id = base.sequences[1].nodeId;
    const out = moveNode(base, id, id);
    expect(out).toBe(base);
  });
});

// ===========================================================================
// DEFAULT_SEQUENCE
// ===========================================================================
describe('DEFAULT_SEQUENCE', () => {
  it('returns sequences[0]', () => {
    const base = addSequence(pl(), 'Two');
    expect(DEFAULT_SEQUENCE(base)).toBe(base.sequences[0]);
  });
});

// ===========================================================================
// cross-cutting immutability: chained ops never touch earlier snapshots
// ===========================================================================
describe('immutability across a chain of ops', () => {
  it('every op leaves prior states byte-for-byte unchanged', () => {
    const s0 = pl();
    const snap0 = snap(s0);

    const s1 = addSequence(s0, 'Two');
    const snap1 = snap(s1);

    const s2 = addSong(s1, s1.sequences[0].nodeId, 'sng_a');
    const snap2 = snap(s2);

    const s3 = moveNode(s2, allNodeIds(s2.sequences[0].children)[0], s2.sequences[1].nodeId);

    // all earlier states remain identical to their snapshots
    expect(s0).toEqual(snap0);
    expect(s1).toEqual(snap1);
    expect(s2).toEqual(snap2);
    // and the final state actually changed
    expect(s3.sequences[1].children).toHaveLength(1);
    expect(s3.sequences[0].children).toHaveLength(0);
  });
});
