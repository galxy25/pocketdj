import { test, expect } from '@playwright/test';
import { setupApp, captureTranscript, writeProof, hasOp } from './helpers';

test('export to zip then re-import on a cleared DB restores identical counts (offline)', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);

  const counts = () =>
    page.evaluate(() => (window as unknown as { __pdj: { counts: () => Promise<{ albums: number; songs: number }> } }).__pdj.counts());
  const clear = () =>
    page.evaluate(() => (window as unknown as { __pdj: { clear: () => Promise<void> } }).__pdj.clear());

  const before = await counts();
  expect(before).toEqual({ albums: 18, songs: 172 });

  // export -> capture the download
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByTestId('export-button').click(),
  ]);
  const zipPath = await download.path();
  expect(hasOp(tx, 'export.zip')).toBe(true);

  // wipe everything
  await clear();
  const cleared = await counts();
  expect(cleared).toEqual({ albums: 0, songs: 0 });

  // re-import the zip via the file input (no network — art is bundled)
  await page.getByTestId('import-input').setInputFiles(zipPath);
  await expect.poll(async () => (await counts()).albums).toBe(18);
  const after = await counts();
  expect(after).toEqual(before);
  // console events arrive async over CDP — poll for the transcript line
  await expect.poll(() => hasOp(tx, 'import.zip')).toBe(true);

  await writeProof('export-import', page, tx);
});
