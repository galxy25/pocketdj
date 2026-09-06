// A port the OS says is free, for tests that must spawn a REAL server.
//
// Why this exists: every rip e2e spawns the real scripts/rip-server.mjs, and each one used to
// hand-pick a constant port ("NOT 8787, NOT 8811, …"). Hand-picked constants only avoid the
// collisions their author happened to know about, and they are GLOBAL state: two runs of the
// suite at once — two agents in one checkout, a watch-mode window left open, a leaked server
// from an earlier run — put two servers on the same number.
//
// That collision is unusually nasty here, and no boot probe can fix it: the loser's listen()
// throws EADDRINUSE, but rip-server does its whole startup (manifest load, backstop sweep)
// BEFORE it listens, so the child logs a clean boot and only dies at the end. Meanwhile the
// probe's /health is answered by the STRANGER — which, when the collision is between two runs
// of the SAME file, is byte-identical in bucket, catalog size and token. The suite then runs to
// completion against someone else's server, writing into someone else's tmpdir, and every
// assertion that reads OUR work directory fails with `expected false to be true`.
//
// Measured: two concurrent `vitest run tests/unit/rip-heal-blast-radius-e2e.test.mjs` — one
// passed in 10.6s, the other failed all 4 in 50.5s with an empty rig log.
//
// Ask the kernel instead. Note the residual window: we close the probe socket before the child
// binds, so callers should still retry on EADDRINUSE (the boot loops in the e2es do).
import net from 'node:net';

export function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}
