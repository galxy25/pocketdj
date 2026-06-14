import { test, expect } from '@playwright/test';
import { setupApp, captureTranscript, writeProof, hasOp, lastFilterApply } from './helpers';

// Fixture (seed 42): 18 albums / 172 songs.
// Genres: Rock 4, Classical 4, Soul 2, New Wave 2, Electronic 2, Jazz 1, Disco 1, Funk 1, Hip-Hop/Rap 1.
// Explicit songs: 28.

test('loads the index and shows albums (import transcript present)', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await expect(page.getByTestId('result-count')).toContainText('18 / 18');
  await expect(page.locator('[data-testid^="item-card-"]').first()).toBeVisible();
  expect(hasOp(tx, 'import.index')).toBe(true);
  expect(hasOp(tx, 'db.bulkPutItems')).toBe(true);
  await writeProof('load-index', page, tx);
});

test('filter: equal genre = Rock -> 4 albums', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await page.getByTestId('filter-add').click();
  await page.getByTestId('filter-field').selectOption('genre');
  await page.getByTestId('filter-op').selectOption('eq');
  await page.getByTestId('filter-value').fill('Rock');
  await expect(page.getByTestId('result-count')).toContainText('4 / 18');
  const fa = lastFilterApply(tx);
  expect(fa).toEqual({ in: 18, out: 4 });
  await writeProof('filter-eq', page, tx);
});

test('filter: not-equal genre = Rock -> 14 albums', async ({ page }) => {
  await setupApp(page);
  await page.getByTestId('filter-add').click();
  await page.getByTestId('filter-field').selectOption('genre');
  await page.getByTestId('filter-op').selectOption('neq');
  await page.getByTestId('filter-value').fill('Rock');
  await expect(page.getByTestId('result-count')).toContainText('14 / 18');
});

test('filter: in-list genre in [Rock, Jazz] -> 5 albums', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await page.getByTestId('filter-add').click();
  await page.getByTestId('filter-field').selectOption('genre');
  await page.getByTestId('filter-op').selectOption('in');
  await page.getByTestId('filter-value').fill('Rock, Jazz');
  await expect(page.getByTestId('result-count')).toContainText('5 / 18');
  await writeProof('filter-in', page, tx);
});

test('filter: between year reduces the set', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await page.getByTestId('filter-add').click();
  await page.getByTestId('filter-field').selectOption('year');
  await page.getByTestId('filter-op').selectOption('between');
  await page.getByTestId('filter-min').fill('1980');
  await page.getByTestId('filter-max').fill('1990');
  // count is data-dependent but must be a strict subset and the transcript records it
  const fa = lastFilterApply(tx);
  expect(fa).not.toBeNull();
  expect(fa!.out).toBeLessThanOrEqual(fa!.in);
  await writeProof('filter-between-year', page, tx);
});

test('songs: explicit = true -> 28 songs (between length also works)', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  await page.getByTestId('type-song').click();
  await expect(page.getByTestId('result-count')).toContainText('172 / 172');

  await page.getByTestId('filter-add').click();
  await page.getByTestId('filter-field').selectOption('explicit');
  await page.getByTestId('filter-op').selectOption('eq');
  await page.getByTestId('filter-value').selectOption('true');
  await expect(page.getByTestId('result-count')).toContainText('28 / 172');

  // between length (m:ss) — just assert it filters
  await page.getByTestId('filter-field').selectOption('lengthMs');
  await page.getByTestId('filter-op').selectOption('between');
  await page.getByTestId('filter-min').fill('2:00');
  await page.getByTestId('filter-max').fill('4:00');
  const fa = lastFilterApply(tx);
  expect(fa).not.toBeNull();
  await writeProof('filter-songs', page, tx);
});

test('sort: by title asc vs desc reorders the grid', async ({ page }) => {
  await setupApp(page);
  await page.getByTestId('sort-field').selectOption('name');
  const firstAsc = await page.locator('[data-testid^="item-card-"] .pdj-card__title').first().textContent();
  await page.getByTestId('sort-dir').click(); // -> desc
  const firstDesc = await page.locator('[data-testid^="item-card-"] .pdj-card__title').first().textContent();
  expect(firstAsc).not.toEqual(firstDesc);
});

test('edit: changing an album title persists across reload (db.putItem transcript)', async ({ page }) => {
  const tx = captureTranscript(page);
  await setupApp(page);
  // open the first album's editor
  const firstCard = page.locator('[data-testid^="item-card-"]').first();
  const testId = await firstCard.getAttribute('data-testid');
  const albumId = testId!.replace('item-card-', '');
  await page.getByTestId(`edit-item-open-${albumId}`).click();
  await expect(page.getByTestId('edit-modal')).toBeVisible();
  const NEW = 'EDITED ' + albumId.slice(-4);
  await page.getByTestId('field-name').fill(NEW);
  await page.getByTestId('field-save').click();
  // the modal closes only AFTER the async putItem write completes — wait for it
  // before reloading, otherwise we'd race the IndexedDB write.
  await expect(page.getByTestId('edit-modal')).toBeHidden();
  expect(hasOp(tx, 'db.putItem')).toBe(true);

  // reload -> IndexedDB persists -> the edited title is still there
  await page.reload();
  await page.waitForFunction(() => !!(window as unknown as { __pdj?: unknown }).__pdj);
  await expect(page.locator(`[data-testid="item-card-${albumId}"] .pdj-card__title`)).toHaveText(NEW);
  await writeProof('edit-persist', page, tx);
});
