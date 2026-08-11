#!/usr/bin/env node
// THE ORDERED RIP-QUEUE DRIVER — pump the owner's whole pocket corpus through the rip
// server, freshest taste first, without ever owning the capture itself.
//
//   node scripts/rip-backfill.mjs [--dry-run] [--once] [--recompute] [--source <backup>]
//
// ── WHAT IT IS ──────────────────────────────────────────────────────────────────────────────────
// The owner said "start the rip and musical backfill of all my pockets". The authoritative scope
// is his device backup (a .pocketdj zip; pockets.json inside): 81 pockets, ~4k unique songIds.
// This driver computes an ORDERED work list from that backup, skips everything the corpus already
// holds (by id OR by recording identity under a different id), classifies what is actually
// rippable, and then pumps the rip server's EXISTING durable queue SHALLOW — ~10 requests at a
// time, refilled as the S3 manifest grows. It never captures audio itself; POST /rip on the rip
// server (launchd com.pocketdj.ripserver, serial 1x-real-time Music.app + Audio Hijack capture)
// is the only way audio is made, and s3://<bucket>/rips/manifest.json (server single-writer)
// stays the only authority on what exists.
//
// ── WHY SHALLOW (8–12), NOT 24k JOBS AT ONCE ────────────────────────────────────────────────────
// The server's queue is durable and would happily hold the whole corpus, but a dumped queue makes
// the app's collection-RIP Stop meaningless (Stop cancels queued+active jobs — against 24k
// entries the user would be canceling for an hour) and freezes priorities for weeks of real-time
// capture. A shallow window keeps Stop instant, keeps the order re-decidable between refills
// (swap the backup, delete the state file, restart), and loses nothing: the capture is serial
// anyway, so the queue only ever needs enough depth that the worker never starves.
//
// ── COEXISTENCE WITH THE F10 NIGHTLY (rec-audio-nightly) ────────────────────────────────────────
// VERIFIED server-side: every enqueue door (/rip, /rip-collection) goes through acceptRip(),
// which (a) answers 'ready' from the manifest when the song already has audio, (b) JOINS an
// in-flight job via the single-flight `inflight` map (resourceKey = songId for digital), and
// (c) persists the durable queue as ONE file per songId (queue/<songId>.json), so even across a
// server restart one song can never hold two capture jobs. If the nightly's ≤50-song rip budget
// asks for a song this driver queued (or vice versa) the second request joins the first —
// double-enqueue is structurally impossible. The nightly therefore does NOT need to be disabled
// while the backfill runs: its requests are songs the rec engine actively wants (arguably higher
// priority) and they interleave into the same serial queue by arrival order. The only cost is
// shared capture bandwidth.
//
// ── RESUMABLE / STOPPABLE ───────────────────────────────────────────────────────────────────────
// State: ~/.pocketdj/backfill/rip-backfill-state.json — the single source of truth. Safe to
// delete: everything (ordering, skips, aliases, progress) recomputes from the backup + indexes +
// manifest; completed rips are re-detected from the manifest, so deletion never re-rips anything.
// Machine reboot: launchd (RunAtLoad + KeepAlive-on-crash) restarts the driver; in-flight
// captures survive on the server's own durable queue and are re-adopted by songId at startup.
//
// STOP (exact commands):
//   launchd-managed:  launchctl unload ~/Library/LaunchAgents/com.pocketdj.rip-backfill.plist
//                     (SIGTERM → state saved; `launchctl load …` resumes where it stopped)
//   manual run:       Ctrl-C, or  kill $(cat ~/.pocketdj/backfill/rip-backfill.pid)
// The app's collection-RIP Stop keeps working: the server queue never holds more than ~window
// backfill jobs, and when this driver observes a job canceled (the Stop path) it BACKS OFF —
// pauses refills for a cooldown and re-queues the row at the END — instead of fighting the user.
//
// ── SKIP DISCIPLINE (visible, never silent) ─────────────────────────────────────────────────────
//   has-audio        the id itself already has audio (S3 manifest / vinyl Raw via the analog
//                    index / My Digital) — nothing to do.
//   alias-analysed   the RECORDING already has audio under a DIFFERENT persistent id. Matched by
//                    the repo's one recording-identity doctrine (am-match normArtist +
//                    comparableTitle: version markers MUST agree, cosmetic markers ignored) plus
//                    the RecVersionIdentity spaceless-base key ("Pop Star" == "Popstar"). The
//                    id→alias mapping is RECORDED in the state file for lane 2's analysis fold.
//   drm-video        the library row is a .movpkg (DRM video container) — not capturable audio.
//   studio-artifact  smp_/lp_/ptn_/tk_ ids — device-local creations, never rippable (server law).
//   no-route         no appleMusicId AND no Library.xml row (exact or loose) — no capture route.
//                    ~15% of past attempts no-match; these are the predictable subset.
//   unresolved       the backup id doesn't exist in any current index. A FEW is data drift; a
//                    LOT is an id-namespace mismatch and the driver refuses to run (loud exit 2).
//
// ── SEGMENT-ATTRIBUTION LAW ─────────────────────────────────────────────────────────────────────
// This driver writes NO analysis rows, ever. It only records id→alias mappings; lane 2's fold
// must still key every analysis row on the rip's OWN segment identity (startMs), never
// trackNumber (f2b427c5). A fabricated row is worse than none.
import { execFile as execFileCb, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, readdirSync, renameSync, appendFileSync, rmSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { homedir } from 'node:os';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { normArtist, comparableTitle, loadLibraryXML, loadLibraryTSV, indexLibrary, findInLibrary } from './lib/am-match.mjs';

const execFile = promisify(execFileCb);
const REPO = dirname(dirname(fileURLToPath(import.meta.url)));

const a = {};
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === '--dry-run') a.dryRun = true;
  else if (k === '--once') a.once = true;
  else if (k === '--recompute') a.recompute = true;
  else if (k === '--verbose') a.verbose = true;
  else if (k.startsWith('--')) a[k.slice(2)] = process.argv[++i];
}

const HOME = homedir();
const CFG = {
  dryRun: !!a.dryRun,
  once: !!a.once,
  recompute: !!a.recompute,
  // The backup swap contract: keep the STABLE path as the default so a future backup is one file
  // copy (cp new.pocketdj ~/.pocketdj/backfill/source-backup.pocketdj + restart). When the stable
  // name is absent, the newest dated source-backup-*.pocketdj in the same dir is used (loudly).
  source: (a.source || join(HOME, '.pocketdj', 'backfill', 'source-backup.pocketdj')).replace(/^~/, HOME),
  // Default index paths resolve against THIS repo checkout (not the cwd) — same trio the rip
  // server loads its catalog from, so "resolves against the current index" means the same thing
  // to both processes.
  indexes: (a.indexes || ['current-index.json', 'apple-music-index.json', 'digital-index.json']
    .map((f) => join(REPO, 'public', f)).join(','))
    .split(',').map((s) => s.trim()).filter(Boolean),
  ripServer: (a['rip-server'] || process.env.RIP_SERVER || 'http://localhost:8787').replace(/\/$/, ''),
  ripToken: a['rip-token'] || process.env.RIP_TOKEN || '',
  bucket: a.bucket || process.env.POCKETDJ_RIPS_BUCKET || 'pocketdj-rips-011183829623',
  // Test seam: read the manifest from a local file instead of S3 (smoke tests / offline planning
  // against a snapshot). Production leaves this unset — S3 is the authority.
  manifestFile: (a['manifest-file'] || process.env.POCKETDJ_MANIFEST_FILE || '').replace(/^~/, HOME) || null,
  region: a.region || process.env.AWS_REGION || 'us-west-2',
  profile: a.profile || process.env.AWS_PROFILE || 'levi',
  // The library file the CAPTURE will match against (rip-one passes CFG.libraryXml through to the
  // rip skill), so classification and capture agree on what "has a library row" means.
  libraryXml: (a['library-xml'] || process.env.POCKETDJ_LIBRARY_XML || join(HOME, 'Downloads', 'Library.xml')).replace(/^~/, HOME),
  // The rip server's durable queue dir (same machine). Read-only here: startup adoption of
  // in-flight/queued captures, and the heartbeat's external-queue count.
  queueDir: (a['queue-dir'] || join(HOME, '.pocketdj', 'rips', 'queue')).replace(/^~/, HOME),
  state: (a.state || join(HOME, '.pocketdj', 'backfill', 'rip-backfill-state.json')).replace(/^~/, HOME),
  log: (a.log || join(HOME, '.pocketdj', 'rip-backfill.log')).replace(/^~/, HOME),
  pid: (a.pid || join(HOME, '.pocketdj', 'backfill', 'rip-backfill.pid')).replace(/^~/, HOME),
  // Target queued+in-flight depth on the server. 8–12 per the sizing doctrine; 10 default.
  window: Math.max(1, Math.min(Number(a.window) || 10, 24)),
  pollSec: Math.max(5, Number(a['poll-sec']) || 30),
  // How long a requested song may be neither in the manifest NOR visible as a job before it is
  // recorded failed ('lost') — covers a server that gave up + restarted (in-memory jobs gone).
  lostGraceSec: Math.max(60, Number(a['lost-grace-sec']) || 900),
  // Back-off after observing a canceled job (the app's collection-RIP Stop): stop refilling for
  // this long so Stop MEANS stop, then resume.
  cancelCooldownSec: Math.max(60, Number(a['cancel-cooldown-sec']) || 900),
  meanCaptureSec: Number(a['mean-capture-sec']) || 280, // measured corpus mean (challenge-corrected)
};

// ═════════════════════════════════════════ PURE PARTS ═══════════════════════════════════════════
// Exported for tests/unit/rip-backfill.test.mjs. Nothing below this banner reads disk or network.

/// Pocket play order: lastPlayedAt DESC with nulls LAST (freshest taste first), then EXPANDED
/// size DESC (a bigger pocket = more invested taste), then id ASC for full determinism — the
/// state file must recompute IDENTICALLY from the same backup or resume order silently shifts.
export function orderPockets(pockets, sizeById = null) {
  const size = (p) => (sizeById ? (sizeById.get(p.id) ?? 0) : (p.songIds || []).length);
  return [...pockets].sort((x, y) => {
    const xp = x.lastPlayedAt ?? -Infinity;
    const yp = y.lastPlayedAt ?? -Infinity;
    if (xp !== yp) return yp - xp;
    const xs = size(x); const ys = size(y);
    if (xs !== ys) return ys - xs;
    return String(x.id) < String(y.id) ? -1 : String(x.id) > String(y.id) ? 1 : 0;
  });
}

/// A pocket's songIds in play order: its OWN songIds first (their stored order is the owner's
/// order — preserved), then each child pocket's, depth-first in childPocketIds order. Cycle- and
/// dangling-child-safe: membership may live on children (the Pocket DAG), and a backup that
/// references a pocket it doesn't contain must not throw the whole plan away.
export function expandPocketSongIds(pocket, byPocketId, seen = new Set()) {
  if (!pocket || seen.has(pocket.id)) return [];
  seen.add(pocket.id);
  const out = [...(pocket.songIds || [])];
  for (const cid of pocket.childPocketIds || []) {
    out.push(...expandPocketSongIds(byPocketId.get(cid), byPocketId, seen));
  }
  return out;
}

/// The whole ordered work list: pockets ordered as above, expanded, de-duplicated across the
/// list with FIRST OCCURRENCE WINNING — a song shared by a fresh pocket and a stale one rips at
/// the fresh pocket's position. Returns [{songId, pocketId, pocketName}] (provenance = the
/// pocket that placed it, for the log and for priority arguments later).
export function buildWorkList(pockets) {
  const byPocketId = new Map(pockets.map((p) => [p.id, p]));
  const sizeById = new Map(pockets.map((p) => [p.id, expandPocketSongIds(p, byPocketId).length]));
  const seen = new Set();
  const out = [];
  for (const p of orderPockets(pockets, sizeById)) {
    for (const songId of expandPocketSongIds(p, byPocketId)) {
      if (seen.has(songId)) continue;
      seen.add(songId);
      out.push({ songId, pocketId: p.id, pocketName: p.name || '' });
    }
  }
  return out;
}

/// Recording-identity keys for the alias layer. Primary = am-match's exact key (normArtist +
/// comparableTitle — version markers must AGREE, cosmetic markers ignored; the repo's ONE answer
/// to "same recording?", per the tight-matching law). Secondary = the same key with the title's
/// word boundaries removed — RecVersionIdentity.spacelessKey's trick, because "Pop Star" and
/// "Popstar" are one record wearing Apple's two spellings. Secondary is consulted only when the
/// primary misses, and both sides of the index carry both keys, so the match stays symmetric.
export function recordingKeys(artist, title) {
  const na = normArtist(artist || '');
  const ct = comparableTitle(title || '');
  if (!na || !ct) return [];
  const keys = [na + ' ' + ct];
  const squashed = ct.replace(/ /g, '');
  if (squashed !== ct) keys.push(na + ' ' + squashed);
  return keys;
}

/// The analysed-audio corpus, keyed by recording identity. rows: [{id, artist, name, rank}] —
/// rank orders PREFERENCE when one recording has audio under several ids (lower wins):
///   0 manifest digital (own per-song mp3, analysis chases it automatically)
///   1 manifest analog with a per-song cut
///   2 vinyl index (analysed segments in current-index; Raw on /Volumes/RipBurnMix)
///   3 My Digital files
///   4 manifest analog, album-level only
export function buildAliasIndex(rows) {
  const idx = new Map();
  for (const r of rows) {
    for (const k of recordingKeys(r.artist, r.name)) {
      if (!idx.has(k)) idx.set(k, []);
      idx.get(k).push(r);
    }
  }
  return idx;
}

/// Resolve one song against the corpus: the best DIFFERENT id holding the same recording, or
/// null. Deterministic: rank ASC then id ASC. Primary key first; spaceless only as fallback.
export function findAlias(aliasIndex, song) {
  for (const k of recordingKeys(song.artist, song.name)) {
    const hits = (aliasIndex.get(k) || []).filter((r) => r.id !== song.id);
    if (hits.length) {
      hits.sort((x, y) => (x.rank - y.rank) || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
      return hits[0];
    }
  }
  return null;
}

/// Device-local studio artifacts — never rippable (rip-server law, same regex).
export const STUDIO_ID_RE = /^(smp_|lp_|ptn_|tk_)/;

/// A DRM video container in the owner's library (music videos download as .movpkg). Not
/// capturable audio; the row is skipped with its own visible reason.
export function isDrmVideo(song) {
  return /\.movpkg\/?$/i.test(String(song?.pointer?.fileLocation || ''));
}

/// Skip/rip classification for ONE resolved song. Precedence is deliberate:
///   1. own audio (nothing to do)  2. alias (feeds lane 2's fold — checked before drm/route so a
///   DRM row whose recording exists elsewhere still yields its mapping)  3. studio  4. drm-video
///   5. capture route: appleMusicId, else Library.xml (exact preferred, loose accepted — the rip
///   skill accepts both), else no-route. libIndex null = no Library.xml available: rows stay
///   rippable as 'library-unprobed' (visible; guessing "no hope" without the library would skip
///   ~900 songs on a hunch).
export function classifySong(song, ctx) {
  if (ctx.audioIds && ctx.audioIds.has(song.id)) {
    return { action: 'skip', reason: 'has-audio', via: ctx.audioVia ? (ctx.audioVia.get(song.id) || null) : null };
  }
  const alias = ctx.aliasIndex ? findAlias(ctx.aliasIndex, song) : null;
  if (alias) return { action: 'skip', reason: 'alias-analysed', aliasOf: alias.id };
  if (STUDIO_ID_RE.test(String(song.id || ''))) return { action: 'skip', reason: 'studio-artifact' };
  if (isDrmVideo(song)) return { action: 'skip', reason: 'drm-video' };
  if (song.appleMusicId) return { action: 'rip', route: 'am-id' };
  if (ctx.libIndex) {
    const { match } = findInLibrary(ctx.libIndex, song.artist || '', song.name || '');
    if (match === 'exact') return { action: 'rip', route: 'library-exact' };
    if (match === 'loose') return { action: 'rip', route: 'library-loose' };
    return { action: 'skip', reason: 'no-route' };
  }
  return { action: 'rip', route: 'library-unprobed' };
}

/// Classify the whole work list. Unresolvable ids are SKIPPED with 'unresolved' (visible), never
/// dropped. Returns { rips, skips, aliases } — aliases is the id→aliasId mapping lane 2 folds.
export function classifyAll(entries, byId, ctx) {
  const rips = [];
  const skips = {};
  const aliases = {};
  for (const e of entries) {
    const song = byId.get(e.songId);
    if (!song) { skips[e.songId] = { reason: 'unresolved', pocketId: e.pocketId }; continue; }
    const c = classifySong(song, ctx);
    if (c.action === 'rip') {
      rips.push({ songId: e.songId, route: c.route, pocketId: e.pocketId, pocketName: e.pocketName });
    } else {
      skips[e.songId] = { reason: c.reason, pocketId: e.pocketId, ...(c.via ? { via: c.via } : {}), ...(c.aliasOf ? { aliasOf: c.aliasOf } : {}) };
      if (c.aliasOf) aliases[e.songId] = c.aliasOf;
    }
  }
  return { rips, skips, aliases };
}

/// Loud-not-empty check: how much of the backup resolves against the current indexes. A backup
/// from a different id namespace resolves ~0% and MUST abort (exit 2) rather than compute an
/// empty work list that looks like a finished backfill.
export function resolutionReport(songIds, byId) {
  const hist = (ids) => {
    const h = {};
    for (const id of ids) { const ns = (String(id).match(/^[a-z]+_/) || ['(none)'])[0]; h[ns] = (h[ns] || 0) + 1; }
    return h;
  };
  const unresolved = songIds.filter((id) => !byId.has(id));
  return {
    total: songIds.length,
    resolved: songIds.length - unresolved.length,
    rate: songIds.length ? (songIds.length - unresolved.length) / songIds.length : 0,
    unresolvedSample: unresolved.slice(0, 10),
    backupNamespaces: hist(songIds),
  };
}

/// Remaining capture time. Real-time capture: mean measured 280 s/song; the pump feeds a serial
/// worker, so ETA is linear in what's left (yield losses only shorten it).
export function etaHours(remaining, meanSec) {
  return Math.round((remaining * meanSec) / 36) / 100;
}

// ═══════════════════════════════════════ IMPL (I/O) ═════════════════════════════════════════════

const log = (...m) => {
  const line = `[rip-backfill ${new Date().toISOString()}] ${m.join(' ')}`;
  console.error(line);
  try { mkdirSync(dirname(CFG.log), { recursive: true }); appendFileSync(CFG.log, line + '\n'); } catch { /* logging must never kill the pump */ }
};

// ---- state (single source of truth; atomic writes; delete = full recompute) ----
function loadState() {
  try { return JSON.parse(readFileSync(CFG.state, 'utf8')); } catch { /* fresh */ }
  return { v: 1, plan: null, done: {}, failed: {}, requested: {}, aliases: {}, retryBudget: {} };
}
function saveState(s) {
  mkdirSync(dirname(CFG.state), { recursive: true });
  const tmp = CFG.state + '.tmp';
  writeFileSync(tmp, JSON.stringify(s));
  renameSync(tmp, CFG.state);
}

// ---- the backup ----
function resolveSourcePath() {
  if (existsSync(CFG.source)) return CFG.source;
  // stable name absent → newest dated sibling (source-backup-*.pocketdj), loudly
  const dir = dirname(CFG.source);
  try {
    const dated = readdirSync(dir).filter((f) => /^source-backup.*\.pocketdj$/.test(f)).sort();
    if (dated.length) {
      const pick = join(dir, dated[dated.length - 1]);
      log(`source ${CFG.source} absent — using newest dated backup ${pick}`);
      return pick;
    }
  } catch { /* dir absent */ }
  return null;
}
function readPockets(sourcePath) {
  let raw;
  if (statSync(sourcePath).isDirectory()) raw = readFileSync(join(sourcePath, 'pockets.json'), 'utf8');
  else if (/\.json$/i.test(sourcePath)) raw = readFileSync(sourcePath, 'utf8');
  else raw = execFileSync('unzip', ['-p', sourcePath, 'pockets.json'], { maxBuffer: 512 * 1024 * 1024 }).toString('utf8');
  const doc = JSON.parse(raw);
  const pockets = Array.isArray(doc) ? doc : (doc.pockets || []);
  if (!pockets.length) throw new Error(`no pockets in ${sourcePath}`);
  return pockets;
}

// ---- the catalog indexes ----
function loadIndexes() {
  const byId = new Map();
  const vinylIds = new Set();   // analog index rows — Raw audio on /Volumes/RipBurnMix
  const digitalIds = new Set(); // "My Digital" rows — decodable files on disk/S3
  for (const f of CFG.indexes) {
    if (!existsSync(f)) { log(`WARNING: index missing: ${f}`); continue; }
    const idx = JSON.parse(readFileSync(f, 'utf8'));
    const sourceType = idx.manifest?.sourceType || 'analog';
    const sourceName = idx.manifest?.sourceName || '';
    for (const s of idx.songs || []) {
      if (!byId.has(s.id)) byId.set(s.id, s);
      if (sourceType === 'analog') vinylIds.add(s.id);
      else if (sourceName === 'My Digital') digitalIds.add(s.id);
    }
    log(`loaded ${f}: ${(idx.songs || []).length} songs (${sourceName || sourceType})`);
  }
  if (!byId.size) throw new Error('no index songs loaded — RIP-server catalog files missing?');
  return { byId, vinylIds, digitalIds };
}

// ---- S3 manifest (authoritative: what has audio) ----
async function fetchManifest() {
  if (CFG.manifestFile) return JSON.parse(readFileSync(CFG.manifestFile, 'utf8') || '{}');
  const out = await execFile('aws', ['s3', 'cp', `s3://${CFG.bucket}/rips/manifest.json`, '-',
                                    '--profile', CFG.profile, '--region', CFG.region],
                             { maxBuffer: 256 * 1024 * 1024 });
  return JSON.parse(out.stdout || '{}');
}

// ---- rip server ----
const authHeaders = () => ({ 'content-type': 'application/json', ...(CFG.ripToken ? { authorization: `Bearer ${CFG.ripToken}` } : {}) });
async function serverHealth() {
  try {
    const r = await fetch(`${CFG.ripServer}/health`, { headers: authHeaders() });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}
async function postRip(songId) {
  const r = await fetch(`${CFG.ripServer}/rip`, { method: 'POST', headers: authHeaders(), body: JSON.stringify({ songId }) });
  if (r.status === 404) return { outcome: 'unknown' };
  if (!r.ok) throw new Error(`POST /rip ${r.status}`);
  const doc = await r.json();
  if (doc.phase === 'ready') return { outcome: 'ready', url: doc.url };
  return { outcome: 'accepted', jobId: doc.jobId || null };
}
async function getJob(jobId) {
  const r = await fetch(`${CFG.ripServer}/jobs/${encodeURIComponent(jobId)}`, { headers: authHeaders() });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`GET /jobs ${r.status}`);
  return r.json();
}
async function getStatus(songId) {
  const r = await fetch(`${CFG.ripServer}/status/${encodeURIComponent(songId)}`, { headers: authHeaders() });
  if (!r.ok) throw new Error(`GET /status ${r.status}`);
  return r.json();
}

// ---- planning ----
function planStale(state, sourcePath) {
  if (!state.plan) return true;
  const st = statSync(sourcePath);
  return state.plan.sourcePath !== sourcePath
    || state.plan.sourceMtimeMs !== st.mtimeMs
    || state.plan.sourceBytes !== st.size;
}

async function computePlan(state, sourcePath) {
  log(`planning from ${sourcePath}`);
  const pockets = readPockets(sourcePath);
  const entries = buildWorkList(pockets);
  log(`${pockets.length} pockets → ${entries.length} unique songs (ordered, first-occurrence-wins)`);

  const { byId, vinylIds, digitalIds } = loadIndexes();
  const rep = resolutionReport(entries.map((e) => e.songId), byId);
  log(`resolution: ${rep.resolved}/${rep.total} (${Math.round(rep.rate * 100)}%) — backup namespaces ${JSON.stringify(rep.backupNamespaces)}`);
  if (rep.rate < 0.5) {
    log(`FATAL: backup id namespace mismatch — ${rep.total - rep.resolved} of ${rep.total} ids do not exist in the current indexes.`);
    log(`unresolved sample: ${rep.unresolvedSample.join(', ')}`);
    log('refusing to compute an empty work list. Check --source and --indexes.');
    process.exit(2);
  }

  const manifest = await fetchManifest();
  log(`manifest: ${Object.keys(manifest).length} songs with audio`);

  // Own-id audio + the alias corpus (every id that carries decodable audio TODAY, with metadata)
  const audioIds = new Set();
  const audioVia = new Map();
  const corpus = [];
  for (const [id, e] of Object.entries(manifest)) {
    audioIds.add(id); audioVia.set(id, `manifest-${e.source || '?'}`);
    const s = byId.get(id);
    if (s) corpus.push({ id, artist: s.artist, name: s.name, rank: e.source === 'digital' ? 0 : (e.cutKey ? 1 : 4) });
  }
  for (const id of vinylIds) {
    if (!audioIds.has(id)) { audioIds.add(id); audioVia.set(id, 'vinyl-raw'); }
    const s = byId.get(id);
    if (s && !manifest[id]) corpus.push({ id, artist: s.artist, name: s.name, rank: 2 });
  }
  for (const id of digitalIds) {
    if (!audioIds.has(id)) { audioIds.add(id); audioVia.set(id, 'digital-file'); }
    const s = byId.get(id);
    if (s && !manifest[id]) corpus.push({ id, artist: s.artist, name: s.name, rank: 3 });
  }
  const aliasIndex = buildAliasIndex(corpus);
  log(`alias corpus: ${corpus.length} audio-bearing rows, ${aliasIndex.size} recording keys`);

  let libIndex = null;
  if (existsSync(CFG.libraryXml)) {
    const entriesLib = loadLibraryXML(CFG.libraryXml);
    libIndex = indexLibrary(entriesLib);
    log(`library index: ${libIndex.count} tracks (${CFG.libraryXml})`);
  } else {
    const tsv = CFG.libraryXml.replace(/\.xml$/, '.tsv');
    if (existsSync(tsv)) { libIndex = indexLibrary(loadLibraryTSV(tsv)); log(`library index (tsv): ${libIndex.count} tracks`); }
    else log(`WARNING: no Library.xml at ${CFG.libraryXml} — id-less rows stay rippable as 'library-unprobed' (no no-route classification)`);
  }

  const { rips, skips, aliases } = classifyAll(entries, byId, { audioIds, audioVia, aliasIndex, libIndex });

  const st = statSync(sourcePath);
  state.plan = {
    sourcePath, sourceMtimeMs: st.mtimeMs, sourceBytes: st.size, computedAt: Date.now(),
    pockets: pockets.length, entries: entries.length,
    rips, skips,
  };
  // Aliases ACCUMULATE across recomputes (lane 2 reads them; a source swap must not lose the
  // mappings the previous backup discovered).
  state.aliases = { ...(state.aliases || {}), ...aliases };
  // A recompute keeps done/failed/requested: the manifest re-confirms done anyway, and failed
  // carries the retry budget. Deleting the state FILE is the full-recompute lever.
  saveState(state);

  const byReason = {};
  for (const s of Object.values(skips)) byReason[s.reason] = (byReason[s.reason] || 0) + 1;
  const byRoute = {};
  for (const r of rips) byRoute[r.route] = (byRoute[r.route] || 0) + 1;
  log(`plan: ${rips.length} to rip ${JSON.stringify(byRoute)}, ${Object.keys(skips).length} skipped ${JSON.stringify(byReason)}`);
  log(`expected capture time at ${CFG.meanCaptureSec}s/song: ~${etaHours(rips.length, CFG.meanCaptureSec)} h of serial capture`);
  return state;
}

// ---- the pump ----
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let stopRequested = false;

function pendingList(state) {
  const done = state.done; const failed = state.failed; const requested = state.requested;
  return state.plan.rips.filter((r) => !done[r.songId] && !failed[r.songId] && !requested[r.songId]);
}

function classifyJobError(errText) {
  const e = String(errText || '');
  if (e === 'canceled') return 'canceled';
  if (/no audio captured|not in the library|no-match/i.test(e)) return 'no-match';
  return 'system';
}

async function pump(state) {
  // one-instance lock — a launchd copy + a manual copy double-pumps the window
  mkdirSync(dirname(CFG.pid), { recursive: true });
  try {
    const old = Number(readFileSync(CFG.pid, 'utf8'));
    if (old && old !== process.pid) { try { process.kill(old, 0); log(`FATAL: another rip-backfill is running (pid ${old})`); process.exit(3); } catch { /* stale */ } }
  } catch { /* no pid file */ }
  writeFileSync(CFG.pid, String(process.pid));

  // Respect captures already on the server at startup: adopt OUR songs from the durable queue
  // dir (they occupy window slots; never re-posted), and never disturb foreign jobs.
  let adopted = 0;
  try {
    for (const f of readdirSync(CFG.queueDir).filter((x) => x.endsWith('.json'))) {
      try {
        const rec = JSON.parse(readFileSync(join(CFG.queueDir, f), 'utf8'));
        const mine = state.plan.rips.some((r) => r.songId === rec.songId);
        if (mine && !state.done[rec.songId] && !state.requested[rec.songId]) {
          state.requested[rec.songId] = { jobId: rec.jobId || null, atMs: Date.now(), adopted: true };
          adopted += 1;
        }
      } catch { /* unreadable entry — foreign or torn write */ }
    }
  } catch { /* queue dir absent (server elsewhere / not yet started) */ }
  if (adopted) log(`adopted ${adopted} already-queued capture(s) from ${CFG.queueDir}`);

  let cooldownUntil = 0;
  let completionsThisRun = 0;
  let firstRequestAt = 0;

  for (;;) {
    if (stopRequested) break;

    const health = await serverHealth();
    if (!health) {
      log('rip server unreachable — waiting (captures resume server-side; nothing lost)');
      await sleep(CFG.pollSec * 1000);
      if (CFG.once) break;
      continue;
    }

    let manifest;
    try { manifest = await fetchManifest(); }
    catch (e) {
      log(`manifest fetch failed (${e.message}) — retrying next cycle`);
      await sleep(CFG.pollSec * 1000);
      if (CFG.once) break;
      continue;
    }

    // reconcile: anything with audio is DONE, whatever we thought of it before
    for (const id of Object.keys(state.requested)) {
      if (manifest[id]) {
        state.done[id] = { atMs: Date.now(), via: 'manifest' };
        delete state.requested[id];
        completionsThisRun += 1;
      }
    }
    for (const id of Object.keys(state.failed)) {
      if (manifest[id]) { state.done[id] = { atMs: Date.now(), via: 'manifest-late' }; delete state.failed[id]; }
    }

    // poll in-flight jobs for terminal errors (the server self-heals transient errors with its
    // own capped retries first; an 'error' here may still be superseded by a retry job — trust
    // /status over a stale job record)
    for (const [id, req] of Object.entries(state.requested)) {
      let terminalError = null;
      try {
        if (req.jobId) {
          const job = await getJob(req.jobId);
          if (job && job.phase === 'error') terminalError = job.error || 'error';
          else if (job) { delete req.missingSince; continue; }   // queued/ripping/uploading — fine
          // job 404 (server restarted) → fall through to /status
        }
        const st = await getStatus(id);
        if (st.ready) continue; // manifest pass next cycle picks it up
        if (st.job) {           // an active job exists (possibly a self-heal retry) — track it
          req.jobId = st.job.jobId || req.jobId;
          delete req.missingSince;
          if (terminalError) log(`  ${id}: previous attempt errored (${terminalError}) — server retry in flight`);
          continue;
        }
        if (terminalError) {
          const reason = classifyJobError(terminalError);
          if (reason === 'canceled') {
            // The app's Stop path — back off and re-queue at the END, no attempt consumed:
            // Stop must MEAN stop, not "the daemon instantly re-queues what I just killed".
            log(`  ${id}: canceled server-side (collection-RIP Stop?) — cooling down ${CFG.cancelCooldownSec}s`);
            cooldownUntil = Date.now() + CFG.cancelCooldownSec * 1000;
            delete state.requested[id];
            const row = state.plan.rips.find((r) => r.songId === id);
            if (row) state.plan.rips = [...state.plan.rips.filter((r) => r.songId !== id), row];
            continue;
          }
          const attempts = (req.priorAttempts || 0) + 1;
          state.failed[id] = { reason, error: String(terminalError).slice(0, 300), attempts, atMs: Date.now() };
          delete state.requested[id];
          log(`  ✗ ${id}: ${reason} (attempt ${attempts}) — moving on`);
          continue;
        }
        // No job anywhere, not ready: give the server a grace window (durable-queue resume,
        // saveManifest lag), then record it lost rather than holding a slot forever.
        req.missingSince = req.missingSince || Date.now();
        if (Date.now() - req.missingSince > CFG.lostGraceSec * 1000) {
          const attempts = (req.priorAttempts || 0) + 1;
          state.failed[id] = { reason: 'lost', attempts, atMs: Date.now() };
          delete state.requested[id];
          log(`  ✗ ${id}: no job and no audio after ${CFG.lostGraceSec}s — recorded lost (attempt ${attempts})`);
        }
      } catch (e) {
        log(`  poll ${id} failed (${e.message}) — next cycle`);
      }
    }

    // refill the shallow window
    const inCooldown = Date.now() < cooldownUntil;
    let pending = pendingList(state);
    while (!inCooldown && Object.keys(state.requested).length < CFG.window && pending.length) {
      const next = pending[0];
      pending = pending.slice(1);
      if (manifest[next.songId]) { state.done[next.songId] = { atMs: Date.now(), via: 'manifest' }; continue; }
      try {
        const r = await postRip(next.songId);
        if (!firstRequestAt) firstRequestAt = Date.now();
        if (r.outcome === 'ready') { state.done[next.songId] = { atMs: Date.now(), via: 'ready' }; continue; }
        if (r.outcome === 'unknown') {
          state.failed[next.songId] = { reason: 'unknown-to-server', attempts: 99, atMs: Date.now() };
          log(`  ✗ ${next.songId}: server does not know this id (RIP_SOURCES stale?) — terminal`);
          continue;
        }
        // priorAttempts rides the request so a retry's SECOND failure records attempts 2
        // (terminal) — "retry ONCE later, not in a loop" is enforced by this number.
        state.requested[next.songId] = { jobId: r.jobId, atMs: Date.now(), priorAttempts: (state.retryBudget || {})[next.songId] || 0 };
        log(`  → queued ${next.songId} (${next.route}; pocket "${next.pocketName}")`);
      } catch (e) {
        log(`  POST /rip ${next.songId} failed (${e.message}) — next cycle`);
        break; // server hiccup: stop refilling this cycle, keep what we have
      }
    }

    // completion / retry pass — when the pass drains, every once-failed row goes back into
    // pending EXACTLY once (per-id retryBudget guard); a second failure is final. Never a loop.
    const remaining = pendingList(state).length + Object.keys(state.requested).length;
    if (remaining === 0) {
      state.retryBudget = state.retryBudget || {};
      const retriable = Object.entries(state.failed)
        .filter(([id, f]) => f.attempts === 1 && !state.retryBudget[id]);
      if (retriable.length) {
        log(`pass complete — retrying ${retriable.length} failure(s) ONCE`);
        for (const [id, f] of retriable) {
          state.retryBudget[id] = f.attempts;   // carried into requested.priorAttempts on re-POST
          delete state.failed[id];              // pendingList picks the row back up in plan order
        }
        saveState(state);
        continue;
      }
      heartbeat(state, { external: externalQueueDepth(state), etaSec: 0 });
      log('ALL DONE — nothing pending, nothing in flight. Exiting 0 (launchd will not respawn a clean exit).');
      break;
    }

    // heartbeat — the one-line JSON the lead monitors
    const meanSec = completionsThisRun >= 3 && firstRequestAt
      ? Math.max(60, Math.round((Date.now() - firstRequestAt) / 1000 / completionsThisRun))
      : CFG.meanCaptureSec;
    heartbeat(state, { external: externalQueueDepth(state), meanSec });

    saveState(state);
    if (CFG.once) { log('--once: single cycle complete'); break; }
    await sleep(CFG.pollSec * 1000);
  }
  saveState(state);
  try { rmSync(CFG.pid); } catch { /* already gone */ }
}

function externalQueueDepth(state) {
  try {
    return readdirSync(CFG.queueDir).filter((f) => f.endsWith('.json'))
      .filter((f) => !state.requested[basename(f, '.json')]).length;
  } catch { return 0; }
}

function heartbeat(state, { external = 0, meanSec = CFG.meanCaptureSec, etaSec = null } = {}) {
  const done = Object.keys(state.done).length;
  const failed = Object.keys(state.failed).length;
  const skipped = Object.keys(state.plan.skips).length;
  const inflight = Object.keys(state.requested).length;
  const pending = pendingList(state).length;
  const total = state.plan.entries;
  const hb = {
    hb: 1, t: new Date().toISOString(),
    done, failed, skipped, inflight, pending, total,
    externalQueue: external,
    meanCaptureSec: meanSec,
    etaHours: etaSec === 0 ? 0 : etaHours(pending + inflight, meanSec),
  };
  log(`HEARTBEAT ${JSON.stringify(hb)}`);
}

// ---- main ----
async function main() {
  const sourcePath = resolveSourcePath();
  if (!sourcePath) {
    log(`FATAL: no backup at ${CFG.source} (and no dated source-backup-*.pocketdj beside it)`);
    process.exit(2);
  }
  const state = loadState();
  if (CFG.recompute || planStale(state, sourcePath)) {
    if (state.plan) log('source changed (or --recompute) — recomputing the plan; progress is kept');
    await computePlan(state, sourcePath);
  } else {
    log(`plan loaded from state (${state.plan.rips.length} rip rows, computed ${new Date(state.plan.computedAt).toISOString()})`);
  }
  if (CFG.dryRun) {
    const pending = pendingList(state);
    log(`dry-run: would pump ${pending.length} songs (window ${CFG.window}); first 15:`);
    for (const r of pending.slice(0, 15)) log(`  ${r.songId}  [${r.route}]  ← "${r.pocketName}"`);
    heartbeat(state, {});
    return;
  }
  process.on('SIGTERM', () => { stopRequested = true; log('SIGTERM — saving state and stopping (resume with launchctl load / re-run)'); });
  process.on('SIGINT', () => { stopRequested = true; log('SIGINT — saving state and stopping'); });
  await pump(state);
}

if (process.argv[1] && process.argv[1].endsWith('rip-backfill.mjs')) {
  main().catch((e) => { log(`FATAL: ${e.stack || e.message}`); process.exit(1); });
}
