// Storybook screenshot capture for PocketDJ.
//
// Drives the LOCAL dev server (http://localhost:5173, auto-seeded from
// public/current-index.json) with a real Chromium and saves PNGs into
// docs/storybook/. Mobile shots are 402x874 (iPhone-16-Pro-ish); a couple of
// desktop shots are 1280x800 where the wider layout reads better.
//
// Run the dev server first (npm run dev), then: node scripts/screenshots/capture.mjs
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(__dirname, '../../docs/storybook');
const BASE = process.env.PDJ_BASE || 'http://localhost:5173';
const MOBILE = { width: 402, height: 874 };
const DESKTOP = { width: 1280, height: 800 };
// A recognizable, art-backed, audio-analyzed album for the album/solar shots.
const ALBUM_ID = 'alb_1082ea222381'; // ABBA — Greatest Hits

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** New page at a viewport, navigate, and wait past boot + cover hydration. */
async function open(browser, viewport, path, { settle = 3500 } = {}) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  await page.goto(BASE + path, { waitUntil: 'load' });
  // Wait out the "Loading your vinyl…" boot screen (seed import into IndexedDB).
  await page
    .waitForFunction(() => !document.querySelector('.pdj-boot'), { timeout: 90_000 })
    .catch(() => {});
  await sleep(settle); // progressive cover art pops in over a few seconds
  return { ctx, page };
}

async function shot(page, name) {
  const file = `${OUT}/${name}.png`;
  await page.screenshot({ path: file });
  console.log('  saved', name + '.png');
}

async function safeClick(page, selector, { timeout = 4000 } = {}) {
  try {
    await page.locator(selector).first().click({ timeout });
    return true;
  } catch {
    console.warn('  (could not click', selector + ')');
    return false;
  }
}

async function main() {
  const browser = await chromium.launch();
  console.log('Capturing into', OUT);

  // 1) Star map — MOBILE GRID, genre mode (constellation cards: title + count + cover mosaic)
  {
    const { ctx, page } = await open(browser, MOBILE, '/map?group=genre');
    await page.waitForSelector('[data-testid="constellation-grid"]', { timeout: 15_000 }).catch(() => {});
    await sleep(2500); // let cover mosaics hydrate
    await shot(page, '01-starmap-genre-mobile');

    // 1b) drill into the first genre card -> sub-genres (mode toggle hides, "← All genres" appears)
    const firstCard = page.locator('[data-testid^="cgrid-"]').first();
    if (await firstCard.count()) {
      await firstCard.click().catch(() => {});
      await sleep(2500);
      await shot(page, '02-starmap-genre-drilled-mobile');
    }
    await ctx.close();
  }

  // 2) Star map — BPM mode (metronome glyph + BPM range cards)
  {
    const { ctx, page } = await open(browser, MOBILE, '/map?group=bpm');
    await page.waitForSelector('[data-testid="constellation-grid"]', { timeout: 15_000 }).catch(() => {});
    await sleep(1500);
    await shot(page, '03-starmap-bpm-mobile');
    await ctx.close();
  }

  // 3) Star map — KEY mode (cards tinted by Camelot color; Unknown neutral)
  {
    const { ctx, page } = await open(browser, MOBILE, '/map?group=key');
    await page.waitForSelector('[data-testid="constellation-grid"]', { timeout: 15_000 }).catch(() => {});
    await sleep(1500);
    await shot(page, '04-starmap-key-mobile');
    await ctx.close();
  }

  // 3d) Settings popout (force refresh & re-pull catalog) — open from the gear
  {
    const { ctx, page } = await open(browser, MOBILE, '/map?group=genre');
    await safeClick(page, '[data-testid="open-settings"]');
    await page.waitForSelector('[data-testid="settings-modal"]', { timeout: 8000 }).catch(() => {});
    await sleep(600);
    await shot(page, '05-settings-modal-mobile');
    await ctx.close();
  }

  // 4) Solar system view (/map/:id): album=sun, songs=orbiting planets
  {
    const { ctx, page } = await open(browser, MOBILE, '/map/' + ALBUM_ID);
    await page.waitForSelector('[data-testid="solar-system"]', { timeout: 15_000 }).catch(() => {});
    await sleep(3000); // orbits + sun cover
    await shot(page, '06-solar-system-mobile');

    // 4b) click the sun -> audio track popup
    if (await safeClick(page, '[data-testid="solar-sun"]')) {
      await page.waitForSelector('[data-testid="audio-tracks"]', { timeout: 8000 }).catch(() => {});
      await sleep(600);
      await shot(page, '07-solar-audio-popup-mobile');
    }
    await ctx.close();
  }

  // 5) Browser — album grid (default), mobile + desktop
  {
    const { ctx, page } = await open(browser, MOBILE, '/browse');
    await page.waitForSelector('[data-testid="item-grid"]', { timeout: 15_000 }).catch(() => {});
    await sleep(2500);
    await shot(page, '08-browser-albums-mobile');

    // 5b) switch to Songs -> per-row BPM/key/Camelot list
    if (await safeClick(page, '[data-testid="type-song"]')) {
      await sleep(1800);
      await shot(page, '09-browser-songs-mobile');
    }
    await ctx.close();
  }
  {
    const { ctx, page } = await open(browser, DESKTOP, '/browse');
    await page.waitForSelector('[data-testid="item-grid"]', { timeout: 15_000 }).catch(() => {});
    await sleep(2500);
    await shot(page, '10-browser-albums-desktop');
    // Open the filter builder so the filter/sort/import bar is visible
    await safeClick(page, '[data-testid="filter-add"]');
    await sleep(800);
    await shot(page, '11-browser-filter-desktop');
    await ctx.close();
  }

  // 6) Single-album view (/album/:id): track table + audio footer + action buttons
  {
    const { ctx, page } = await open(browser, MOBILE, '/album/' + ALBUM_ID);
    await page.waitForSelector('[data-testid="album-track-table"]', { timeout: 15_000 }).catch(() => {});
    await sleep(2500);
    await shot(page, '12-album-tracktable-mobile');

    // 6b) tap a track row -> song detail card
    const row = page.locator('[data-testid^="song-row-"]').first();
    if (await row.count()) {
      await row.click().catch(() => {});
      await page.waitForSelector('[data-testid="song-detail"]', { timeout: 8000 }).catch(() => {});
      await sleep(500);
      await shot(page, '13-song-detail-modal-mobile');
      // close it
      await safeClick(page, '[data-testid="song-detail-close"]');
      await sleep(300);
    }

    // 6c) album editor modal (Cover URL + Genre dropdown+free-text)
    if (await safeClick(page, '[data-testid="edit-album"]')) {
      await page.waitForSelector('[data-testid="edit-modal"]', { timeout: 8000 }).catch(() => {});
      await sleep(500);
      await shot(page, '14-edit-album-modal-mobile');
      await safeClick(page, '[data-testid="field-cancel"]');
      await sleep(300);
    }

    // 6d) audio-analysis editor modal
    if (await safeClick(page, '[data-testid="edit-audio"]')) {
      await page.waitForSelector('[data-testid="audio-edit-modal"]', { timeout: 8000 }).catch(() => {});
      await sleep(500);
      await shot(page, '15-edit-audio-modal-mobile');
      await safeClick(page, '[data-testid="audio-edit-cancel"]');
      await sleep(300);
    }
    await ctx.close();
  }

  // 7) Song editor + Delete-track confirm — open the song editor from the Songs list
  {
    const { ctx, page } = await open(browser, MOBILE, '/browse');
    await page.waitForSelector('[data-testid="item-grid"]', { timeout: 15_000 }).catch(() => {});
    await safeClick(page, '[data-testid="type-song"]');
    await sleep(1500);
    // Click the first row's edit (✎) button
    const editBtn = page.locator('[data-testid^="edit-item-open-"]').first();
    if (await editBtn.count()) {
      await editBtn.click().catch(() => {});
      await page.waitForSelector('[data-testid="edit-modal"]', { timeout: 8000 }).catch(() => {});
      await sleep(500);
      await shot(page, '16-edit-song-modal-mobile');

      // Delete track -> mobile confirm (Delete / Nope)
      if (await safeClick(page, '[data-testid="track-delete-open"]')) {
        await page.waitForSelector('[data-testid="delete-confirm"]', { timeout: 6000 }).catch(() => {});
        await sleep(400);
        await shot(page, '17-delete-track-confirm-mobile');
        await safeClick(page, '[data-testid="delete-nope"]'); // don't actually delete
      }
    }
    await ctx.close();
  }

  await browser.close();
  console.log('Done.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
