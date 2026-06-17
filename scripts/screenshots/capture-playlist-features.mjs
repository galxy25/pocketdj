// Storybook capture for the playlist-features PR — re-shoots the screens this PR
// changed (settings, browser songs, song detail, add-to picker, playlists list,
// playlist detail, setlist). Uses ONE browser context so a seeded demo playlist
// (songs + a cue + a note) persists across the shots and the enriched rows show
// real data.
//
// Run the dev server first (npm run dev), then:
//   node scripts/screenshots/capture-playlist-features.mjs
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(__dirname, '../../docs/storybook');
const BASE = process.env.PDJ_BASE || 'http://localhost:5173';
const MOBILE = { width: 402, height: 874 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function shot(page, name) {
  await page.screenshot({ path: `${OUT}/${name}.png` });
  console.log('  saved', name + '.png');
}
async function safeClick(page, sel, { timeout = 5000 } = {}) {
  try { await page.locator(sel).first().click({ timeout }); return true; } catch { console.warn('  (no click', sel + ')'); return false; }
}

async function seedDemo(page) {
  return page.evaluate(async () => {
    const idb = await new Promise((res, rej) => { const r = indexedDB.open('pocketdj'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
    const songs = await new Promise((res) => {
      const out = []; const cur = idb.transaction('items', 'readonly').objectStore('items').index('by_type').openCursor(IDBKeyRange.only('song'));
      cur.onsuccess = (e) => { const c = e.target.result; if (c && out.length < 6) { const v = c.value; if (v.bpm != null && v.albumId) out.push(v); c.continue(); } else res(out); };
    });
    const uuid = () => crypto.randomUUID();
    const now = Date.now();
    const nd = (kind, extra) => ({ nodeId: 'nd_' + uuid(), kind, ...extra });
    const pl = {
      id: 'pls_' + uuid(), name: 'Sunset Rooftop', createdAt: now, updatedAt: now,
      sequences: [
        { nodeId: 'nd_' + uuid(), kind: 'sequence', name: 'Warm Up', children: [
          nd('song', { songId: songs[0].id, note: 'open cold — let it breathe' }),
          nd('song', { songId: songs[1].id }),
          nd('song', { songId: songs[2].id }),
          nd('text', { text: 'sample of This Land Is Mine Land' }),
        ] },
        { nodeId: 'nd_' + uuid(), kind: 'sequence', name: 'Peak', children: [
          nd('song', { songId: songs[3].id }),
          nd('song', { songId: songs[4].id }),
          nd('song', { songId: songs[5].id }),
        ] },
      ],
    };
    await new Promise((res, rej) => { const tx = idb.transaction('playlists', 'readwrite'); tx.objectStore('playlists').put(pl); tx.oncomplete = res; tx.onerror = () => rej(tx.error); });
    idb.close();
    localStorage.setItem('pdj.addToPrefs.v1', JSON.stringify({ playlistId: pl.id })); // for the "last used" badge
    return { playlistId: pl.id };
  });
}

async function main() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: MOBILE, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  console.log('Capturing into', OUT);

  const go = async (path, { settle = 2500, wait } = {}) => {
    await page.goto(BASE + path, { waitUntil: 'load' });
    await page.waitForFunction(() => !document.querySelector('.pdj-boot'), { timeout: 90_000 }).catch(() => {});
    if (wait) await page.waitForSelector(wait, { timeout: 15_000 }).catch(() => {});
    await sleep(settle);
  };

  // boot once + seed the demo playlist
  await go('/playlists');
  const ids = await seedDemo(page);

  // 05 — Settings: data backup/restore + collections-preserving refresh + migrations + reset
  await go('/map?group=genre');
  await safeClick(page, '[data-testid="open-settings"]');
  await page.waitForSelector('[data-testid="settings-modal"]', { timeout: 8000 }).catch(() => {});
  await sleep(600);
  await shot(page, '05-settings-modal-mobile');

  // 09 — Browser songs + "Hide songs already in…" multi-select dropdown (open, "any" checked)
  await go('/browse', { wait: '[data-testid="item-grid"]' });
  await safeClick(page, '[data-testid="type-song"]');
  await sleep(1500);
  await safeClick(page, '[data-testid="exclude-trigger"]');
  await safeClick(page, '[data-testid="exclude-any"]');
  await sleep(600);
  await shot(page, '09-browser-songs-mobile');

  // 21 — Playlists list with ⤒ Import / ⤓ Export entry points
  await go('/playlists', { settle: 900 });
  await shot(page, '21-playlists-list-mobile');

  // 22 — Playlist detail: cover art + bpm/key per row, a note, a cue, ▲/▼ reorder,
  //      per-chapter + total counts/runtime, ⤓ Export
  await go('/playlists/' + ids.playlistId, { wait: '[data-testid="playlist-detail"]', settle: 3000 });
  await shot(page, '22-playlist-detail-mobile');

  // 13 — Song detail modal (album cover art + "open album ↗" link) from a playlist row
  await safeClick(page, '[data-testid^="node-open-"]');
  await page.waitForSelector('[data-testid="song-detail"]', { timeout: 8000 }).catch(() => {});
  await sleep(800);
  await shot(page, '13-song-detail-modal-mobile');

  // 23 — Setlist (realized via ▶ Play): editable name, sections, the cue row, per-track notes
  await go('/playlists/' + ids.playlistId, { wait: '[data-testid="playlist-detail"]' });
  await safeClick(page, '[data-testid="playlist-play"]');
  await page.waitForSelector('[data-testid="setlist-view"]', { timeout: 10_000 }).catch(() => {});
  await sleep(1500);
  await shot(page, '23-setlist-take2-mobile');

  // 20 — Add-to-collection picker showing the "last used" default
  await go('/browse', { wait: '[data-testid="item-grid"]' });
  await safeClick(page, '[data-testid="type-song"]');
  await sleep(1200);
  await safeClick(page, '[data-testid^="song-row-"]');
  await page.waitForSelector('[data-testid="song-detail"]', { timeout: 8000 }).catch(() => {});
  await safeClick(page, '[data-testid^="add-to-collection-"]');
  await page.waitForSelector('[data-testid="add-collection-modal"]', { timeout: 8000 }).catch(() => {});
  await sleep(600);
  await shot(page, '20-add-to-collection-picker-mobile');

  await browser.close();
  console.log('Done.');
}

main().catch((e) => { console.error(e); process.exit(1); });
