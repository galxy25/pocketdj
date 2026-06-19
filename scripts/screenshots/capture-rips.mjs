// Storybook capture for the stream/download (rip-on-demand) feature (§31). Shoots:
//   31 ▶/⤓ buttons on song rows, 32 the mini player (cached song playing),
//   33 Settings ▸ Rip server, 34 Setlist ▸ Rip all / Play all / Burn.
//
// Needs the dev server (npm run dev) + the rip server (scripts/rip-server.mjs) up,
// and at least one already-ripped song in the public manifest (for the player shot).
//   PDJ_BASE=http://localhost:5177 RIP_URL=http://localhost:8787 \
//     node scripts/screenshots/capture-rips.mjs
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(__dirname, '../../docs/storybook');
const BASE = process.env.PDJ_BASE || 'http://localhost:5173';
const RIP_URL = process.env.RIP_URL || 'http://localhost:8787';
const MANIFEST = 'https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com/rips/manifest.json';
const MOBILE = { width: 402, height: 874 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function shot(page, name) { await page.screenshot({ path: `${OUT}/${name}.png` }); console.log('  saved', name + '.png'); }
async function click(page, sel, { timeout = 5000 } = {}) { try { await page.locator(sel).first().click({ timeout }); return true; } catch { return false; } }
async function setInput(page, sel, value) {
  await page.evaluate(({ sel, value }) => { const el = document.querySelector(sel); if (!el) return; const d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value'); d.set.call(el, value); el.dispatchEvent(new Event('input', { bubbles: true })); }, { sel, value });
}

async function main() {
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: MOBILE, deviceScaleFactor: 2 })).newPage();
  console.log('Capturing into', OUT);
  const go = async (path, { settle = 2200, wait } = {}) => {
    await page.goto(BASE + path, { waitUntil: 'load' });
    await page.waitForFunction(() => !document.querySelector('.pdj-boot'), { timeout: 90_000 }).catch(() => {});
    if (wait) await page.waitForSelector(wait, { timeout: 15_000 }).catch(() => {});
    await sleep(settle);
  };

  // boot + configure the rip server + grab a cached song id for the player shot
  await go('/playlists');
  await page.waitForFunction(() => window.__pdj, { timeout: 30_000 }).catch(() => {});
  await page.evaluate(async () => { let c = await window.__pdj.counts(), n = 0; while (c.songs === 0 && n++ < 40) { await new Promise((r) => setTimeout(r, 500)); c = await window.__pdj.counts(); } });
  const cachedId = await page.evaluate(async (m) => { try { const r = await fetch(m + '?t=' + Date.now(), { cache: 'no-store' }); const j = await r.json(); return Object.keys(j)[0] || null; } catch { return null; } }, MANIFEST);
  await page.evaluate((u) => localStorage.setItem('pdj.rip.v1', JSON.stringify({ serverUrl: u, token: '' })), RIP_URL);

  // seed a demo setlist for the setlist-actions shot
  await page.evaluate(async () => {
    const idb = await new Promise((res) => { const q = indexedDB.open('pocketdj'); q.onsuccess = () => res(q.result); });
    const now = Date.now(), uid = () => crypto.randomUUID();
    const pl = { id: 'pls_sbrip', name: 'Sunset Rooftop', createdAt: now, updatedAt: now, sequences: [{ nodeId: 'nd_' + uid(), kind: 'sequence', name: 'Set', children: [] }] };
    const tracks = [
      { songId: 'sng_x1', artist: 'Bryson Tiller', name: 'Outta Time', bpm: 120, camelot: '8A', lengthMs: 200000, source: 'explicit', sequenceName: 'Warm Up' },
      { songId: 'sng_x2', artist: 'Childish Gambino', name: 'Redbone', bpm: 122, camelot: '9A', lengthMs: 210000, source: 'explicit', sequenceName: 'Warm Up' },
      { songId: 'sng_x3', artist: 'SZA', name: 'Good Days', bpm: 121, camelot: '8A', lengthMs: 270000, source: 'pocket', sequenceName: 'Peak' },
      { songId: '', artist: '', name: 'sample of This Land Is Mine', isText: true, source: 'explicit', sequenceName: 'Peak' },
    ];
    const set = { id: 'set_sbrip', playlistId: 'pls_sbrip', name: 'Sunset Rooftop — take 1', seed: 's', generatedAt: now, totalMs: 680000, tracks };
    await new Promise((res) => { const tx = idb.transaction(['playlists', 'setlists'], 'readwrite'); tx.objectStore('playlists').put(pl); tx.objectStore('setlists').put(set); tx.oncomplete = res; });
    idb.close();
  });

  // 31 — ▶/⤓ rip buttons on song rows
  await go('/browse', { wait: '[data-testid="item-grid"]' });
  await click(page, '[data-testid="type-song"]');
  await sleep(1500);
  await shot(page, '31-rip-buttons-mobile');

  // 32 — mini player (play a cached vinyl song = instant, no rip). RIP_PLAY_ID +
  // RIP_PLAY_SEARCH let the caller pick a song that's in the LOCAL catalog.
  void cachedId;
  const playId = process.env.RIP_PLAY_ID;
  if (playId) {
    if (process.env.RIP_PLAY_SEARCH) { await setInput(page, '[data-testid="browser-search"]', process.env.RIP_PLAY_SEARCH); await sleep(1200); }
    const played = await click(page, `[data-testid="rip-play-${playId}"]`);
    await sleep(played ? 2500 : 500);
    await shot(page, '32-mini-player-mobile');
  } else {
    console.warn('  (set RIP_PLAY_ID + RIP_PLAY_SEARCH to capture the mini-player shot)');
  }

  // 33 — Settings ▸ Rip server
  await go('/map?group=genre');
  await click(page, '[data-testid="open-settings"]');
  await page.waitForSelector('[data-testid="settings-rip"]', { timeout: 8000 }).catch(() => {});
  await page.evaluate(() => document.querySelector('[data-testid="settings-rip"]')?.scrollIntoView({ block: 'center' }));
  await sleep(500);
  await shot(page, '33-settings-rip-server-mobile');
  await click(page, '.pdj-modal__close, [aria-label="Close"]');

  // 34 — Setlist ▸ Rip all / Play all / Burn
  await go('/playlists/pls_sbrip/setlist/set_sbrip', { wait: '[data-testid="setlist-view"]', settle: 1800 });
  await shot(page, '34-setlist-actions-mobile');

  await browser.close();
  console.log('Done.');
}
main().catch((e) => { console.error(e); process.exit(1); });
