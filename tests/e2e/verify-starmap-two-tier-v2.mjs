/**
 * Headless Playwright verification for the two-tier star map v2 changes:
 *  1. Slider is gone (no data-testid="tier-slider" element)
 *  2. Tier-1 shows categories + hazy overlays, stars dimmed
 *  3. Clicking a category overlay drills into focused tier-2 (sub-genres)
 *  4. Album stars at tier-2 have visible name labels (data-testid="star-label-*")
 *  5. Clicking a star navigates to solar system
 *  6. Zero uncaught JS errors throughout
 */
import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROOF_DIR = path.join(__dirname, 'proof/starmap-two-tier-v2');
const BASE = 'http://localhost:5198';

const errors = [];
let browser;

try {
  browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();

  // Collect uncaught errors
  page.on('pageerror', (err) => errors.push(err.message));

  // ---- Load app + ingest catalog ----
  await page.goto(BASE + '/', { waitUntil: 'networkidle' });

  // Ingest the real catalog
  await page.evaluate(async () => {
    const idx = await (await fetch('/current-index.json')).json();
    await window.__pdj.loadIndex(idx, 'My Vinyl');
  });

  // Navigate to /map
  await page.goto(BASE + '/map', { waitUntil: 'networkidle' });

  // Wait for the star map scene to be present
  await page.waitForSelector('[data-testid="starmap-scene"]', { timeout: 10000 });

  // ---- Screenshot (a): Tier 1 — categories + hazy overlays, NO slider ----
  const screenshotA = path.join(PROOF_DIR, 'a-tier1-categories.png');
  await page.screenshot({ path: screenshotA, fullPage: false });
  console.log('Screenshot A saved:', screenshotA);

  // Assert: NO tier-slider
  const slider = await page.$('[data-testid="tier-slider"]');
  if (slider) {
    throw new Error('FAIL: tier-slider element is still present — should be removed');
  }
  console.log('PASS: no tier-slider element');

  // Assert: at least one constellation overlay exists
  const overlays = await page.$$('[data-testid^="constellation-overlay-"]');
  if (overlays.length === 0) {
    throw new Error('FAIL: no constellation overlays found at tier 1');
  }
  console.log(`PASS: found ${overlays.length} constellation overlays`);

  // Assert: stars are dimmed on tier 1 (spot check first star visible)
  const dimmedStars = await page.$$('.pdj-star.is-dimmed');
  if (dimmedStars.length === 0) {
    throw new Error('FAIL: no dimmed stars at tier 1 — expected stars to be non-interactive');
  }
  console.log(`PASS: ${dimmedStars.length} dimmed stars at tier 1`);

  // Assert: no star labels visible at tier 1
  const tier1Labels = await page.$$('[data-testid^="star-label-"]');
  if (tier1Labels.length > 0) {
    throw new Error(`FAIL: ${tier1Labels.length} star labels found at tier 1 — should only show at tier 2`);
  }
  console.log('PASS: no star labels at tier 1');

  // ---- Click first overlay to drill into tier 2 ----
  const firstOverlay = overlays[0];
  const overlayTestId = await firstOverlay.getAttribute('data-testid');
  const clickedCategory = overlayTestId.replace('constellation-overlay-', '');
  console.log(`Drilling into category: "${clickedCategory}"`);
  await firstOverlay.click();

  // Wait for back button to appear (confirms tier-2 loaded)
  await page.waitForSelector('[data-testid="back-to-tier1"]', { timeout: 8000 });
  // Also wait for stars to be clickable (interactive, not dimmed)
  await page.waitForSelector('[data-star]', { timeout: 8000 });

  // ---- Screenshot (b): Tier 2 — sub-genre constellations + album labels ----
  const screenshotB = path.join(PROOF_DIR, 'b-tier2-subgenres-with-labels.png');
  await page.screenshot({ path: screenshotB, fullPage: false });
  console.log('Screenshot B saved:', screenshotB);

  // Assert: "← All genres" back button visible
  const backBtn = await page.$('[data-testid="back-to-tier1"]');
  if (!backBtn) {
    throw new Error('FAIL: back-to-tier1 button not found at tier 2');
  }
  console.log('PASS: back-to-tier1 button visible');

  // Assert: NO tier-slider at tier 2 either
  const slider2 = await page.$('[data-testid="tier-slider"]');
  if (slider2) {
    throw new Error('FAIL: tier-slider element is present at tier 2 — should be removed');
  }
  console.log('PASS: no tier-slider at tier 2 either');

  // Assert: album name labels present at tier 2
  const tier2Labels = await page.$$('[data-testid^="star-label-"]');
  if (tier2Labels.length === 0) {
    throw new Error('FAIL: no star-label elements found at tier 2 — album name labels missing');
  }
  console.log(`PASS: ${tier2Labels.length} album name labels found at tier 2`);

  // Assert: interactive (clickable) stars present
  const clickableStars = await page.$$('[data-star]');
  if (clickableStars.length === 0) {
    throw new Error('FAIL: no clickable stars at tier 2');
  }
  console.log(`PASS: ${clickableStars.length} clickable stars at tier 2`);

  // Assert: breadcrumb label visible showing focused category
  const crumb = await page.$('[data-testid="focus-label"]');
  if (!crumb) {
    throw new Error('FAIL: focus-label breadcrumb not found at tier 2');
  }
  console.log('PASS: focus-label breadcrumb visible');

  // ---- Click first album star -> solar system ----
  // Use JS dispatchEvent on the <g> element to avoid child-intercept issues
  // (the cover-art <image> intercepts pointer events from Playwright's native click).
  const firstStar = clickableStars[0];
  const starTestId = await firstStar.getAttribute('data-testid');
  console.log(`Clicking star: ${starTestId}`);
  await firstStar.dispatchEvent('click');

  // Wait for solar system scene (URL changes to /map/:albumId)
  await page.waitForURL(/\/map\/.+/, { timeout: 8000 });

  // ---- Screenshot (c): Solar system ----
  const screenshotC = path.join(PROOF_DIR, 'c-solar-system.png');
  await page.screenshot({ path: screenshotC, fullPage: false });
  console.log('Screenshot C saved:', screenshotC);

  // Assert: we're in the solar system view
  const solarHeader = await page.$('.pdj-solar__title');
  if (!solarHeader) {
    throw new Error('FAIL: solar system header (.pdj-solar__title) not found after star click');
  }
  console.log('PASS: solar system rendered after clicking album star');

  // ---- Final error check ----
  if (errors.length > 0) {
    throw new Error(`FAIL: ${errors.length} uncaught JS error(s):\n  ${errors.join('\n  ')}`);
  }
  console.log('PASS: 0 uncaught JS errors');

  console.log('\n=== ALL ASSERTIONS PASSED ===');
  console.log('Screenshots:');
  console.log('  (a)', screenshotA);
  console.log('  (b)', screenshotB);
  console.log('  (c)', screenshotC);

} finally {
  if (browser) await browser.close();
}
