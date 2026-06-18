// Storybook capture for the multi-source + online-search update (§27). Shoots:
//   27 multi-source selector (browser), 28 Settings ▸ Sources panel,
//   29 show/hide collection filters, 30 online search (OpenSearch), 31 Settings ▸ Online search.
//
// Loads the Apple Music (Local) source (so the selector shows two sources), seeds
// a demo playlist + pocket (so the membership filters appear), and sets the
// read-only search creds (from env — never hard-coded) so the online toggle works.
// The dev server's Vite proxy forwards /pocketdj/* to the aoss origin, so online
// search returns real results locally.
//
//   npm run dev    # in another shell
//   PDJ_ES_AKID=… PDJ_ES_SECRET=… node scripts/screenshots/capture-search-sources.mjs
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
async function click(page, sel, { timeout = 5000 } = {}) {
  try { await page.locator(sel).first().click({ timeout }); return true; } catch { console.warn('  (no click', sel + ')'); return false; }
}
async function setInput(page, sel, value) {
  await page.evaluate(({ sel, value }) => {
    const el = document.querySelector(sel);
    if (!el) return;
    const d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
    d.set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }, { sel, value });
}

async function main() {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: MOBILE, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  console.log('Capturing into', OUT);

  const go = async (path, { settle = 2200, wait } = {}) => {
    await page.goto(BASE + path, { waitUntil: 'load' });
    await page.waitForFunction(() => !document.querySelector('.pdj-boot'), { timeout: 90_000 }).catch(() => {});
    if (wait) await page.waitForSelector(wait, { timeout: 15_000 }).catch(() => {});
    await sleep(settle);
  };

  // boot + wait for the vinyl seed, then load Apple Music (second source)
  await go('/browse');
  await page.waitForFunction(() => window.__pdj, { timeout: 30_000 }).catch(() => {});
  await page.evaluate(async () => {
    let c = await window.__pdj.counts(), n = 0;
    while (c.songs === 0 && n++ < 40) { await new Promise((r) => setTimeout(r, 500)); c = await window.__pdj.counts(); }
    const has = (await window.__pdj.collections()) && true;
    void has;
  });
  await page.evaluate(() => window.__pdj.loadIndexUrl(location.origin + '/apple-music-index.json', 'Apple Music (Local)')).catch(() => {});
  await sleep(1500);

  // seed a demo playlist (3 songs) + pocket (1 song) so the membership filters show
  await page.evaluate(async () => {
    const idb = await new Promise((res) => { const r = indexedDB.open('pocketdj'); r.onsuccess = () => res(r.result); });
    const songs = await new Promise((res) => { const out = []; const cur = idb.transaction('items', 'readonly').objectStore('items').index('by_type').openCursor(IDBKeyRange.only('song')); cur.onsuccess = (e) => { const c = e.target.result; if (c && out.length < 4) { out.push(c.value.id); c.continue(); } else res(out); }; });
    const uid = () => crypto.randomUUID(); const now = Date.now();
    const pl = { id: 'pls_sbdemo', name: 'Sunset Rooftop', createdAt: now, updatedAt: now, sequences: [{ nodeId: 'nd_' + uid(), kind: 'sequence', name: 'Warm Up', children: songs.slice(0, 3).map((id) => ({ nodeId: 'nd_' + uid(), kind: 'song', songId: id })) }] };
    const pk = { id: 'pkt_sbdemo', name: 'Peak Hour', kind: 'harmonic', songIds: [songs[3]], albumIds: [], childPocketIds: [], createdAt: now, updatedAt: now };
    await new Promise((res) => { const tx = idb.transaction(['playlists', 'pockets'], 'readwrite'); tx.objectStore('playlists').put(pl); tx.objectStore('pockets').put(pk); tx.oncomplete = res; });
    idb.close();
  });

  // set read-only search creds (so the online toggle appears) — from env, not hard-coded
  const akid = process.env.PDJ_ES_AKID, secret = process.env.PDJ_ES_SECRET;
  if (akid && secret) {
    await page.evaluate(({ akid, secret }) => localStorage.setItem('pdj.search.v1', JSON.stringify({ creds: { accessKeyId: akid, secretAccessKey: secret }, online: false })), { akid, secret });
  } else {
    console.warn('  (no PDJ_ES_AKID/SECRET — online-search shots will be skipped)');
  }

  // 27 — multi-source selector (browser), dropdown open showing both sources
  await go('/browse', { wait: '[data-testid="item-grid"]' });
  await click(page, '[data-testid="source-trigger"]');
  await sleep(500);
  await shot(page, '27-multi-source-selector-mobile');

  // 28 — Settings ▸ Sources panel (multi-select + Apple Music load/remove)
  await go('/map?group=genre');
  await click(page, '[data-testid="open-settings"]');
  await page.waitForSelector('[data-testid="settings-sources"]', { timeout: 8000 }).catch(() => {});
  await sleep(500);
  await shot(page, '28-settings-sources-mobile'); // captures Sources + Online-search panels
  await click(page, '.pdj-modal__close, [aria-label="Close"]');

  // 29 — show/hide collection filters (songs view, show dropdown open)
  await go('/browse', { wait: '[data-testid="item-grid"]' });
  await click(page, '[data-testid="type-song"]');
  await sleep(1200);
  await click(page, '[data-testid="include-trigger"]');
  await sleep(500);
  await shot(page, '29-show-hide-filters-mobile');

  // 30 — online search (OpenSearch): go online + query
  if (akid && secret) {
    await go('/browse', { wait: '[data-testid="item-grid"]' });
    await click(page, '[data-testid="type-song"]');
    await sleep(800);
    await click(page, '[data-testid="search-mode-toggle"]'); // → online
    await sleep(400);
    await setInput(page, '[data-testid="browser-search"]', 'midnight');
    await sleep(1800);
    await shot(page, '30-online-search-mobile');
  }

  await browser.close();
  console.log('Done.');
}

main().catch((e) => { console.error(e); process.exit(1); });
