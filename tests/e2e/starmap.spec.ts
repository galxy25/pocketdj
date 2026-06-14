import { test, expect } from '@playwright/test';
import { setupApp, captureTranscript, writeProof, FIXTURE, hasOp } from './helpers';

interface FixtureAlbum { id: string; trackList: string[] }

test('star map renders genre constellations and a star per album', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await page.goto('/map');
  await expect(page.getByTestId('starmap-scene')).toBeVisible();
  // one star per album
  await expect(page.locator('[data-testid^="star-"]')).toHaveCount(FIXTURE.albums.length);
  // at least a few genre constellations
  const constellations = await page.locator('[data-testid^="constellation-"]').count();
  expect(constellations).toBeGreaterThanOrEqual(5);
  expect(hasOp(tx, 'starmap.layout')).toBe(true);
  await writeProof('starmap', page, tx);
});

test('clicking a star opens the solar system with one planet per track', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  // pick a fixture album that actually has tracks
  const album = (FIXTURE.albums as FixtureAlbum[]).find((a) => a.trackList.length >= 3)!;
  await page.goto(`/map/${album.id}`);
  await expect(page.getByTestId('solar-system')).toBeVisible();
  await expect(page.getByTestId('solar-sun')).toBeVisible();
  await expect(page.locator('[data-testid^="planet-"]')).toHaveCount(album.trackList.length);
  await writeProof('solar-system', page, tx);
});

test('every track is labelled by default; clicking a planet opens the song popup (Esc closes)', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  const album = (FIXTURE.albums as FixtureAlbum[]).find((a) => a.trackList.length >= 3)!;
  await page.goto(`/map/${album.id}`);
  // names show for ALL tracks by default
  await expect(page.locator('[data-testid="track-label"]')).toHaveCount(album.trackList.length);
  // click a planet -> metadata popup
  await page.locator('[data-testid^="planet-sng_"]').first().click();
  await expect(page.getByTestId('song-modal')).toBeVisible();
  await expect(page.getByTestId('song-detail')).toBeVisible();
  // Escape closes it
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('song-modal')).toBeHidden();
  await writeProof('song-detail', page, tx);
});
