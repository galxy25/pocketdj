# PocketDJ — Product Storybook

**PocketDJ** is an offline-first PWA that "puts a DJ in your pocket": it turns a
personal music collection (here, a digitized **vinyl** crate of 1,361 albums /
12,525 songs) into something you can *explore* and *perform from* on a phone —
even with no signal. Every album and song is enriched with metadata, mood
keywords, and **audio analysis** (BPM, musical key, and Camelot-wheel code), and
all cover art is cached locally so the app is fully usable offline and durable
across restarts. And on the native iPhone / iPad / Mac app it goes beyond *browsing*
to *mixing*: a two-deck **Mix** engine — live tempo, pitch, an effects grid,
crossfader and beat-sync — plus **stems**, which split any track into vocals / drums /
bass / other so you can mute, solo and remix live (**Part IV**). Both run on the same
burned, offline files, so a full mix works with no signal.

**The user story.** *As a DJ / crate-digger, I want to browse my whole collection
on my phone — by genre, by tempo, or by harmonic key — find the right record
fast, see each track's BPM/key so I can beat- and key-match, drill into a single
album, and fix up any wrong metadata, all without a network connection.* PocketDJ
serves that story with two complementary lenses on the same data: a visual,
**spatial "star map"** for discovery and a precise, **filterable browser** for
look-up — joined by a per-album **solar-system** view and **single-album** track
table for the close-up work.

The screens below follow a natural journey: **discover** (star map → solar
system), **look up** (browser → single album), then **maintain** (edit modals,
settings). All shots are from the real local app at mobile width (402×874) unless
labeled *desktop*.

---

## 1. Star map — genre mode (mobile grid)

![Star map, genre grid](storybook/01-starmap-genre-mobile.png)

The landing screen. On a phone the star map renders as a vertically-scrolling
**2-column grid of constellation cards** (the pan/zoom SVG night-sky is illegible
on a phone, so the grid replaces it). Each genre card is a big **TITLE**, an
album **count**, and a **4×4 mosaic of ~16 randomly-sampled covers** from that
genre, so you recognize the constellation at a glance.

**Affordances**
- **Genre / BPM / Key** segmented toggle (top right) — switches how the whole
  collection is grouped. Genre is selected here.
- **⚙ gear** (far top right) — opens the Settings popout.
- **✦ Star Map / ☰ Browser** pills (top bar) — switch between the two main views.
- **A constellation card** — tap to *drill into* that genre's sub-genres (see §2).
- The grid free-scrolls to the rest of the genres below the fold.

**User story:** this is the **discovery** entry point — "show me my crate, grouped
the way a DJ thinks about it." Genre is the default mental model; the cover mosaic
makes each pile instantly recognizable.

---

## 2. Star map — drilled into a genre (sub-genres)

![Genre drilled into sub-genres](storybook/02-starmap-genre-drilled-mobile.png)

Tapping a genre card drills in. The mode toggle **hides**, a breadcrumb
(**"OTHER · SUB-GENRES"**) appears, and a **"← All genres"** back button takes you
up a level. Inside the focused genre, albums are drawn as **clickable stars** in a
constellation scatter (each art-backed star shows a small cover and its album-name
caption); tapping a star opens that album's **solar system** (§4).

**Affordances**
- **← All genres** — return to the genre grid (§1).
- **A star** — open `/map/:albumId`, the album's solar system.

**User story:** narrows discovery from "a genre" down to "the actual records in
it," keeping the spatial, browse-by-feel experience while getting you one tap from
any single album.

---

## 3. Star map — BPM mode

![Star map, BPM grid](storybook/03-starmap-bpm-mobile.png)

The same collection, regrouped by **tempo**. Each card is a **BPM range** (30–40,
40–50, 50–60, 60–70 …) marked with a **metronome glyph** and the number of songs
in that band.

**Affordances**
- **BPM** is selected in the mode toggle.
- **A BPM card** — opens the browser pre-filtered to songs in that tempo band.

**User story:** direct support for **beat-matching** — "what have I got around 120
BPM?" is the core question when building a set, and this is the one-tap answer.

---

## 4. Star map — Key mode (Camelot colors)

![Star map, key grid](storybook/04-starmap-key-mobile.png)

Regrouped by **musical key**, with each card **tinted by the Camelot color** of its
key. The 12 wheel numbers map to 12 hues around the color circle; **B (major)**
reads brighter, **A (minor)** deeper — so 1A/1B are red, 2A/2B amber, and so on
around the wheel. An **"Unknown"** card (songs with no analyzed key) stays a
neutral grey.

**Affordances**
- **Key** is selected; a **Camelot / Musical** sub-toggle switches the key
  *notation* shown on the cards (Camelot codes like `8A` vs. musical names like
  `A minor`).
- **A key card** — opens the browser pre-filtered to songs in that key.

**User story:** **harmonic mixing** — the Camelot wheel is exactly the tool DJs use
to pick key-compatible tracks, and coloring the cards by it makes adjacent
(mixable) keys visually obvious.

---

## 5. Settings popout

![Settings modal](storybook/05-settings-modal-mobile.png)

Opened from the **⚙ gear**. Shows the catalog size (albums · songs) and the active
source, plus a single maintenance action.

**Affordances**
- **↻ Force refresh & re-pull catalog** — clears this device's cached app shell +
  data and re-pulls the latest catalog from the server (the fix for "I'm seeing
  old data or a stale layout"). The button shows "Refreshing…" while it works.

**User story:** the offline cache is a feature, but occasionally you *want* the
newest catalog — this is the escape hatch that re-syncs without reinstalling.

---

## 6. Solar system view (`/map/:id`)

![Solar system](storybook/06-solar-system-mobile.png)

A single album rendered as a **solar system**: the **album cover is the sun** at the
center and each **song is a planet** orbiting it. Planet *size* scales with track
length; planet *color* flags content (explicit tracks read red, tracks with mood
keywords use the secondary accent). Each planet is captioned with its song name.

**Affordances**
- **← Back** — return to the star map (or wherever you came from).
- **☰ Browser** — jump to this album's single-album track table (§8).
- **Tap the sun (cover)** — open the album **audio-tracks popup** (§7).
- **Tap a planet** — open that song's read-only detail card (like §9).

**User story:** a playful, at-a-glance close-up of one record — see its shape (how
many tracks, how long, how spicy) before committing, and pivot straight into the
precise views.

---

## 7. Solar system — audio-tracks popup

![Audio tracks popup](storybook/07-solar-audio-popup-mobile.png)

Tapping the sun opens **"<album> — Audio"**: the album's **independent audio
segmentation** in a table of **# · Start–End · BPM · Key** (each key shown with its
Camelot tag, e.g. `7A`). The caption notes that this segmentation is detected from
the recording and *may differ from the metadata tracklist*, with the total
analyzed runtime.

**User story:** the ground-truth tempo/key data a DJ actually mixes on, surfaced
right where you're looking at the record. (The same table appears, editable, in §8
and §15.)

---

## 8. Single-album view (`/album/:id`)

![Album track table](storybook/12-album-tracktable-mobile.png)

The precise per-album work surface: a **header** (cover, title, artist,
year · genre · track count) over a **track table**. Each row shows the track number,
title, **BPM**, **key**, and **Camelot** tag, plus a "plug in" affordance for the
physical/file pointer. A **"ALBUM AUDIO ANALYSIS"** footer repeats the
audio-segmentation table from §7.

**Affordances**
- **← Back** — returns to the browser **with your filters/sort preserved**.
- **◎ Solar** — open this album's solar system (§6).
- **A track row** — open that song's detail card (§9).
- **✎ Edit album info** — open the album editor (§14).
- **✎ Edit audio analysis** (in the footer) — open the audio editor (§15).

**User story:** the "I've found the record, now show me everything about it"
view — every track's mixable data in one scannable table, with edit hooks for
fixing anything wrong.

---

## 9. Song detail modal

![Song detail modal](storybook/13-song-detail-modal-mobile.png)

Tapping a track row (here, or a planet in §6) opens a **read-only** song card:
track #, artist, album, year, length, explicit flag, **BPM / Key / Camelot**
(or "— pending audio" when not yet analyzed), sentiment keyword tags, the physical
"plug in" pointer, and lyrics when found.

**Affordances**
- **✕ / Close** — dismiss (Escape or backdrop-tap also close).

**User story:** the full single-track read-out for when you need every detail of
one song without leaving the album.

---

## 10. Browser — albums (mobile)

![Browser albums, mobile](storybook/08-browser-albums-mobile.png)

The look-up lens. A **responsive grid of album cards** (cover, title, artist,
year · genre · track count). Cards lazy-load their cached covers. Tapping a card
opens the single-album view (§8); each card has a **✎** edit shortcut.

**Affordances** (toolbar, fuller view in §12)
- **Source** selector, **Albums / Songs** type toggle, **Sort**, result count, and
  the import/export bar.
- **⚙** settings, **✦ Star Map / ☰ Browser** view switch (top bar).

**User story:** "I know roughly what I want — let me filter and sort to it,"
complementary to the spatial star map.

---

## 11. Browser — songs (mobile)

![Browser songs, mobile](storybook/09-browser-songs-mobile.png)

Flipping the type toggle to **Songs** swaps the album grid for a **dense song
list**. Each row is track # · title · **BPM** · **key** · **Camelot** tag · "plug
in" · **✎**. The result count (here `12525 / 12525`) updates as you filter.

**Affordances**
- **Albums / Songs** toggle (Songs active).
- A **row** opens the song detail card (§9); **✎** opens the song editor (§16).

**User story:** the track-level look-up — scan, filter, and sort 12k songs by the
exact fields that matter for mixing.

---

## 12. Browser — filter & sort (desktop)

![Browser filter, desktop](storybook/11-browser-filter-desktop.png)

The full toolbar, shown at desktop width. The **filter builder** composes
AND-clauses of *field · operator · value* (e.g. *Genre is Disco*, *BPM between
120–128*); operators include is / is-not / in-list / between, with field-aware
value editors. **Sort** picks a field + direction (↑/↓). The **import/export bar**
loads demo data, imports a `.json`/`.zip`, or exports the whole catalog as a `.zip`
for portability.

**Affordances**
- **+ Filter** — add a clause; **Clear** removes all; each row has **✕** to remove.
- **Sort** field dropdown + **↑/↓** direction.
- **Load demo data / Import… / Export**.

**User story:** the power-user query surface — express the exact crate slice you
want and carry your library between devices.

> **Interchange formats — `.pocketdj.zip` & friends.** *Import…* accepts any of the
> PocketDJ zip kinds and routes on the manifest: a **full backup** (`.pocketdj.zip` —
> catalog + collections + your metadata edits), a single **playlist**
> (`.playlist.pocketdj.zip`), or a single **pocket** (`.pocket.pocketdj.zip`). These
> are the *same* files the native iPhone/iPad/Mac apps read and write, so a backup made
> on your phone imports straight into the browser (and vice-versa). A native backup
> omits the catalog (both apps re-seed the same index) but carries an `edits.json` of
> your corrections; importing it **merges those edits** into the PWA — so a BPM/key/name
> fix made on the phone shows up in the browser. User-authored data (pockets, playlists,
> set lists, edits) round-trips losslessly both ways; the bundled catalog stays a
> browser↔browser concern. *Export* writes a portable backup that any client can read.

---

## 13. Browser — albums (desktop)

![Browser albums, desktop](storybook/10-browser-albums-desktop.png)

The same album browser at desktop width: a wider multi-column grid showing many
covers at once, for fast visual scanning on a laptop.

---

## 14. Edit album modal

![Edit album modal](storybook/14-edit-album-modal-mobile.png)

Opened from **✎ Edit album info** (§8) or a card's **✎**. Edits the album's
metadata: **Artist, Title, Year**, a **Genre** combo (suggests the canonical
category names *and* accepts free text), a **Cover URL** field (paste a new cover
to re-fetch), **Country**, and **File type**.

**Affordances**
- **Cancel** / **Save** (Save persists to the local IndexedDB catalog).

**User story:** fix wrong enrichment in place — bad genre, missing year, or a
broken cover — without re-running the indexer.

---

## 15. Edit audio-analysis modal

![Edit audio modal](storybook/15-edit-audio-modal-mobile.png)

Opened from **✎ Edit audio analysis** in the album footer (§8). One editable row
per detected audio segment: **Start / End** (m:ss), **BPM**, **Key**, and
**Camelot**. The **Key** and **Camelot** dropdowns are linked — picking one fills
the other from the Camelot↔key mapping — so the pair always stays consistent.

**Affordances**
- **Cancel** / **Save**.

**User story:** correct the auto-detected tempo/key when the analyzer got a track
wrong — critical, because the whole BPM/Key discovery flow trusts these numbers.

---

## 16. Edit song modal

![Edit song modal](storybook/16-edit-song-modal-mobile.png)

The song editor (opened from a song row's **✎**). Edits **Artist, Title, Track #,
Year, Length, Explicit**, **sentiment keywords**, and the audio fields — with
**Key** and **Camelot** as **valid-value dropdowns** (the 24 musical keys / 24
Camelot codes, kept in sync). It also exposes a destructive **Delete track**
action (§17).

**Affordances**
- **Cancel** / **Save**, and **Delete track** (red).

**User story:** per-song corrections — fix a mistagged key, mark a track explicit,
or remove a track that doesn't belong.

---

## 17. Delete-track confirm

![Delete track confirm](storybook/17-delete-track-confirm-mobile.png)

**Delete track** swaps the editor for a mobile-friendly confirm: *"Delete '<song>'
from the index? This can't be undone."* with a safe **Nope** and a red **Delete**.

**Affordances**
- **Nope** — back out (no change).
- **Delete** — remove the track from the local catalog.

**User story:** a deliberate two-step guard so a destructive edit can't happen by a
stray tap — important on a touch screen.

---

# Part II — Pockets, Playlists & Setlists (perform from the crate)

The screens above are about *exploring and maintaining* the collection. This part
is about **performing from it**. Three nouns:

- A **Pocket** is a reusable, harmonically-coherent grouping of songs/albums (and
  it can nest other pockets — a DAG). Think "Classic Soul Anthems."
- A **Playlist** is a **template**: an ordered set of **Sequences** ("chapters"),
  where each sequence holds songs, albums, or pocket references and can carry a
  **time budget**.
- A **Setlist** is a **frozen instance** produced by hitting **▶ Play**: PocketDJ
  *realizes* the template into a concrete, ordered track list — expanding albums,
  **sampling** over-budget pockets to fit the slot, and **autofilling** temporal
  gaps with harmonic bridge tracks — then persists it so you can hand it to the DJ:
  *"spin these tracks, in this order."*

The top bar also changes here: Star Map and Browser are merged into one
**Collection** mode (with a remembered **Map / List** sub-toggle), sitting beside
the new **Pockets** and **Playlists** modes. On a phone the brand stacks above the
mode tabs so nothing competes for width (visible in every shot below).

---

## 18. Pockets — list

![Pockets list](storybook/18-pockets-list-mobile.png)

The Pockets mode landing screen: a **New pocket** creator and a list of existing
pockets, each a card with a **kind badge** (`HARMONIC`), the name, and member
counts (*songs · albums · child pockets*).

**Affordances**
- **New pocket name… + Create** — make a pocket, then jump into it.
- **A pocket card** — open its detail (§19).
- The new **bag** icon marks the Pockets tab; the **▶ play** icon marks Playlists.

**User story:** "keep a few reusable crates of records that mix well together, so I
can drop a whole vibe into any set."

---

## 19. Pocket — detail

![Pocket detail](storybook/19-pocket-detail-mobile.png)

Inside a pocket: an editable **name**, an **⤓ Export**, a **Delete**, and the
**Members** list. **Export** writes a portable `.pocket.pocketdj.zip` (the pocket plus
any nested child pockets, DAG-expanded) that any client — browser or the native apps —
can import; ids are reminted on import so it never clobbers an existing pocket. Each
song is a **two-line row** — title + artist on top, then its **BPM** and
**Camelot key** badges (e.g. `57 BPM · 9A`) so the harmonic coherence of the pocket
is visible at a glance. A **Child pockets** section nests other pockets (cycle-
guarded). Tapping a song opens the same **song detail** popover used everywhere
else (§24).

**Affordances**
- **⤓ Export** — download the pocket (with its nested pockets) as a `.pocket.pocketdj.zip`.
- **Tap a song** — open its detail popover.
- **Remove** — drop a member.
- **Add child pocket** — nest another pocket (rejected if it would create a cycle).
- Members are added from anywhere via **＋ Add to…** (§20).

**User story:** curate the crate and *see the key/tempo spread* while you do it — a
pocket is only as good as how well its records mix.

---

## 20. Add to a pocket or playlist

![Add-to-collection picker](storybook/20-add-to-collection-picker-mobile.png)

The shared **＋ Add to…** picker, reachable from any song or album — the browser
song detail, the album view, and the solar-system popovers. It lists your
**Playlists** (with a sequence count) and **Pockets**, plus **＋ New playlist /
＋ New pocket** to create-and-add in one step. (Here it's layered over a song's
detail card — note *Lyrics — Not found* behind it, the lazy lyrics loader behaving
correctly when none exist.)

**Affordances**
- **A playlist row** — add the item (to a chosen sequence if it has more than one).
- **A pocket row** — add the item to that pocket.
- **＋ New playlist / ＋ New pocket** — create and add in one action.

**User story:** wherever you find a record, you're one tap from filing it into a set
or a crate.

---

## 21. Playlists — list

![Playlists list](storybook/21-playlists-list-mobile.png)

The Playlists mode landing: a **New playlist** creator and the list of playlist
**templates**, each showing its sequence and item counts.

**Affordances**
- **New playlist name… + Create** — start a template and open it.
- **A playlist card** — open its detail/editor (§22).

**User story:** "keep the sets I perform — Family BBQ, Sunday Brunch — as living
templates I can re-roll any time."

---

## 22. Playlist — the template (sequences)

![Playlist detail / template](storybook/22-playlist-detail-mobile.png)

The template editor. The header has the editable **name**, the primary **▶ Play**
button, and **Delete**. Below are the **Sequences** (chapters): here *Warm-up
(pocket)* carries a **10:00 target** and holds the **Soul Anthems** pocket (10
items); *Closers (songs)* holds two hand-picked songs. Each item can be **moved**
between sequences or **removed**, and **＋ Add sequence** adds a chapter. At the
bottom, **Set lists** is the history of everything you've generated from this
template.

**Affordances**
- **▶ Play** — realize the template into a new Setlist (§23) and open it.
- **target (m:ss)** — give a sequence a time budget; pockets sample to fit it.
- **Move to / Remove / ＋ Add pocket / ＋ Add sequence** — shape the chapters.
- **A set list row** — open a previously generated performance.

**User story:** compose the *shape* of the night — a warm-up pulled from a pocket,
a fixed pair of closers — without nailing down the exact tracks yet.

---

## 23. Setlist — a generated performance (the ▶ Play payoff)

![Setlist](storybook/23-setlist-take2-mobile.png)

Hitting **▶ Play** freezes a **Setlist**: *"Family BBQ — take 2 · 18:08 total."*
Tracks are grouped under **section headers that map to the playlist's sequences**.
The *Warm-up (pocket)* section came in at **9:50 — under its 10:00 budget**: from a
44-minute, 10-song pocket the engine **sampled** a coherent subset and **autofilled
harmonic bridges** (the `↔ bridge` tracks, key-matched at `10B`) to smooth the
transitions; the *Closers* are the `explicit` hand-picks. Every row shows **BPM +
Camelot key**, a **provenance badge** (`pocket` / `↔ bridge` / `explicit`), and a
dormant **Mix suggestions** seam (coming soon). **Play again → a different take**
(the pocket samples fresh each time).

**Affordances**
- **⤓ Save CSV** — export the set via the native OS file picker (name + location).
  Columns: `#, Artist, Title, BPM, Key, Length, Source, Sequence, Song ID` — the
  **Song ID** lets a downstream process resolve each track's audio segment in O(1).
- **Delete** — discard this take.
- **Tap a track** — open its song detail (§24).

**User story:** the mission payoff — a real, saved set list you can read off ("spin
these, in this order"), export, or regenerate for a different feel.

---

## 24. Setlist — tap a track for song detail

![Setlist song detail](storybook/24-setlist-song-detail-mobile.png)

Tapping any setlist track (or pocket member, or browser row) opens the shared
read-only **song detail** popover — track #, artist, album, genre, year, length,
explicit flag, **BPM / Key / Camelot**, sentiment tags, the analog **plug-in**
pointer, and lyrics — closed by a **mobile-friendly ✕** in the top-right.

**Affordances**
- **✕ (top-right) / Close / Escape / backdrop** — dismiss.
- **＋ Add to…** — file this track into a pocket or playlist (§20).

**User story:** one consistent detail card everywhere, so you can always check a
track's key/tempo before you commit it to a mix.

---

## 25. Collection — Map / List (the merged top-level mode)

![Collection Map/List toggle](storybook/25-collection-map-list-toggle-mobile.png)

Star Map and Browser are now one **Collection** mode. A contextual **✦ Map / ☰
List** sub-toggle (under the main tabs) flips between the spatial star map and the
filterable list, and **remembers your choice** — clicking **Collection** later, or
relaunching the app, lands you back on the view you last used.

**Affordances**
- **⊞ Collection** — go to your remembered sub-view.
- **✦ Map / ☰ List** — switch sub-view (persisted).
- **🛍 Pockets / ▶ Playlists / ⚙** — the other modes + settings.

**User story:** "discovery and look-up are two takes on the same crate — keep them
together under one roof, and remember how I like to look at it."

---

## 26. Playlists & performance — 2026 update (what's new)

The playlist/pocket/setlist surfaces got a big pass. The shots in §5, §9, §11, §20,
§21, §22 and §23 above were **re-captured** for this update; the capabilities are
summarized here.

### Playlist template — enriched, reorderable items

![Playlist detail, enriched](storybook/22-playlist-detail-mobile.png)

Each item row now carries its **album cover art** and **BPM / Camelot** badges, and
the header shows a **song count + total runtime** both **per chapter** and for the
**whole playlist**. Every item has:

- **▲ / ▼ reorder** — move it up/down within its chapter (mobile-friendly tap
  targets; disabled at the ends). The **→ chapter** dropdown still moves it *between*
  chapters.
- **＋ note** — an inline **performer note** (e.g. *"open cold — let it breathe"*).
- Tapping the **name** opens the full **song metadata** modal.

You can also drop a **free-text cue** that isn't a catalog item — *"sample of This
Land Is Mine Land"* — straight into a chapter (the **CUE** row). And **⤓ Export**
saves the playlist to a portable file (see below).

### Setlist — editable, with notes & cues

![Setlist with notes + cue](storybook/23-setlist-take2-mobile.png)

The realized set list (▶ Play) now has an **editable name**, **per-track performer
notes**, and renders any **free-text cues** as no-audio rows. The **Save CSV** export
gains a **Note** column, so your cues + notes travel to whatever you spin from.

### Song metadata — cover art + jump to the album

![Song detail with cover art + album link](storybook/13-song-detail-modal-mobile.png)

The shared song-detail card (used everywhere a song is tapped — browser, album
table, playlist, set list — **except** the solar view, which *is* the album art)
now shows the **album cover** and an **Album → ↗** link that opens the album view in
a new tab.

### "Add to…" remembers your last choice

![Add-to picker, last used](storybook/20-add-to-collection-picker-mobile.png)

The Add-to picker surfaces your **last-used** playlist/pocket first (with a *last
used* badge) and defaults the sequence to the one you last added into — fewer taps
when you're building a set fast.

### Song list — hide songs you've already placed

![Browser songs, exclude dropdown](storybook/09-browser-songs-mobile.png)

A **"Hide added"** multi-select dropdown filters the song list. Hide songs already
in **any playlist/pocket** (show only *unplaced* songs), or scope to a **checked
subset** of collections. A checkbox dropdown (not chips) so it scales to many
playlists/pockets and stays mobile-friendly. Full data **Import/Export moved to
Settings**, so the browser toolbar no longer duplicates it.

### Settings — backup/restore, safe refresh, migrations

![Settings: backup, refresh, migrations, reset](storybook/05-settings-modal-mobile.png)

- **⤓ Export all data / ⤒ Import data** — back up *everything* (catalog, art,
  pockets, playlists, set lists) to one file and restore it on another device or a
  fresh/offline install. Side by side.
- **↻ Force refresh** now **preserves your pockets, playlists & set lists** — it
  re-pulls only the catalog, so updating the app no longer wipes client-side work.
- **Data version + ⬆ Run migrations** — a versioned, non-destructive migration
  framework (baseline **v0**) that keeps collections compatible across app updates.
- **⚠ Reset everything** — a separate, clearly-labeled nuclear wipe (collections
  included), behind a confirm.

### Export / import a single playlist

A playlist exports to a tiny **`.playlist.pocketdj.zip`** that **references the
catalog by id** (the app re-seeds the same index), so it's ~4 KB instead of bundling
hundreds of KB of catalog + art — yet imports with every song resolved. A
`portable` mode still bundles everything for a device with a different/empty catalog.
Import lands it as *"… (imported)"* without clobbering existing playlists.

---

## 27. Multi-source, collection filters & online search — 2026 update

PocketDJ is no longer vinyl-only: it indexes **multiple data sources** into one
catalog, adds a **show/hide** pair of collection filters to the song list, and gains
an optional **online search** mode backed by OpenSearch. The browser shots in
§8–§11 now show two sources.

### A second source — Apple Music (Local)

![Multi-source selector](storybook/27-multi-source-selector-mobile.png)

Alongside the digitized vinyl crate, the app can index your **Apple Music library**
(from the macOS `Library.xml`) as a second, **digital** source — here **12,220
albums / 92,865 songs** next to vinyl's **1,361 / 12,525**. The **Sources** picker is
a multi-select: show **all**, **none**, or a **subset** (e.g. just vinyl, or just
Apple Music). Digital albums carry real genre/year/track metadata but no cover art
(the ♪ tile) — art is added only via a rip/burn. The selection **persists**, and the
star map, counts and browser all respect it. Items are kept distinct per source, so
the same album owned on vinyl *and* in Apple Music never collide.

### Settings ▸ Sources — load / remove sources

![Settings: Sources panel + Online search](storybook/28-settings-sources-mobile.png)

Apple Music is **opt-in**: a fresh device boots vinyl-only (fast), and you add the
library with **＋ Load Apple Music (Local)** in Settings ▸ Sources. The same
multi-select lives here too, plus a per-source **✕ remove** (which also drops that
source's imported playlists). Importing the library also **mirrors your iTunes
playlists** into app playlists. (This shot also shows the **Online search** panel —
see below.)

The mirrors now track your Music library **faithfully overnight**: a playlist you
create or rework in Music shows up (or updates) in the catalog the next morning even
if you'd been mid-edit at sync time — a playlist that's momentarily **empty stays
listed as empty instead of disappearing** — and albums you add stream-ready the same
night. Music **videos** in your library no longer sneak in as bogus "songs".

### Show *and* hide — collection filters on the song list

![Show / hide collection filters](storybook/29-show-hide-filters-mobile.png)

The song list now has a **pair** of membership filters. **Hide added** (from §26)
drops songs already placed; the new **Show added** keeps **only** songs that *are* in
a chosen playlist/pocket (or *any*). Both can be on at once — the browser
**intersects** them (e.g. "everything in *Peak Hour* that isn't already in *Saturday
Set*"). The dropdowns list your playlists + pockets, including the **imported iTunes**
ones.

### Online search (OpenSearch) — opt-in ⚡

![Online search via OpenSearch](storybook/30-online-search-mobile.png)

A search box spans the catalog. **Offline** (the default) it filters the loaded set
by title/artist locally. Once you paste a **read-only search key/secret** into
**Settings ▸ Online search** (§28), an **⚡ Online** toggle appears: it queries
**OpenSearch Serverless** across **title, artist, album, lyrics and sentiment** over
the *entire* indexed catalog — here **80 of 470** matches for *"midnight"* in
**389 ms**, with explicit (**E**) and BPM/key badges intact. The browser signs each
request itself (SigV4) and reaches the collection same-origin via a CloudFront proxy,
so there's no separate server to run. The backing collection is now **NextGen
scale-to-zero** — it costs **$0 while idle** and only adds a one-time **~15 s warm-up**
on the first search after a long pause. Settings ▸ Online search also shows the current
**search host** with an **editable override**, so the search backend can be moved (or
made private per-user) without shipping a new app.

---

## 28. Stream & download — rip on demand (2026 update)

The offline-first crate is now **playable end to end**. Any song or album can be
**streamed or downloaded** from a ▶/⤓ button: on a cache miss the app asks the iMac
(over Tailscale) to **rip** the track — analog from a local recording, Apple Music in
real time via Audio Hijack — upload an **mp3** to a public S3 cache, then stream it
back. Rip once → instant forever (and playable anywhere, since the cache is just S3).

### ▶ / ⤓ on every song & album + a mini player

![Rip buttons + mini player](storybook/32-mini-player-mobile.png)

Each song row and album card gets **▶ Play** and **⤓ Download**. Tap ▶ and — if it
isn't already ripped — the button shows the live phase **Searching… → Ripping mm:ss →
Uploading…** (polled from the rip server), then a **mini player** docks at the bottom
with **⏮/⏭** and **auto-seek** to the track inside a whole-album rip. Already-ripped
songs play instantly.

**Audio analysis + waveform scrub.** Every ripped song is analyzed in the background:
**BPM, musical key & Camelot** are computed (librosa) and **rolled into the default
index** — so they're filterable, sortable, on the star map, and in song detail, just
like the rest of the catalog (existing audio-stage values are kept; only gaps are
filled). A **waveform** image is generated (ffmpeg) and uploaded alongside the rip;
the player lazy-loads it (like cover art / lyrics) and renders it as a **clickable
scrub bar** — click anywhere on the waveform to seek. The same analysis runs on songs
ripped via the **`rip` skill** (a setlist's `_ripped/` folder) through the batch tool.

### Play while it rips — live streaming

Tapping ▶ on an un-ripped Apple Music song now **plays within a few seconds and
follows the real-time capture**, instead of waiting the full capture + upload. As
Audio Hijack records, the server segments the growing audio into a **live HLS** stream
(`tail | ffmpeg`, 2 s AAC segments + a rolling playlist) and serves it over Tailscale;
the player shows a red **● LIVE** chip. HLS is used because iOS Safari plays it
natively (a plain progressive stream is silent on iOS); desktop browsers without
native HLS use a lazy-loaded `hls.js`. When the rip finishes it uploads the durable
mp3 to S3 as before, so every later play is the **seekable** cached file (with the
waveform). Analog stays rip-then-play (already faster than real time).

The app and rip server do a small **version handshake** (`/health`): if the server is
reachable but **outdated** (e.g. its process predates a code update), the app shows a
transient banner — *"Rip server is outdated — restart it for live streaming"* — that
auto-dismisses after 5 s, instead of silently failing to stream.

### Settings ▸ Rip server

![Settings: rip server](storybook/33-settings-rip-server-mobile.png)

Point the app at the **iMac running the rip server** — its Tailscale HTTPS URL
(`https://…ts.net`) from your phone, or `http://localhost:8787` on the same machine —
and **Test connection**. The rips live in a public S3 cache (deterministic
`rips/<id>.mp3`), so the server is only needed to *create* a rip; once ripped, a song
plays from anywhere even with the server off.

### Setlist ▸ Rip all · Play all · Burn

![Setlist rip actions](storybook/34-setlist-actions-mobile.png)

A realized set list gains three actions: **⬇ Rip all** (rip every track so playback is
instant), **▶ Play all** (play the set start→finish, **ripping ahead** so the next
track is ready before the current ends, auto-advancing the mini player), and **🔥 Burn**
(rip any that aren't yet, then download the whole set as one **zip**). Progress shows
as *Ripping / Burning N/M*.

---

# Part III — The native app: play, identify & stream (2026 update)

Everything above is the cross-client product. This part is what the **native
iPhone / iPad / Mac app** (under `apple/`) adds on top of the same crate: an
**inline player** that plays and downloads right inside the list, a **"?♪?"** button
that *listens* and identifies the song in the room, a Settings section to **link an
Apple Music subscription** beside your own catalog,
and full **keyboard navigation** for the desktop. The shots/copy below describe the
native surfaces; they read the *same* catalog, rips cache, and collections as the PWA.

**The app icon.** The Home Screen / Dock / Finder icon is the **stick-figure DJ in a
denim pocket** — headphones on, hands on a two-deck controller — as clean dark line
art on a solid **PDX-carpet turquoise** field (`#00A99D`, a nod to the classic
Portland airport carpet). One full-bleed source renders every iOS, iPadOS and macOS
size; the three smallest macOS sizes (16/32/64 px) use a stroke-emboldened cut of the
same line art so the silhouette stays legible at menu-bar scale.

> The Apple Music streaming source ships **inert** until provisioned: the app runs
> with it unconfigured, where the account row reads **"Not available."** Wire it on per
> the setup guide [`streaming-integration.md`](./streaming-integration.md). (Earlier
> Spotify + YouTube provider scaffolding was removed.)

---

## 29. The inline player — play, stream, download, scrub

Every song row in the native app — in the Browser **and** in an album's track table —
has a **▶ play** and **⤓ download** button on the right (the `RowTransport`). They're
the same rip-on-demand transport the PWA mini-player uses, but the player itself docks
**inline, directly below the row you played**.

**Play.** Tap **▶**. **Apple Music (Local) songs now stream straight from Apple
Music** — when the app can find the track in the Apple Music catalog (and you've
linked Apple Music in Settings, §31), tapping ▶ plays it instantly from your
subscription via MusicKit, no ripping involved (the player shows a *"via Apple
Music"* backend). Only when there's no catalog match (an obscure pressing, a
region-gated or removed track) does it **degrade to ripping** — so a song *always*
plays, but the common case is now an immediate Apple Music stream instead of a
multi-minute capture. If the song is already ripped it plays instantly from the cache;
otherwise the button shows the live rip phase — **Queued… → Searching… → Ripping mm:ss →
● Streaming live → Uploading…** (polled from the rip server) — and, for an un-ripped
track that fell back to ripping, begins playing the **live HLS** stream within seconds
while the capture continues (a red **● live** chip). When the row is the one playing,
**▶ flips to a pause/resume toggle** for that same player instead of re-resolving.

**The slide-out panel.** Below the playing row a panel appears with:
- a **play/pause** button, the **title · artist**, a **chevron** to collapse/expand,
  and an **✕** to close (stop + dismiss),
- a full-width **waveform** image (lazy-loaded, like cover art) sitting **edge-to-edge**
  above a full-width **scrubber** — drag the slider to seek; elapsed / duration labels
  flank its two ends,
- for a live stream, instead of a scrubber: a *"Streaming live as it rips"* state (a
  live HLS stream has no fixed length to scrub).

The position updates ~4×/s smoothly without the buttons ever going "dead" — a subtle
but real win the desktop build needed (the scrubber redraws on its own clock so it
never disturbs the control buttons' taps).

**Download.** Tap **⤓** to resolve the durable mp3 — ripping it on demand first if it
isn't ripped yet (the button shows the same live rip phase: *Searching… / Ripping
mm:ss / Uploading…*) — then a native **save-location picker** opens so you choose
*where* the file lands (the **NSSavePanel** on macOS, the document picker in export
mode on iOS/iPadOS), pre-filled with an `Artist - Title.mp3` name. The OS writes the
mp3 to the spot you pick; cancel or an error just resets the button.

**Lock screen & Control Center.** Native playback registers with the OS, so the
current track shows on the **lock screen / Control Center** — **with its album cover**
when the track's album is in the catalog — and working play / pause / scrub (AirPods
and CarPlay drive it too); audio keeps playing in the background.

**User story:** "I found the record — now let me actually hear it, right here, without
leaving the list — and scrub to the drop."

---

## 30. "?♪?" — identify the song that's playing

At the **top of the Browser**, centered, is a **"?♪?"** button — two question marks
flanking a music note. Tap it and the app **listens through the mic** (ShazamKit),
**identifies** the playing song, and maps it back to your crate:

- while listening it pulses with a sonar ring (note bounces; *Identifying* as it
  queries),
- a hit **in your crate** opens a *"Heard it"* sheet — **"In your crate"** with an
  **Open song** deep-link straight into that song's detail,
- a hit **not in your crate** shows the recognized title/artist/artwork as **"Not in
  your crate"**, and — when Shazam returns an Apple Music id — notes *"A linked Apple
  Music account can play this."*,
- if mic permission is **denied**, the button shakes, shows a `mic.slash`, and tapping
  it jumps to Settings.

Matching is title+artist **normalized** (so *"Café (Remastered 2011)"* still matches
*"Cafe"*). On a build without ShazamKit it simply reads *"Recognition isn't available
in this build."* — never a crash.

**User story:** "Something great is playing — what is it, and have I already got it?"
One tap answers both.

---

## 31. Settings ▸ Streaming accounts — link Apple Music

A **"Streaming accounts"** section in native Settings sits beside your URL
**Data sources**. It lists one row per provider — currently **Apple Music** — with a
status line and a **Log in / Log out** button:

- a configured provider shows **Log in**; linking hands off to that service's sign-in
  (Apple Music shows the system consent sheet), after which the row reads
  **Linked / Connected**, and **Log out** severs it,
- an **unconfigured** provider (not provisioned in this build) reads **"Not
  available"** with a developer note,
- the section footer explains: *link a streaming service to play directly from your
  subscription, beside your own catalog sources.*

A linked subscription is an **additional, account-based source** — orthogonal to the
vinyl / Apple Music (Local) URL catalogs and to rip-on-demand. It also gives the "?♪?"
recognizer a way to **play** a recognized track that isn't in your crate.

**User story:** "Beyond my own crate, let me reach into my streaming subscription —
log in once, and play from it inside the same app."

---

## 32. Keyboard navigation (desktop)

On the Mac (and an iPad keyboard), the Browser is fully **keyboard-drivable**:

- **↑ / ↓** move a **focus cursor** that highlights a row — across the **song list**
  *and* the **album grid/list** (the album grid walks album order linearly). It works
  **live during search**: type a query, then arrow into the results.
- **⌘P** plays (or pauses/resumes) the **focused song**.
- **Return** or **⌘O** **opens** the focused item — an album → its detail, a song →
  its song detail — the same destination a click reaches.

Other shortcuts round it out: **⌘1 / ⌘2** Albums / Songs, **⌘L** focus search,
**⌘V** grid/list, **⌥⌘F** Filter, **⌥⌘S** Sort.

**User story:** "On a laptop I want to fly — Spotlight-style: type, arrow down,
hit Return to open or ⌘P to play, hands never leaving the keyboard."

---

## 33. Rip & Burn a whole set — take it offline

Playing one song at a time is great in the room with signal. But a gig is a *set*, and
the venue might have no signal at all. So every collection you can perform from — a
**playlist**, a **pocket**, a **setlist**, or a whole **source** ("From your sources")
— gets two collection-level buttons in its detail screen: **Rip** and **Burn**.

**Rip = "send the whole set to be recorded."** Tap **Rip** and the app hands the entire
set to your iMac to capture — analog tracks from your vinyl recordings, Apple Music
tracks in real time — and upload each as an mp3 to the shared cache. Nothing downloads to
your phone; this is just *"make sure every track in this set exists as a rip."* Because
ripping Apple Music happens in real time and one track at a time, it **completes over
time** in the background — so the result reads like *"Ripped 8 of 10 — 2 unrippable,
enqueued, completes over time,"* with a **Refresh** to reconcile the final counts later.
Re-tapping Rip on a set that's mostly done is cheap: already-ripped and in-progress tracks
are skipped. (Rip is only offered when you've pointed the app at a rip server.)

> **You usually don't even have to ask.** Whenever you simply *play* an Apple Music track
> in the app, it quietly gets ripped in the background too (no waiting, no prompt) — so a
> set you've been playing through is often already half-ripped before you ever tap **Rip**.

**Burn = "download this set for offline."** Tap **Burn** and the app downloads every
*already-ripped* track in the set onto the device, so the whole set plays with **no
signal and no rip server**. Burn never waits on a live recording — it only pulls tracks
that are already ripped, and reports the rest as *"not yet ripped — Rip first"* (so the
natural flow is **Rip**, let it finish, then **Burn**). Alongside each downloaded track it
writes a plain-text companion with the track's **BPM, key (musical + Camelot), sentiment,
album, and full metadata** — the same kind of mixer-ready sidecar the desktop burn
produces. Burning the same set again is smart: it re-downloads only what's **missing or
stale** (e.g. a track you re-ripped, or whose BPM/key was re-analyzed since), and skips
everything still current. Progress shows as *"Burning 6 of 10,"* ending in a summary like
*"Burned 6 of 10 — 4 not yet ripped."*

**Where you'll see them.** The pair appears on the playlist detail, the pocket detail, the
setlist detail, and the read-only "From your sources" list — anywhere you've gathered a set
worth carrying. Both buttons disable when the collection has nothing rippable in it.

**⏹ Stop — cancel a rip or burn in flight.** While a Rip or Burn is running, a red **Stop**
control stays reachable. Tap it and the in-flight job halts: a **Stop rip** tells the iMac
to drop this set's still-queued and currently-recording tracks; a **Stop burn** ends the
download loop after the current file (so whatever already finished stays on the device). Either
way you get the partial summary so far — handy when you change your mind about a long set
mid-capture, or only meant to grab the first few tracks.

**Live "X of N ripped" — and a Stop that stays put.** A collection **Rip** captures every
track in real time, one at a time, so it finishes *over minutes or hours* on the iMac long
after the app has handed off the set. The app now follows that progress: a small **"ripping —
3 of 12 done"** chip ticks up as each track lands in the cache, sitting beside a persistent red
**Stop** the whole time the rip is running — not just for the split-second it takes to send the
set off. (Earlier, Stop flashed by in about a second and was effectively unusable for a long
rip.) When the last track completes, the chip resolves to **"Ripped 12 of 12"**; tap **Stop**
at any point to drop whatever's still queued or recording and keep what already finished.
Rips also **self-heal** server-side — a stuck capture or a briefly-unplugged vinyl drive no
longer freezes the queue, so a long Rip reliably grinds to completion (it just keeps going,
retrying transient hiccups) instead of stalling forever.

**User story:** "I've built the set — now make it bulletproof: rip everything so it's
captured, then burn it onto my phone so it plays in a basement with no bars, every track
carrying the BPM and key I mix on — and let me call it off if I started the wrong one."

---

## 34. Settings ▸ Rip from cloud · burnt-music folder

Two new native Settings controls refine *how* and *where* the app rips and burns.

**Rip from cloud source.** In **Settings ▸ Rip server**, below the URL, a **Rip from cloud
source** toggle changes where a rip comes from. With it **on**, any song that *exactly* matches
a track in your iMac's Apple Music library is captured from **Apple Music itself** (real-time,
one track at a time) instead of from a vinyl recording — so even a set built from the vinyl
crate can be ripped at full digital quality when the same recording lives in your library. When
there's no exact match it **falls back to the vinyl rip** automatically, so nothing is skipped.
The match is deliberately strict: a *remix*, *radio edit*, *live*, or *instrumental* version
won't masquerade as the standard recording (and vice-versa) — only the genuinely-same recording
matches, so a cloud rip never quietly swaps in the wrong version. The setting's footer warns that
because cloud rips capture in real time, one at a time, a large **Rip/Burn can take a while**.

**Burnt-music folder.** A **Burnt music folder** section lets you pick **where burned audio +
their `.txt` sidecars are saved**. By default they live in the app's private storage; tap
**Choose burnt-music folder…** and pick any folder (the system folder picker on each platform)
to have burns land somewhere **you can browse yourself** — in **Finder** on the Mac or **the
Files app** on iPhone/iPad. The chosen folder's name is shown with a **Use app storage** button
to revert. Now the mixer-ready files (audio + BPM/key/sentiment sidecar) are right where you can
drag them into a DJ app or back them up. *(This picker now lives on the **Settings ▸ Storage**
screen — the storage manager, §64 — together with the session folder and the delete tools.)*

**User story:** "Rip from my actual Apple Music library when it's the same record — and drop
the burned files in a folder I can open, not buried inside the app."

---

## 35. Setlist ▸ ▶ Play — play the whole set in order

A realized set list gains a **▶ Play** button in its toolbar (beside Rip/Burn). Tap it and the
app plays the set **start to finish, in order**, in the inline player — auto-advancing to the
next track as each one ends. For each track it prefers the **burned local file** if you've
burned the set (so it plays with no signal), otherwise it **streams** the rip; a track that
can't be played at all (no rip, no server) is **skipped** rather than stalling the set. The
button flips to **⏹ Stop** while it runs (and reorder/delete are locked so the queue can't
shift under playback). When the current track is a **live** stream — which has no natural end —
a **⏭ Next** button appears so you can advance by hand.

**User story:** "Hit one button and let the set play itself through, in order — the way I'll
actually run it on the night — pulling from what I've burned and skipping anything not ready."

---

## 36. Browse — genre & collection-membership filters, per-clause remove

The native Browser's **Filter** sheet gains the PWA's richer filtering (and a little more).

**Genre filter.** Add a **Genre** clause and pick from a multi-select of **top-level
categories** — the ~15 buckets the star map groups by (Disco, Soul, House…), not the ~600 raw
sub-genres. Two operators: **in list** (any-of — keep songs/albums in any of the picked
categories) and **not in list** (none-of — drop them). It works in both Albums and Songs mode
(a song inherits its album's category). **Genre** is also a **Sort** key, so you can order the
list by category.

**Collection-membership filters (Songs mode).** When you've got playlists or pockets, a
**Collection membership** section adds two filters: **In playlist / pocket** keeps **only** songs
that *are* in a chosen collection (or *any*), and **Not in playlist / pocket** **drops** songs
that are. Each is an *"Any playlist / pocket"* toggle plus per-collection checkboxes, with its
own **Clear**. Both can be on at once — the list shows the **intersection** (e.g. *everything
in Peak Hour that isn't already in Saturday Set*) — exactly mirroring the web app, including
your **imported iTunes** playlists.

**Per-clause remove.** Every filter clause now has its **own remove** — a **trash** button (and
a left **swipe**) on the row — alongside the existing **Clear All**. So you can drop a single
clause without tearing down the whole query.

**User story:** "Filter by the genre buckets I think in, slice by what's already in my sets,
and peel off one filter at a time instead of starting over."

---

## 37. Online search — load-more pagination & server-side sort

The native **⚡ Online** search (OpenSearch) gets two refinements over the offline filter.

**Pagination — scroll to load more.** Instead of stopping at a fixed cap, online results now
**page in as you scroll**: the first page loads on a query/filter change, and reaching the
bottom of the list **fetches and appends** the next page, until every match is loaded. The
results header shows the **real total** (e.g. *"470 songs"*) — the full match count across the
entire indexed catalog, not just the rows currently on screen — so you always know how big the
result set actually is.

**Sort applies online too.** The Browser's **Sort** (field + ↑/↓) now drives the **online**
search as well: OpenSearch sorts the *whole* result set server-side and pages come back already
in order — so sorting by BPM, key, genre, year, or title behaves the same whether you're
searching offline or online, across the entire catalog rather than just the loaded slice.

**User story:** "Search the whole library online, scroll to pull in as many matches as I want,
see the true total, and sort it the way I always do."

---

## 38. Keep going in the background — rips, burns, downloads & playback don't stop when you leave

Capturing a whole set or burning it for offline takes real time — minutes for a long Rip,
a steady download-by-download grind for a Burn. Before, leaving the app (switching to
Messages, locking the phone, letting the screen sleep) could pause or drop that work
half-finished. Now the native app keeps the long jobs **alive in the background** so you can
start something big, pocket the phone, and come back to it done.

**Rips, burns & downloads continue while the app is backgrounded or locked.** Kick off a
collection **Rip** or **Burn**, or a single-track **⤓ Download**, then switch away or lock the
device — the work keeps running. Downloads and burns hand off to the system so each file
finishes (and the next one starts) even while the app is suspended; a **Burn** that was halfway
through when you locked the phone keeps landing tracks, and you'll find the set fully burned when
you return — its **"Burning 6 of 10"** progress having carried on the whole time. Even a **cold**
relaunch (the system having fully unloaded the app mid-transfer) picks the finished files back up
rather than losing them.

**Setlist playback plays on past the lock screen.** Hit **▶ Play** on a setlist (§35), lock the
phone or switch apps, and the set keeps playing — **auto-advancing from track to track** on its
own. The currently-playing song shows on the **lock screen / Control Center** (and on AirPods,
CarPlay, or a watch) with its **album cover** and working **play / pause / next / previous** —
⏮ goes to the previous track, ⏭ to the next, play/pause touches only the current track — so you
can run the set, or skip ahead, without ever unlocking. This is the whole set sequencing in the
background, not just a single track: each track ends, the next begins, hands-free.

**User story:** "Start a big rip or burn, lock my phone, and trust it'll be finished when I pull
it back out — and once a set is playing, run the whole thing from the lock screen, skipping tracks
from my headphones, without the music ever cutting out because I left the app."

---

## 39. Press Play on a playlist or pocket — hear it now, in order or shuffled

A playlist and a pocket aren't just things you *shape* — now you can **hear them straight away**.
Each playlist and pocket detail screen carries two side-by-side buttons:

- **▶ Play** — play its songs **in their listed order**, top to bottom,
- **🔀 Shuffle** — play the same songs in a **random order**.

Tap either and the app jumps you to a single reusable **"Now Playing"** set and **starts playing
at once** in the inline player, auto-advancing track to track. It's built **literally from the
songs you're looking at** — the exact list, in order (or shuffled) — not the "realized" set the
**make-a-set-list** button produces (§40): no sampling, no harmonic autofill, no dedup. A song
that can't be resolved to anything playable is simply dropped from the run. Because it's **one
shared set** that's **reused** every time, hitting **▶ Play** or **🔀 Shuffle** anywhere just
**replaces** what's in Now Playing rather than piling up a new set each time — and it's **hidden
from your set-list history** and **cleared on launch**, so it never clutters the sets you've
deliberately saved.

Landing in **Now Playing** drops you into the normal setlist screen (§35), so you can **see
what's next and reorder it on the fly** while it plays — exactly the controls you'd want with a
set running.

**User story:** "I just want to *hear* this crate right now — one tap to play it in order, one
to shuffle it — and still see and nudge what's coming up next."

---

## 40. The "make a set list" button — freeze a take from a playlist

The **older** ▶ Play behavior — *realize* a playlist into a frozen, saved take (expanding albums,
sampling over-budget pockets to fit, autofilling harmonic bridges; §22–§23) — now lives on its
own toolbar button marked with the **list.bullet.clipboard** icon. Tap it to generate a concrete,
persisted **set list** from the template, just as before; the plain **▶ Play** beside it is now
the play-it-now button from §39.

**User story:** "Keep the two ideas separate: one button just plays the crate, the other builds
me a real, saved set list I can tweak, rip, and burn."

---

## 41. Your playlists on top; folders to organize them

**Your playlists come first.** The Playlists screen now renders **your own playlists above** the
**"From your sources"** section — the sets you build are what you reach for, so they sit at the
top.

**Folders.** You can now group playlists into **folders**:

- **＋ New folder** — create one and name it,
- **rename** or **delete** a folder — deleting it **keeps the playlists**; they simply fall back
  to the top level,
- **move** a playlist into (or out of) a folder.

Folders show as **collapsible sections** ordered by name, and **each section remembers whether
you left it collapsed** — so a long shelf of sets stays tidy. Folders ride along through
**import/merge** and the **backup zip**, so the way you've organized your sets travels with them
to another device.

**User story:** "I've got a lot of sets — let me file them into folders I can fold shut, and keep
the ones I made up top where I actually look."

---

## 42. Device / Cloud playback — play burned files or stream

A small **browser-style toggle** now sits on the **setlist, playlist and pocket** toolbars, with
two modes that change **where the audio comes from**:

- **☁ Cloud** (the streaming default) — play from your **streaming provider**, falling back to a
  **rip** from the server. This is the behavior you've had.
- **📱 Device** — play the **burned files** from your designated **burnt-music folder** (§34), so
  the set plays with **no signal and no rip server**.

In **Device** mode, a **Play-all skips any track that isn't burned yet** (it plays only what's
actually on the device) — and if *nothing* in the set is on the device, you get a **"nothing on
device"** banner instead of silence. Tapping a **single** un-burned song still **falls back to
Cloud** for that one track, so you're never stuck. The toggle is global and the now-playing state
stays consistent across it; flipping mode mid-set lets the **current track finish** before the
next one honors the new mode.

On **iPhone/iPad** the inline per-song player **slides and collapses as the set advances** —
collapsing the track that just finished and expanding the next — so the open player always tracks
the song you're hearing. (The Mac player stays a plain, fixed panel.)

**User story:** "In a basement with no bars I flip to Device and run the set off what I burned; on
the couch I flip to Cloud and stream — same toggle, same set, no fuss."

---

## 43. Burned files are named so you can mix from them

When you **Burn** a set, the downloaded files now carry **descriptive, mixer-ready names** instead
of a bare title. Each filename is built from the track's
**Artist · Song · Album · Year · Genre · Camelot · Key · BPM** (sanitized for the filesystem and
length-capped, with the song id kept on the end so names never collide). Digital and cloud rips
are named **per song**; a shared **analog whole-album** file is named at the **album** level. Each
audio file still gets its same-named **`.txt` sidecar** with the full BPM/key/sentiment/metadata
read-out.

**User story:** "When I drag the burned files into my DJ app, the filename alone already tells me
the key, Camelot code and BPM — I can order a set straight from the folder."

---

## 44. Play mode — the set runs like a music transport (iPhone)

Once a set list is **playing** (§35), the iPhone toolbar reshapes itself into a clean **music
transport**. The three controls — **⏮ previous · ⏯ play/pause · ⏭ next** — move to the **center
of the nav bar**, evenly spaced and accent-tinted, so the bar reads exactly like a player rather
than a row of mixed buttons. Prev/next step the **whole set** (not just the current track); the
middle button toggles **play/pause on whichever backend is live** — Apple Music streaming, or the
rip/local engine — and shows ⏸ while it's playing, ▶ while paused.

**Stop takes the play button's slot.** The **⏹ Stop** that ends the run sits in the **same
trailing spot** that showed **▶ Play** when the set was idle — so the one obvious "start / end the
set" affordance never moves and is never buried. (It is *not* hidden in a menu.)

**Everything else folds into ••• .** While the set plays, the secondary actions collapse into a
single **••• overflow** menu — **Add note**, **Rip**, **Burn**, **Rename**, **Edit order**
(present but **disabled** mid-play, since reordering would desync the running queue), and a
**Delete set list** below a divider. **Rip and Burn are two separate, flat menu items**, not a
nested "Rip / Burn" submenu — one tap each.

When the set is **idle**, the iPhone bar stays the familiar flat layout (▶ Play · the
device/cloud toggle · Edit · •••). And the **Mac keeps its flat toolbar** in every state (it has
no centered nav-bar slot) — play/stop with ⏮/⏭ flanking it while running, and the secondary
actions laid out in a row.

**User story:** "When the set is actually playing, give me a real transport — prev, play/pause,
next, centered — and tuck everything else out of the way so I'm not fat-fingering Delete reaching
for Next."

---

## 45. The set advances at each track's *own* length

A whole side of vinyl is ripped as **one mp3**, with every song pointing at its **start offset**
inside that shared file. That used to mean the auto-advance only fired at the **end of the entire
album file** — so a set built from analog tracks would play one song, then keep rolling straight
into the *next* album track instead of moving to the next set entry.

Now each playing track **advances at its own end**: the player arms a boundary at *this song's
start + its known length*, and when playback passes it the set moves on to the next entry — even
though the audio file keeps going. Per-song files (digital rips, individual burns) are untouched:
they have a real end of their own, so they advance naturally and are never cut short by a missing
or short catalog length. The same length-aware advance works whether the track is **streaming a
cloud rip**, **playing a burned file**, or sitting **inside a shared album rip** — so a set plays
through cleanly regardless of where its audio comes from.

**Tap a row mid-set and the set follows you.** If a set is running and you tap **▶** on a *row
that's in that set*, the set **repositions onto it** and keeps auto-advancing from there — instead
of the set silently stopping when that hand-started track ends. (If the same song appears more
than once, it jumps to the **nearest occurrence**, preferring the one ahead of where you are.) The
persistent **⏮ / ⏭** transport (§44) is always there to step by hand.

**User story:** "Each track should hand off to the next one at *its* end, not the end of the whole
record side — and if I tap a song in the set to jump there, the set should pick up from that song,
not quit on me."

---

## 46. Opens with no network — the offline-first catalog & playback

PocketDJ is offline-*first*, and the native app now lives up to it from the very first second: it
**opens with your full catalog even with no signal at all**.

**The catalog opens offline.** Every time the app successfully loads a source's index online, it
**caches the raw catalog to disk** (one file per source, under the app's Application Support). On a
later launch with **no network — or a server that's down — it falls back to that cached catalog**,
so all 1,300+ albums / 12k+ songs are right there, browsable and searchable, on a plane or in a
basement. With multiple sources, it degrades **gracefully**: each source falls back to its own
cache independently, an un-cached source (one you never loaded online) is simply **skipped**, and
the app only fails to open if **every** source fails. (The catalog index is too big for the
system's default response cache to keep, which is why offline relaunch used to come up empty — the
app now keeps its own copy that survives restarts.)

**Burned songs always play first — and actually make sound offline.** On **every** way you start a
song — tapping **▶** on a row, **⌘P** on the keyboard, or **Play-All** — the app now **prefers a
burned local file** whenever one exists, in **both** Device and Cloud mode. So a song you've
burned plays **instantly and with no network**, never reaching for the rip server first. Crucially,
a burned file living in a **folder you picked yourself** (§34) now **plays its audio** offline —
the app **holds that folder's read access open for the whole song** instead of dropping it the
instant it found the file, which is what used to leave a picked-folder burn stuck at **0:00 with no
sound**. (Playback only needs the folder *readable*, so a folder that's momentarily not writable —
say an offline iCloud Drive folder — still plays.)

**Snappier when the server's just unreachable.** When a rip server is configured but can't be
reached (asleep at home while you're on venue wifi), a play request now gives up in **~12 seconds**
instead of stalling a full minute — so **Play-All skips an un-burned track promptly** and keeps the
set moving. And the inline scrubber falls back to the **catalog's length** for its end timestamp,
so the **/ m:ss** is sensible even before the audio file reports its real duration.

**User story:** "Open the app in a dead zone and still have my whole crate — and have everything
I burned play instantly, with sound, no signal, no waiting on a server that isn't there."

---

## 47. The background "Burning N of M" count now actually ticks up

A **Burn** runs as a string of background downloads, and the collection screen shows a
**"Burning N of M"** overlay while it works. That counter used to **freeze at the starting total**
— it was reading from the background-transfer engine, which (because it has to be the system's
download delegate) isn't the kind of object the UI can watch for changes. Now the progress is
**mirrored into an observable store** as each download lands, so the overlay **re-renders and
counts up** — *Burning 3 of 10 → 4 of 10 → …* — as the set burns, finishing on the run's summary
(§33).

**User story:** "When I burn a set I want to watch it actually progress — not stare at 'Burning 1
of 10' until the whole thing's silently done."

---

## 48. Analog cut export — the full single-track list for your DJ software

A side of vinyl rips as **one album mp3**, and that whole-album file (the "backcase") is what a
burn has always written. But other DJ software wants the **individual tracks** as their own files.
So a Burn now also exports a **per-song cut** of every analog track **alongside** the whole-album
file.

**How it's made.** When the rip server rips an analog album, it **slices each song out** of the
freshly-made album mp3 (from the song's start offset, for its own length — *derived from the
segment boundaries* when the catalog doesn't carry a length) and uploads it as its own file, **ID3
tagged** with the track's **title, artist and album**. A **Burn** then downloads each cut into your
burn folder under the **same descriptive, mixer-ready name** as a digital track (§43 —
Artist · Song · Album · Year · Genre · Camelot · Key · BPM), **paired with its own `.txt`
sidecar**. So your folder ends up with both: the **whole-album backcase** *and* the **full list of
individual, tagged single tracks** ready to drop into any DJ app.

**It stays current on its own.** If a cut is **re-uploaded** on the server (re-sliced or re-tagged),
the next burn notices it's **newer** and **re-pulls just that file**, cleanly replacing the old one
— no manifest change needed. A cut that fails to export **never fails the burn** (the album file
alone still plays and is the backcase). And playback is **completely unchanged**: songs still play
from the album file at their start offset — the per-song cut is **burn-only**, purely for handing
off to other software.

**Retro-fitting older rips.** Two server actions backfill the cuts for albums ripped before this
existed: one **slices a cut for every analog track that's missing one** (straight from the raw
album source, no full re-transcode), and one **re-tags every existing cut** (title/artist/album,
a fast tag-only pass with no re-encode) — bumping each file's timestamp so the next burn auto-pulls
the freshly-tagged version.

**User story:** "Burn me the whole record *and* every song as its own properly-tagged file, named
with the key and BPM, so I can load the single tracks straight into my DJ software — and quietly
keep them up to date."

---

# Part IV — Mix & Stems: the DJ engine

Everything so far gets you to a *set* — a crate explored, a playlist shaped, a set list ripped and
burned for offline. **Part IV is where you actually mix it.** The native iPhone / iPad / Mac app
adds a fourth top-level tab — **Mix** (the slider icon, beside Browser · Playlists · Settings) — a
real **two-deck DJ console**, and **stems**: a track split into four parts (**vocals · drums · bass ·
other**) you can mute, solo and remix live. Both run on the *same* burned, on-device files
everything else uses — nothing here streams — so a mix, stems and all, works in a basement with no
signal. The Mix engine is **app-scoped**, so a mix keeps playing while you leave the tab and come
back.

These sections are **prose-only** (no screenshots captured yet); they describe the real Mix
(`apple/PocketDJ/Mix/MixView.swift` + `MixEngine.swift`) and stem
(`StemAuditionPanel.swift` · `StemPlayer.swift`) surfaces.

---

## 49. The Mix tab — two decks, one screen

The Mix tab is a **DJ main screen**: **two decks side by side** — **Deck A** on the left, **Deck B**
on the right, equal width — with **one crossfader** spanning both beneath them and **one big master
Play/Pause** at the bottom. On an iPhone the whole console scrolls in portrait; on iPad and Mac it's
roomy and centered (the controls cap at a comfortable width).

**Load a track.** A deck plays a **burned / local** track — only **on-device (burned)** songs can be
mixed (the engine never streams). Each deck header carries a **deck letter** and a quick **source
menu** to point that deck at a **pocket** or **set list**; the two decks can share one source or each
hold its own. **Tap the header** (or **long-press / right-click** it) to open the **track-loader
sheet** — a searchable picker (by **artist · title · album**) of that source's burned tracks. If the
collection isn't burned yet, the sheet says so: *only burned songs can be mixed — burn the collection
first.*

**The header reads like a deck.** Once loaded it shows a **waveform** image, the **album artwork**,
the **title · artist**, and a **key | BPM** chip — the Camelot key when known, otherwise the BPM — so
each deck shows at a glance what's cued and whether the two will mix.

**User story:** "Give me two real decks on my phone, loaded straight from the crates I already burned
for offline — pick a pocket per deck and drop a record on each."

---

## 50. Per-deck controls — seek, tempo & pitch

Under each deck's header sits its control stack:

- a **seek scrubber** — drag to seek (sample-accurate), with **elapsed / duration** clocks at its
  ends,
- the **Lead · Sync · Reset** row (beat-matching — §53; the **Stems** toggle joins it for a stemmed
  track — §56),
- a **Tempo** slider — live **time-stretch** from **0.5× to 2.0×** with **pitch preserved**,
- a **Pitch** slider — **±12 semitones** with **tempo preserved** (independent of the tempo slider),
- a **Vol** slider (0–100%),
- a **per-deck play/pause** for cueing one side on its own.

**Reset (↺)** wipes the deck back to neutral — clears tempo, pitch, every effect and the volume trim,
then rewinds — so you can recover a deck to a clean state in one tap. **Long-press** (iOS) /
**right-click** (macOS) the ↺ opens a **"Clear deck (eject track)"** action that goes one step
further: it **ejects the loaded track entirely** — stopping playback and returning the whole deck to
its **empty zero state** — for when you want to start the side over from nothing, not just re-neutralise
the track that's on it.

**User story:** "Stretch a track to match a tempo without chipmunking it, nudge its key by a few
semitones to mix in harmonically, scrub to the drop — reset the deck clean when I want to start over,
or hold Reset to eject the track and clear the deck completely."

---

## 51. The effects grid — tap to toggle, dial the strength

Each deck has a **2×2 effects grid**: **Compressor · Reverb** on top, **Flanger · Filter** below.
**Tap** a pad to **toggle** that effect on or off (it fills with the accent colour when on).
**Long-press** (iOS) / **right-click** (macOS) a pad to reveal its **STRENGTH** (the wet amount)
right there — and revealing it also **switches the effect on**, so the dial is immediately audible.

How the strength control appears adapts to the screen: on **landscape / iPad / macOS** the pad
**flips in place** to a strength slider — same footprint, no popover, no navigation — and **flips back
after 3 s idle**. On **iPhone portrait** the pad is too narrow to drag a slider in place, so it opens
a **fixed-width popover** instead (dismissed by an outside-tap or after 3 s idle).

**User story:** "Reach an effect with one tap, and when I want to ride it, hold the pad and a real
slider's right there — sized so I can actually drag it on a phone."

---

## 52. The crossfader & the master transport

One **equal-power crossfader** spans both decks (**A ◀ ▶ B**). Equal-power means the **midpoint isn't
a volume dip** — both decks stay at full perceived loudness through the blend, so a slow crossfade
sounds smooth rather than dropping out in the middle. Each deck's effective gain is its own **Vol**
trim **×** the crossfade factor, so the fader and the per-deck volumes compose cleanly.

The **master Play/Pause** at the bottom drives **both decks at once** (disabled until at least one
deck is loaded). Alongside it, each deck keeps its **own** play/pause, so you can start one side to
cue it before bringing it in on the fader.

**User story:** "Blend the two decks with a fader that doesn't gut the mix in the middle, and start
or stop the whole thing with one button — or cue a single deck on its own first."

---

## 53. Lead & Sync — beat-matching to a reference deck

Tap **Lead (★)** on a deck to make it the **tempo reference** — it's **exclusive** (tapping the
current Lead clears it). On the *other* deck, **Sync** matches its **tempo** (playback rate) to the
Lead's **effective BPM**, **octave-folded** into the 0.5–2.0× range — so a 70-BPM track half- or
double-times to lock against a 140 — then **best-effort phase-aligns the downbeats**.

Crucially, the match prefers each song's **MEASURED beat-grid BPM** (from the rips indexer, measured
on the *exact* burned file) over the catalog's **rounded** BPM — so a sync doesn't slowly drift the
way it would off a `120`-vs-`119.7` rounding error. **Sync** is only enabled when there's a Lead that
isn't this deck and **both decks have a known BPM**.

**User story:** "Pick one deck as the reference, hit Sync on the other, and have it actually lock —
to the tempo I measured off the record, not a rounded guess — with the downbeats lined up to mix on."

---

## 54. Auto-Mix — the auto-DJ

A **Manual / Auto** toggle sits in the Mix toolbar — one tap flips the mode. In **Auto**, pick a
**collection** (a pocket or a set list) from the toolbar picker, then hit **▶ Play** (in listed
order) or **🔀 Shuffle**. The engine plays the whole collection **end-to-end across the two decks** —
**auto-loading the next track** onto the free deck and running a **timed crossfade** between them
(the lead-in and fade lengths come from Settings).

While it runs, a live **"Auto-mixing"** banner shows the running status (**N / M**) with a **Stop**.
The banner lives in the body of the screen (not only the nav bar), so on an iPhone — where a crowded
toolbar collapses extras into a "•••" menu — the **Stop stays reachable** the whole time.

**Two "glide" toggles** ride the auto-mix pill (in both the setup row and the running banner, so you
can arm them before Play or flip them mid-set):

- **FX Glide** — every transition gets a **coherent effect sweep**: an effect (filter, reverb, or
  flanger) eases **in** on the outgoing track *before* the volume sweep, rides **both** tracks through
  the crossfade, then eases **off** the incoming track. It keeps the **same effect for a run of 3–5
  songs** so a texture settles in rather than flickering track to track.
- **Mix Glide** — the two tracks **ease toward each other** through the transition, but **only using
  the data each track actually has** (no guessing):
  - when **both tracks have a Camelot key**, they **bend in pitch** toward a shared key — the outgoing
    track glides up (or down) by up to **one key** while the incoming starts the opposite way, so they
    **meet in the middle** and the incoming then **settles back to its own key**;
  - when **both tracks have a BPM**, they **beat-match** — the same tempo-matching maths as **Sync**
    (§53), pulling the two tempos together on the **beat grid** with a best-effort **downbeat align**,
    then releasing the incoming track back to its own tempo;
  - when a track is **missing** its key or BPM, that dimension is simply **left alone** — and if *neither*
    is known for both tracks, Mix Glide falls back to the **plain volume-fader crossfade** (no bend at
    all). It never invents a key or tempo it doesn't have.

  Its **length is a setting** (**Settings ▸ Mix**, default **10 s**) so you can make the bend as
  gradual as you like.

Both are off by default; the plain crossfade is unchanged when they're off.

**Pause & Resume — walk away, take over, come back.** Next to Stop, the banner shows a **Pause**
button while the auto-DJ runs (and a **Resume** button once it's paused). **Pause** doesn't stop the
music or your recording — it just **hands you the decks**: the auto-DJ stops advancing so you can mix
by hand for as long as you like (load tracks, ride the faders, whatever). Hit **Resume** and it slots
back in **musically**, never with an abrupt cut:

- if **one deck** is playing, it lets that track ride until it reaches the crossfade window, then loads
  the **next unplayed** track from the collection onto the other deck and fades over;
- if you've got **two decks blended** together, it waits for the **first** of them to end, then loads
  the next unplayed track onto that freed deck and **glides/fades the still-playing deck over to it** —
  so the handoff happens right as your first track runs out.

It always picks the **next *unplayed*** track from the collection, so nothing you already spun during
your hands-on stretch gets repeated. Pause and Resume both drop a marker on the session timeline (§59),
so a replay shows exactly where you took over and handed back. Perfect for a long night: *auto-mix →
Pause for a bathroom break's worth of hand-mixing → Resume → repeat until sunrise.*

**Auto mode points both decks at the collection.** The moment you're in Auto with a collection chosen,
**both decks' load-source is set to that collection** — so when you Pause and want to hand-load more
tracks, the track browser is already scoped to the right crate on each deck, no re-picking.

**Run it from your pocket — the lock-screen card is mix-native.** While the Mix is what's playing,
the **lock screen / Control Center card** shows the live deck's track **with its album cover** — and
the card **stays on the deck you paused** (it never flips to the other deck's title and art just
because the music stopped). The buttons map to what a DJ actually means by them: **⏸ suspends** the
auto-DJ exactly like the in-app Pause (the session, queue and recording stay alive — it never
silently drops you back to manual mode), **▶ resumes only what the pause silenced** — one deck
paused, one deck comes back, never both blasting — and picks the auto-mix back up where it left off
(a half-finished crossfade resumes mid-sweep, not jumped to the end). **⏭ is the fast track-switch**
(the same 5 s sweep as double-tapping Skip in the app) and **⏮ is the slow one** (your Settings
skip-fade, same as a single tap) — and pressed while paused they mean *"resume the mix on the next
track."* All from the pocket, AirPods, or the car — and when a **setlist** (not the Mix) is what's
playing, the very same buttons keep their normal meaning: ⏮ previous track, ⏭ next track,
play/pause the current track.

**User story:** "Point it at a pocket, hit Play or Shuffle, and let it DJ the whole crate for me —
crossfading track to track on its own — with a Stop I can always find. Flip on FX Glide for a sweep
through each blend, or Mix Glide to bend the keys and tempos together where the data's there so
nothing clashes — set how long that glide takes. And when I want to jump in, hit Pause, mix a few
tracks myself, then Resume and let it take back over right as my last track ends."

---

## 55. Stems I — the SongDetail stem-audition panel

The simplest place to meet **stems** is a song's own detail screen. On a **stemmed** song the
detail-view transport grows a **stem glyph (☰)**; tap it to **slide out a "Stems" panel** beneath the
inline player.

**It burns first, then plays — fully offline.** On open the panel **burns the 4 stems** to the
offline store — *"Burning stems for offline playback…"* — because stems are **never streamed**; once
on disk it reads **"4 · offline"** and they play with no network. The panel then shows **four rows —
Vocals · Drums · Bass · Other** — each with a **solo ▶** ("play just this one") and a **🔊 / 🔇 mute**
toggle, over a **shared scrubber**, with a **centered "Play All"** that starts **every stem in perfect
sync from 0:00, all audible**, so you can then **mute and solo live**. Play All becomes **Pause /
Resume** mid-track (keeping your mute set and position), and a **↺** restarts from the top.

This panel is the **end-to-end test bed** for the stem feature — the same **synchronized multi-stem
player** the Mix decks reuse, proven on one song before it reaches the two-deck console.

**User story:** "On any stemmed song, pull out the four parts, hit Play All, and start muting the
vocal or soloing the drums — all in sync, all working with no signal."

---

## 56. Stems II — the Mix stem decks (the coloured 2×2 grid)

On the Mix tab, load a **stemmed + burned** track onto a deck and a **"Stems"** toggle appears
**between Sync and Reset**. Tap it — it **burns the 4 stems first if they aren't on disk** (a brief
spinner) — to enter **stem mode**, which reveals a **2×2 STEM GRID** under the effects:

- **Vocals (purple) · Drums (yellow) · Bass (red) · Other (green).**

The four stems play **in sync through the deck's effects + crossfader** — so the **tempo, pitch, the
effects grid and the crossfade all act on the stem mix**, exactly as they do on a normal track.
**TAP** a pad to **MUTE** that stem (it **greys out**, with a speaker-slash); tap again to unmute.
**LONG-PRESS / RIGHT-CLICK** a pad for that stem's **VOLUME**. The grid **only shows in stem mode**,
so a normal deck stays compact.

The volume control follows the same screen-aware split as the effects (§51): **iPhone portrait** opens
the per-stem slider as a **fixed-width popover** (the in-place flip is too narrow to drag there,
dismissing on outside-tap or after 3 s idle), while **landscape / iPad / macOS** flip the pad **in
place**.

**User story:** "Drop a stemmed record on a deck, tap Stems, and now I'm muting the vocal and
riding the bass right inside the mix — through the same effects and crossfader as everything else."

---

## 57. Stems III — burn a collection's stems · mix entirely offline

Stems are only useful in the field if they're **on the device**, so **burning a collection now also
pulls every stemmed song's 4 stems** into the burn folder — alongside the audio and sidecars (§43,
§48). The result: a **burned collection plays *and* mixes entirely offline**, stems included.

It's **idempotent and stop-aware**. Re-burning fetches **only the stems that are missing**, so it
**picks up songs that became stemmed since** the last burn (driven by a **"Burning stems X of N"**
pill); a stem that fails to download **never fails the burn** (the album audio still plays). And
burning **only fetches what the server has already separated** — it **never triggers** separation
itself.

The stems are produced **server-side** by a **Stemify collection / song** action — an on-demand
**Demucs** stem-separation indexer (**htdemucs**). So the full pipeline reads: **rip → stemify →
burn**, and the whole crate lands on the phone as a **fully-offline, stem-mixable DJ set**.

**User story:** "Stemify the records I want to take apart, burn the set once, and have every stem
on my phone — so I can mute, solo and remix in a venue with no bars and no server."

---

## 58. Record your mix — the session recording

A **record button** (the ⏺ record icon) sits in the **Mix toolbar**. Tap it and it **pulses a purple→
red gradient** while it captures the **audio of your mix** — the house output, exactly what an audience
would hear (your monitoring **cue** in the headphones never leaks in). A live **"● Recording m:ss"**
strip shows the elapsed time with a **Stop**, so on an iPhone the state and the stop stay visible even
if the toolbar tucks the button away. Tap the button again (or Stop) to end the capture.

Recordings are filed **per session** into a **session folder** — one subfolder per mix session, so
each sitting keeps its own takes (and there's room to grow other session data later). By default that
lives in the app's private storage; in **Settings ▸ Storage** (the storage manager, §64) you can
**pick your own folder** (just like the burnt-music folder) to browse the `.m4a` files yourself in
Finder / the Files app.

**It's written to survive a crash.** The take isn't held in memory and flushed at the end — it's
**streamed to disk continuously** (fragmented AAC), so if the app is killed, runs out of disk, or the
phone dies mid-set, **whatever played up to that moment is already a playable file**. On the next
launch the app **re-files any interrupted take** back onto its session automatically — from whichever
screen you open, and even a take that was mid-capture when you **quit the app** is filed on the way
out — so a crash never loses the recording.

**And it survives everything short of a crash, too.** Yank the headphones, switch to the speaker, hop
between Bluetooth devices mid-set — the audio engine the system kills comes **back by itself**, the mix
picks up where it stopped, and the take keeps rolling (dead air is never silently written into it). A
**phone call** pauses the whole performance exactly like the lock-screen ⏸ — and when the call ends,
only what the call paused resumes; a mix you'd already paused yourself stays paused. If capture ever
*does* stop making progress while music is audibly playing, the recording strip turns **amber —
"Recording — no audio"** — so you find out mid-set, not at playback. And if the file itself can't keep
writing (disk full, your session folder vanished), the recording **stops itself, keeps everything
captured so far, and tells you why** instead of pulsing over a dead take. While recording, the Shazam
button sits out — its microphone listener would fight the capture for the audio session.

Every take shows up back on the **Sessions** screen (the same place that replays the *actions* of a
mix): open a session and each recording gets a **▶ / ⏹ play control** **and a scrub bar** — so you can
**hear the mix back** and **jump around inside it**, not just watch the moves. The session list marks
how many takes a session has. Each take also has a **🗑 delete** (tap or long-press/right-click) that,
after a confirmation, removes **that one recording's audio** — the session's played-tracks log and
timeline stay. To clear **every** take at once, use **Settings ▸ Storage ▸ Delete session
recordings** (§64).

**User story:** "Hit record before I start the set, let the mix run, and stop when I'm done — then
play the whole thing back from Sessions and scrub to any moment, or grab the file from my own folder
to share. Even if it crashes, the recording's still there."

---

## 59. Replay a session — the wrapped move-by-move timeline

Every mix also records the **moves themselves** — each load, play/pause, seek, tempo & pitch change,
volume, **crossfader**, effect, stem action, Lead/Sync and Reset — into a **time-stamped timeline** on
the **Sessions** screen, so a set can be **replayed move by move** (the raw material for later training
an auto-mix model). This batch made that timeline far easier to actually read:

- **It wraps to fill the screen** instead of scrolling forever to the right — **5 moves per row on
  Mac, 3 on iPad** — with **arrows between the nodes** (→ along a row, then ↵ down to the next) so the
  **left-to-right-then-down** order is unmistakable.
- **Glides are one compact node, not a blur of ticks.** An auto-mix bend (or a crossfade) that used to
  be thousands of tiny moves now shows as a single **"glide"** node reading **from → to** with its
  **average rate of change** — so an automated sweep reads as one gesture, while a human's subtler
  hand-moves are still captured change by change. (The **crossfader** is captured the same way.)
- **Tap a "load" node** (long-press isn't needed — a tap) and the track's **song-metadata card** pops
  up, so you can see exactly *what* was dropped at that point in the set.

**User story:** "Open a past session and actually read it — the moves wrap across the screen in order,
each auto-glide is one clean from→to node instead of a thousand ticks, and I can tap any track I loaded
to see what it was."

---

## 60. Export a tracklist — PocketDJ or CSV

Exporting a **playlist**, **pocket**, **set list**, or a **session's tracklist** now asks **one extra
question — the format:**

- **PocketDJ (full metadata)** — the existing re-importable bundle (`.pocketdj.zip`) that keeps
  *everything* PocketDJ knows and can be loaded straight back into the app. This is the **default**.
- **CSV (tracklist)** — a **universal** comma-separated list any spreadsheet, DJ app, or database can
  read, with just the columns **everyone** shares: **play track # · Title · Artist · Album · Year ·
  Genre**. It deliberately **leaves out** PocketDJ's own metadata (BPM/key/segments/provenance) —
  that's what the PocketDJ format is for — so the CSV stays portable.

The format picker appears after you tap **Export**; pick **PocketDJ** to keep working inside the app,
or **CSV** to hand your tracklist to the outside world.

**User story:** "Export a set as PocketDJ when I'm round-tripping it in the app — or as a plain CSV
with just the universal columns when I need to drop the tracklist into a spreadsheet or another DJ
tool."

---

## 61. Hey Siri — App Shortcuts (play, auto-mix, create a pocket)

The native app's performance surface is now **voice- and system-invocable** — no Shortcuts-app
setup, live the moment the app installs. Every phrase ends **"…in PocketDJ"**:

- **"Play *Friday Warmup* in PocketDJ"** / **"Shuffle *Friday Warmup* in PocketDJ"** — plays a
  **playlist** exactly like tapping ▶/🔀 on its detail screen: the resolved songs snapshot into the
  reusable **Now Playing** set list and the app-scoped player starts — even from the Home Screen,
  the Action button, or a locked phone (playback starts in the background; the lock-screen card
  takes over from there).
- **"Play the pocket *Deep Funk* in PocketDJ"** — same for a **pocket** (its songs, albums, and
  nested pockets in DAG order), with a shuffle variant.
- **"Auto-mix *Deep Funk* in PocketDJ"** — starts the **Auto-DJ** (Ch. 54) from a pocket **or** a
  set list, with the Settings lead/fade and your glide preferences. Auto-mix plays **burned local
  files only**, and Siri says so if the collection has none yet ("…burn it first").
- **"Pause the auto-mix in PocketDJ" / "Resume the auto-mix in PocketDJ"** — the same suspend/resume
  as the lock-screen ⏸/▶: the mix clock **freezes** through the pause and resumes **exactly** the
  fade it was in — never a cold stop.
- **"Create a pocket in PocketDJ"** — Siri asks *"What kind of pocket should I build?"* — answer in
  plain words: *"optimistic soul, funk, r&b or disco songs from 1960 to 1989."* On-device Apple
  Intelligence (iOS 26+) parses the brief; PocketDJ then searches the whole catalog — **exact** year
  range, **fuzzy** genre matching, and **mood-vector similarity** over each song's sentiment
  keywords — the model curates and orders the best matches, and up to **90 minutes** of songs (the
  minutes are adjustable in Shortcuts) are saved as a new pocket, **asynchronously**: Siri answers
  right away and the pocket appears in Playlists ▸ Pockets moments later, with your brief kept as
  its description.

Beyond voice, the same intents surface everywhere the system composes actions: the **Shortcuts app**
(with playlist/pocket pickers), **Spotlight** — where your playlists and pockets are now **indexed by
name**, and tapping one opens it straight in the app — and system **suggestions**, which learn from
the real ▶/🔀/Auto-mix taps the app donates as you use it. Renaming a playlist re-teaches Siri the
new name automatically.

**User story:** "Hands on the decks — or walking out the door — I say *'Shuffle Crate Warmers in
PocketDJ'* and it's playing; and when I only know the vibe I want, I ask Siri to *create a pocket*
and find ninety minutes of it waiting in the app."

---

## 62. The home Now Playing deck — a spinning gold record on the menu screen

Start any collection playing — a playlist, a pocket, an album, a Siri request — and the
app's **home menu screen** (iPhone) or the space **under the sidebar menu** (iPad, Mac)
becomes a little record deck. It appears whenever music is playing in any mode **except
Mix** (the Mix tab has its own two-deck board; while a mix or Auto-DJ owns the audio, the
home deck yields).

Top to bottom:

- **The track name and artist**, right above the player.
- **A gold vinyl record spinning inside a blue record-player chassis** (the same blue as
  the app's icons), the current album's cover as its center label, a fixed tonearm on the
  right. The record **spins at a rate that reflects the track's tempo** — one revolution
  per 4-beat bar of the measured **beat-grid BPM** (catalog BPM as fallback), so a ~133 BPM
  banger turns like real 33 RPM vinyl and faster tracks visibly spin faster. Pause and the
  platter **freezes in place** (no rewind-to-twelve-o'clock); resume and it picks up from
  the same groove. Unknown tempo ⇒ classic 33⅓.
- **⏮ ⏯ ⏭ transport** — the same prev/play-pause/next that works from the lock screen.
- **Up next** — the not-yet-played queue of the playing collection. **Drag to reorder**
  (Reorder button on iPhone) or **✕ / swipe to remove**; edits touch only what hasn't
  played yet, so the current track never skips or restarts.
- **Add-search — the same native search control as the Browser tab** (user-tested: a
  bottom text field hid under the keyboard). On iPhone the field rides the bar at the
  top; on **iPad and Mac it sits on the LEFT, at the top of the sidebar** (this also
  fixed a Mac crash — two search fields were fighting over the window toolbar). **⌘L
  jumps the cursor straight into it**, so a set is fully drivable from the keyboard;
  type
  anything ("optimistic", "cobalt", a title) and matching **albums appear above songs**,
  each in a **collapsible** section (fold the albums away to scroll just songs). **＋
  appends** a song — or an album's whole tracklist — to the end of the queue, live, without
  interrupting playback. Exact-title matches rank first even in a ~100k-song catalog, and
  the search runs debounced off the main thread so typing stays smooth.

The whole deck **scrolls** (user-tested): pull the list up and the record player and its
controls slide out of view so **Up next can take over the panel** — the menu/tab links
above stay pinned. The **tonearm plays the record**: it rests on the outer edge at
0:00 and sweeps toward the center label in proportion to the play position, like a real
stylus crossing the grooves. **Right-click or long-press** is everywhere: a **queue row**
offers *Move to top · Move to bottom · Remove*, a **search result song OR album** offers
*Add next · Add to end* (＋ still appends; an album lands its whole tracklist, in album
order, wherever you chose), and **the record itself** opens the current track's full
**song detail metadata** — closed with a Back button top-left on iPhone, or an
always-visible **✕** on iPad and Mac (Esc still works for the keyboard-inclined).

And the **Mix tab now wears Apple Music's AutoMix mark** — the two overlapping records
(one solid, one open) from Apple's own symbol sheet, redrawn to color exactly like the
neighboring tab icons.

**Getting there is also nicer now:** on iOS the app opens on the **home menu** ("PocketDJ" —
the ✦ sparkle is gone) unless you'd navigated somewhere before — then it **reopens wherever
you last left off**. On the Mac it always opens on the **Mix** tab, ready to DJ.

**User story:** "I start a pocket from the couch, glance at my phone's home screen and see
the gold record turning at the track's tempo with what's coming next — I drag tomorrow's
opener up the queue, type 'slow burn', add it straight into the set, and the music never
hiccups."


---

## 63. The nuclear option — a mushroom cloud easter egg

Settings ▸ **Reset all app state** is PocketDJ's nuclear option — so confirming it now
detonates one. A stylized **mushroom cloud** blooms up from the bottom of the screen
(white-hot flash, fireball cap rising on its stem, glowing ground ring) and drifts away
about two and a half seconds later. Pure decoration: it never blocks a tap, and the reset
itself runs exactly as before.

**User story:** "If I'm going to erase everything, at least let me enjoy the blast."

---

## 64. Settings ▸ Storage — the storage manager

Burned music, stems, beat grids, and mix recordings all live on your device — and until now
the only way out was the nuclear reset. Settings now has a single **Storage** row that opens
the **storage manager** (with a back button to return), gathering everything about on-device
space in one place.

**What's on it.** At the top, **On this device** shows what your library actually costs:
**Burnt music** (songs + total size — audio, per-song cuts, stems, beat grids, and sidecars,
across the app's storage *and* your chosen folder) and **Session recordings** (takes + size).
Below that live the two **folder pickers** that used to sit on the Settings root — the
burnt-music folder (§34) and the mix-sessions folder (§58) — unchanged, just relocated to
where they belong.

**Deleting downloaded music.** Three tools, all with confirmations, and all with the same
guarantee: **only the downloaded files are removed — never a song from your library, or from
any pocket, playlist, or set list.** Anything you delete can simply be burned again later.

- **Delete by artist…** — every burned artist with song count and size; tap one to clear
  their downloads.
- **Delete by collection…** — your pockets, playlists, and set lists that have burned music,
  each with a burned-song count and size; tap one to clear those songs' downloads (the
  collection itself is untouched).
- **Delete all burnt music** — the sweep: audio, cuts, stems, beat grids, sidecars, gone.

A matching **Delete session recordings** clears every captured take's audio while keeping
each session's played-tracks log and timeline (a recording in progress is never touched) —
and the Sessions screen deletes **individual takes** (§58) when you only want one gone.

**The soft cap — storage that manages itself, only if you ask.** By default **no cap is
set, and the app never deletes music on its own** — storage is yours to manage with the
tools above. Tap **Set a soft cap…** and the cap starts at your current footprint (so
nothing becomes instantly evictable), adjustable by the GB. With a cap set, **once a day**
— in the background on iPhone/iPad, or when the app comes forward — the app prunes burnt
music down under the cap, **least-recently-played first**: the records you haven't touched
in months go before anything you played last night, and whatever's actually loaded on a
deck or playing right now is never touched. A **Prune now** button runs the same pass on
demand, and **Remove cap** returns the app to fully-manual storage. (To know what
"least-recently-played" means, the app now quietly keeps per-song play counts and
last-played times on-device — every play surface counts: rows, set lists, and the Mix
decks.)

Deletes here are safe by design around **your own folders**: if you've pointed burns or
recordings at a folder of your own, the app only ever removes files **it** wrote there —
your other audio and subfolders are never counted, never touched. And if a burn lives on a
drive that isn't plugged in right now, the app skips it rather than forgetting about it.

**User story:** "Show me what PocketDJ is costing my phone, let me clear an artist I'm done
with or a set I've played out — without touching my library — and if I give it a budget,
keep me under it by tossing what I never play."
