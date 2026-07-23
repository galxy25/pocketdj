# Explore the Crate — Catalog, Star Map & Discovery

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). This chapter is the
> **explore & maintain** surface: the two lenses on your catalog — a spatial **star
> map** for discovery and a precise, **filterable browser** for look-up — joined by
> a per-album **solar-system** view and **single-album** track table for the
> close-up work, plus the in-place **editors** that keep the metadata honest, and
> the **history** of what you've played. The complement, from the systems side, is
> [Catalog & Data Model](../architecture/03-catalog-and-data-model.md) and
> [Search & Discovery](../architecture/06-search-and-discovery.md).

**The user story.** *As a DJ / crate-digger, I want to browse my whole collection on
my phone — by genre, by tempo, or by harmonic key — find the right record fast, see
each track's BPM/key so I can beat- and key-match, drill into a single album, and fix
up any wrong metadata, all without a network connection.* PocketDJ serves that with
two complementary takes on the same data: the visual star map and the precise browser.

The screens below follow a natural journey: **discover** (star map → solar system),
**look up** (browser → single album), then **maintain** (edit modals, settings). Web
screenshots are from the real local app at mobile width (402×874) unless labeled
*desktop*; the native-only surfaces (artist discography, Discover, play history, the
Browse filter sheet) are described in prose.

## Star map — genre mode (mobile grid)

![Star map, genre grid](01-starmap-genre-mobile.png)

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
- **A constellation card** — tap to *drill into* that genre's sub-genres (see [Star map — drilled into a genre](#star-map--drilled-into-a-genre-sub-genres)).
- The grid free-scrolls to the rest of the genres below the fold.

**User story:** this is the **discovery** entry point — "show me my crate, grouped
the way a DJ thinks about it." Genre is the default mental model; the cover mosaic
makes each pile instantly recognizable.

---

## Star map — drilled into a genre (sub-genres)

![Genre drilled into sub-genres](02-starmap-genre-drilled-mobile.png)

Tapping a genre card drills in. The mode toggle **hides**, a breadcrumb
(**"OTHER · SUB-GENRES"**) appears, and a **"← All genres"** back button takes you
up a level. Inside the focused genre, albums are drawn as **clickable stars** in a
constellation scatter (each art-backed star shows a small cover and its album-name
caption); tapping a star opens that album's **solar system** ([Solar system view](#solar-system-view-mapid)).

**Affordances**
- **← All genres** — return to the genre grid ([Star map — genre mode](#star-map--genre-mode-mobile-grid)).
- **A star** — open `/map/:albumId`, the album's solar system.

**User story:** narrows discovery from "a genre" down to "the actual records in
it," keeping the spatial, browse-by-feel experience while getting you one tap from
any single album.

---

## Star map — BPM mode

![Star map, BPM grid](03-starmap-bpm-mobile.png)

The same collection, regrouped by **tempo**. Each card is a **BPM range** (30–40,
40–50, 50–60, 60–70 …) marked with a **metronome glyph** and the number of songs
in that band.

**Affordances**
- **BPM** is selected in the mode toggle.
- **A BPM card** — opens the browser pre-filtered to songs in that tempo band.

**User story:** direct support for **beat-matching** — "what have I got around 120
BPM?" is the core question when building a set, and this is the one-tap answer.

---

## Star map — Key mode (Camelot colors)

![Star map, key grid](04-starmap-key-mobile.png)

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

## Settings popout

![Settings modal](05-settings-modal-mobile.png)

Opened from the **⚙ gear**. Shows the catalog size (albums · songs) and the active
source, over the maintenance and backup actions.

**Affordances**
- **↻ Force refresh & re-pull catalog** — clears this device's cached app shell +
  data and re-pulls the latest catalog from the server (the fix for "I'm seeing
  old data or a stale layout"), while **preserving your pockets, playlists & set
  lists** — it re-pulls only the catalog. The button shows "Refreshing…" while it works.
- **⤓ Export all data / ⤒ Import data** — back up *everything* (catalog, art, pockets,
  playlists, set lists) to one file and restore it on another device or a fresh/offline
  install.
- **Data version + ⬆ Run migrations** — a versioned, non-destructive migration framework
  (baseline **v0**) that keeps your collections compatible across app updates.
- **⚠ Reset everything** — a separate, clearly-labeled nuclear wipe (collections included),
  behind a confirm.

**User story:** the offline cache is a feature, but occasionally you *want* the
newest catalog — this is the escape hatch that re-syncs without reinstalling, and the
one place to back up and restore your whole library.

---

## Solar system view (`/map/:id`)

![Solar system](06-solar-system-mobile.png)

A single album rendered as a **solar system**: the **album cover is the sun** at the
center and each **song is a planet** orbiting it. Planet *size* scales with track
length; planet *color* flags content (explicit tracks read red, tracks with mood
keywords use the secondary accent). Each planet is captioned with its song name.

**Affordances**
- **← Back** — return to the star map (or wherever you came from).
- **☰ Browser** — jump to this album's single-album track table ([Single-album view](#single-album-view-albumid)).
- **Tap the sun (cover)** — open the album **audio-tracks popup** ([Solar system — audio-tracks popup](#solar-system--audio-tracks-popup)).
- **Tap a planet** — open that song's read-only detail card (like [Song detail modal](#song-detail-modal)).

**User story:** a playful, at-a-glance close-up of one record — see its shape (how
many tracks, how long, how spicy) before committing, and pivot straight into the
precise views.

---

## Solar system — audio-tracks popup

![Audio tracks popup](07-solar-audio-popup-mobile.png)

Tapping the sun opens **"<album> — Audio"**: the album's **independent audio
segmentation** in a table of **# · Start–End · BPM · Key** (each key shown with its
Camelot tag, e.g. `7A`). The caption notes that this segmentation is detected from
the recording and *may differ from the metadata tracklist*, with the total
analyzed runtime.

**User story:** the ground-truth tempo/key data a DJ actually mixes on, surfaced
right where you're looking at the record. (The same table appears, editable, in [Single-album view](#single-album-view-albumid)
and [Edit audio-analysis modal](#edit-audio-analysis-modal).)

---

## Single-album view (`/album/:id`)

![Album track table](12-album-tracktable-mobile.png)

The precise per-album work surface: a **header** (cover, title, artist,
year · genre · track count) over a **track table**. Each row shows the track number,
title, **BPM**, **key**, and **Camelot** tag, plus a "plug in" affordance for the
physical/file pointer. A **"ALBUM AUDIO ANALYSIS"** footer repeats the
audio-segmentation table from [Solar system — audio-tracks popup](#solar-system--audio-tracks-popup).

**Affordances**
- **← Back** — returns to the browser **with your filters/sort preserved**.
- **The artist name** (in the header) — a **hotlink** to that artist's page (their whole
  discography); on native it opens the artist in the **Browser**, with the album left
  underneath so **← Back** returns you here.
- **◎ Solar** — open this album's solar system ([Solar system view](#solar-system-view-mapid)).
- **A track row** — open that song's detail card ([Song detail modal](#song-detail-modal)).
- **✎ Edit album info** — open the album editor ([Edit album modal](#edit-album-modal)).
- **✎ Edit audio analysis** (in the footer) — open the audio editor ([Edit audio-analysis modal](#edit-audio-analysis-modal)).

**User story:** the "I've found the record, now show me everything about it"
view — every track's mixable data in one scannable table, with edit hooks for
fixing anything wrong.

---

## Song detail modal

![Song detail modal](13-song-detail-modal-mobile.png)

Tapping a track row (here, or a planet in [Solar system view](#solar-system-view-mapid)) opens a **read-only** song card:
track #, artist, album, year, length, explicit flag, **BPM / Key / Camelot**
(or "— pending audio" when not yet analyzed), sentiment keyword tags, the physical
"plug in" pointer, and lyrics when found.

**Affordances**
- **✕ / Close** — dismiss (Escape or backdrop-tap also close).

**User story:** the full single-track read-out for when you need every detail of
one song without leaving the album.

---

## Browser — albums (mobile)

![Browser albums, mobile](08-browser-albums-mobile.png)

The look-up lens. A **responsive grid of album cards** (cover, title, artist,
year · genre · track count). Cards lazy-load their cached covers. Tapping a card
opens the single-album view ([Single-album view](#single-album-view-albumid)); each card has a **✎** edit shortcut.

**Affordances** (toolbar, fuller view in [Browser — filter & sort](#browser--filter--sort-desktop))
- **Source** selector, **Albums / Songs** type toggle, **Sort**, result count, and
  the import/export bar.
- **⚙** settings, **✦ Star Map / ☰ Browser** view switch (top bar).

**User story:** "I know roughly what I want — let me filter and sort to it,"
complementary to the spatial star map.

---

## Browser — songs (mobile)

![Browser songs, mobile](09-browser-songs-mobile.png)

Flipping the type toggle to **Songs** swaps the album grid for a **dense song
list**. Each row is track # · title · **BPM** · **key** · **Camelot** tag · "plug
in" · **✎**. The result count (here `12525 / 12525`) updates as you filter.

**Affordances**
- **Albums / Songs** toggle (Songs active).
- A **row** opens the song detail card ([Song detail modal](#song-detail-modal)); **✎** opens the song editor ([Edit song modal](#edit-song-modal)).

**User story:** the track-level look-up — scan, filter, and sort 12k songs by the
exact fields that matter for mixing.

---

## Browser — filter & sort (desktop)

![Browser filter, desktop](11-browser-filter-desktop.png)

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

## Browser — albums (desktop)

![Browser albums, desktop](10-browser-albums-desktop.png)

The same album browser at desktop width: a wider multi-column grid showing many
covers at once, for fast visual scanning on a laptop.

---

## Collection — the Map and List views

![Collection Map/List toggle](25-collection-map-list-toggle-mobile.png)

Star Map and Browser are unified into one **Collection** mode. A contextual **✦ Map / ☰
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

## Edit album modal

![Edit album modal](14-edit-album-modal-mobile.png)

Opened from **✎ Edit album info** ([Single-album view](#single-album-view-albumid)) or a card's **✎**. Edits the album's
metadata: **Artist, Title, Year**, a **Genre** combo (suggests the canonical
category names *and* accepts free text), a **Cover URL** field (paste a new cover
to re-fetch), **Country**, and **File type**.

**Affordances**
- **Cancel** / **Save** (Save persists to the local IndexedDB catalog).

**User story:** fix wrong enrichment in place — bad genre, missing year, or a
broken cover — without re-running the indexer.

---

## Edit audio-analysis modal

![Edit audio modal](15-edit-audio-modal-mobile.png)

Opened from **✎ Edit audio analysis** in the album footer ([Single-album view](#single-album-view-albumid)). One editable row
per detected audio segment: **Start / End** (m:ss), **BPM**, **Key**, and
**Camelot**. The **Key** and **Camelot** dropdowns are linked — picking one fills
the other from the Camelot↔key mapping — so the pair always stays consistent.

**Affordances**
- **Cancel** / **Save**.

**User story:** correct the auto-detected tempo/key when the analyzer got a track
wrong — critical, because the whole BPM/Key discovery flow trusts these numbers.

---

## Edit song modal

![Edit song modal](16-edit-song-modal-mobile.png)

The song editor (opened from a song row's **✎**). Edits **Artist, Title, Track #,
Year, Length, Explicit**, **sentiment keywords**, and the audio fields — with
**Key** and **Camelot** as **valid-value dropdowns** (the 24 musical keys / 24
Camelot codes, kept in sync). It also exposes a destructive **Delete track**
action ([Delete-track confirm](#delete-track-confirm)).

**Affordances**
- **Cancel** / **Save**, and **Delete track** (red).

**User story:** per-song corrections — fix a mistagged key, mark a track explicit,
or remove a track that doesn't belong.

---

## Delete-track confirm

![Delete track confirm](17-delete-track-confirm-mobile.png)

**Delete track** swaps the editor for a mobile-friendly confirm: *"Delete '<song>'
from the index? This can't be undone."* with a safe **Nope** and a red **Delete**.

**Affordances**
- **Nope** — back out (no change).
- **Delete** — remove the track from the local catalog.

**User story:** a deliberate two-step guard so a destructive edit can't happen by a
stray tap — important on a touch screen.

---

## Multiple sources & online search

PocketDJ isn't vinyl-only: it indexes **multiple data sources** into one catalog,
offers a **show/hide** pair of collection filters on the song list, and can search the
whole catalog **online**. The browser shots above show two sources side by side.

### A second source — Apple Music (Local)

![Multi-source selector](27-multi-source-selector-mobile.png)

Alongside the digitized vinyl crate, the app can index your **Apple Music library**
(from the macOS `Library.xml`) as a second, **digital** source — here **12,220
albums / 92,865 songs** next to vinyl's **1,361 / 12,525**. The **Sources** picker is
a multi-select: show **all**, **none**, or a **subset** (e.g. just vinyl, or just
Apple Music). Digital albums carry real genre/year/track metadata but no cover art
(the ♪ tile) — art is added only via a rip/burn. The selection **persists**, and the
star map, counts and browser all respect it. Items are kept distinct per source, so
the same album owned on vinyl *and* in Apple Music never collide.

### Settings ▸ Sources — load / remove sources

![Settings: Sources panel + Online search](28-settings-sources-mobile.png)

Apple Music is **opt-in**: a fresh device boots vinyl-only (fast), and you add the
library with **＋ Load Apple Music (Local)** in Settings ▸ Sources. The same
multi-select lives here too, plus a per-source **✕ remove** (which also drops that
source's imported playlists). Importing the library also **mirrors your iTunes
playlists** into app playlists. (This shot also shows the **Online search** panel —
see below.)

The mirrors track your Music library **faithfully overnight**: a playlist you create
or rework in Music shows up (or updates) in the catalog by the next morning even if
you were mid-edit at sync time — a playlist that's momentarily **empty stays listed as
empty instead of disappearing** — and albums you add are stream-ready the same night.
Music **videos** in your library are kept out (they never sneak in as bogus "songs").

### Show *and* hide — collection filters on the song list

![Show / hide collection filters](29-show-hide-filters-mobile.png)

The song list carries a **pair** of membership filters. **Hide added** drops songs
already placed in a collection; **Show added** keeps **only** songs that *are* in a
chosen playlist/pocket (or *any*). Both can be on at once — the browser **intersects**
them (e.g. "everything in *Peak Hour* that isn't already in *Saturday Set*"). The
dropdowns list your playlists + pockets, including the **imported iTunes** ones.

### Online search (OpenSearch) — opt-in ⚡

![Online search via OpenSearch](30-online-search-mobile.png)

A search box spans the catalog. **Offline** (the default) it filters the loaded set
by title/artist locally. Once you paste a **read-only search key/secret** into
**Settings ▸ Online search** ([Stream & download — rip on demand](play-rip-burn.md#stream--download--rip-on-demand)), an **⚡ Online** toggle appears: it queries
**OpenSearch Serverless** across **title, artist, album, lyrics and sentiment** over
the *entire* indexed catalog — here **80 of 470** matches for *"midnight"* in
**389 ms**, with explicit (**E**) and BPM/key badges intact. The browser signs each
request itself (SigV4) and reaches the collection same-origin via a CloudFront proxy,
so there's no separate server to run. The backing collection is **NextGen
scale-to-zero** — it costs **$0 while idle** and only adds a one-time **~15 s warm-up**
on the first search after a long pause. Settings ▸ Online search also shows the current
**search host** with an **editable override**, so the search backend can be moved (or
made private per-user) without shipping a new app.

Online results **page in as you scroll**: the first page loads on a query or filter
change, and reaching the bottom of the list **fetches and appends** the next page until
every match is loaded — with the results header showing the **real total** (e.g. *"470
songs"*, the full match count across the entire indexed catalog, not just the rows on
screen). The Browser's **Sort** (field + ↑/↓) drives the online search too: OpenSearch
sorts the *whole* result set server-side and pages come back already in order, so
sorting by BPM, key, genre, year, or title behaves the same offline or online.

---

## Browse by Artist — the whole discography, one tap

The Browser's top-level **Show** picker isn't just **Albums** and **Songs** — a third segment, **Artists** (⌘3), lists one row per distinct album-artist: name, an "N albums · M songs" count, and a representative cover pulled from their catalog. This list is always computed on-device, even when online search is active, since OpenSearch only indexes albums and songs. Tapping an artist opens an **Artist detail** screen — a header with the artist's name, the same "N albums · M songs" line, and two prominent buttons, **▶ Play all** and **🔀 Shuffle all**, that queue the artist's entire discography — every track across every one of their albums — straight into the reusable Now Playing set, either in catalog order or shuffled. Below the header, each album lists as a normal row that opens straight into that album's own detail screen. The feature is cross-platform on iPhone, iPad, and Mac, and the same on-device Artists list powers the **Artists** tab in CarPlay.

**Affordances**
- **Artists segment (⌘3)** — a third Browser kind alongside Albums and Songs, always on-device.
- **Artist row** — name, "N albums · M songs" count, representative cover.
- **▶ Play all** — queues the artist's whole discography, in catalog order, into Now Playing.
- **🔀 Shuffle all** — same discography, shuffled.
- **Album row (in Artist detail)** — opens the normal album detail screen.

**User story:** "I want everything this artist ever gave me — one tap and it's all queued up, in order or shuffled, no hunting album by album."

---

## Discover — search all of Apple Music, ＋ Add it to your crate

The Show picker's **fourth** segment, **Discover**, turns the Browser outward: instead
of filtering what you own, it searches the **entire Apple Music catalog**. Type a title
into the shared search box — plus an optional **"Refine by artist"** field under the
tabs — and results arrive from **two sources merged**: MusicKit's full-catalog search
(when your Apple Music account is authorized) leads with its relevance ranking, and the
rip server's search proxy fills in, so every tester gets results even without a
subscription. A nested **Songs / Albums** sub-toggle flips between track hits and
whole-album hits (each entry always starts on Songs); the Discover tab itself is
remembered across launches like the other Show tabs.

Every result row's trailing action tells its state: **＋ Add** for something new, a
spinner with the live phase ("Queued," "Searching…," "Ripping…") while your copy is
being prepared, then **▶** — playable right in the results list through the standard
play path, with the same inline player strip the Browser rows get. An **album** ＋ Add
fans out per-track: the row counts **n/m** as each track's copy lands, settles to a
green **✓ Added** when all of them do, or an honest **n/m** partial marker when some
tracks couldn't be prepared (never an eternal spinner).

The ＋'s help wording is **capability-aware**, shared by the song and album rows so it
can't overstate: on iPhone/iPad with an authorized subscription it reads *"Save this
song/album to your Apple Music library and prepare your copy"*; on a Mac — which can't
write the Apple Music library — an album ＋ **opens the album in Music.app** instead
(and still prepares your copies), and a song ＋ simply *"Prepare your copy."*
Long-press (or right-click) a ready row to **Play Next / Play Last** into the running
Now Playing queue, or **Add to Catalog** immediately. Discover adds live as
**provisional** catalog entries — full citizens you can play, collect, and burn — and
when the same song or album later shows up in your synced library (matched by its
Apple Music id, which the indexer now stamps on **albums** as well as songs), the
provisional copy quietly folds away instead of duplicating what you own.

**Affordances**
- **Discover** — the fourth Show segment, alongside Albums / Songs / Artists.
- **Songs / Albums** sub-toggle + **Refine by artist** — scope and narrow the catalog search.
- **＋ Add** — save to your Apple Music library (where the device can) and prepare your
  own copy; album adds fan out per track (n/m → ✓ Added).
- **▶ on a ready row** — play immediately; the inline player appears under the row.
- **Long-press a ready row** — Play Next / Play Last / Add to Catalog.

**User story:** "I heard something that isn't in my crate yet — find it in the whole
Apple Music catalog, and one ＋ makes it mine: saved to my library, my own copy
prepared, playable right from the results."

---

## History — every play, timestamped

A **History** view is one shortcut away from anywhere in the app — **⌘H**, or the clock-with-arrow (⏱) icon — and opens onto two timelines behind a **Plays / Activity** segmented toggle. **Plays** is a scrollable timeline of every song you've played, wherever you played it: **Browser**, **Playlist**, **Pocket**, **Album**, **Set list**, **Mix**, **Artist** — one row per play event (an earlier "By song" grouping mode was retired; the timeline is the one read). Each row is the same song row you already know from the Browser, with a context line underneath — "Mix · Friday Night Mix · 2h ago," relative time and all. Play the same track twice within about 30 seconds — a restart, a seek back to the top — and it collapses to a single entry; that's one listen, not two.

The Plays timeline runs on the Browser's own **filter & sort** machinery, so every filter and sort you already trust — genre, BPM, key, source — works here too, plus two History-only additions: a **Last played** sort (the default, most recent first) and a **date-range filter** for things like "played between May and August." The log itself is durable and append-only, written straight through relaunches, and caps at 20,000 entries so it never grows unbounded. An empty state tells you which kind of empty you're looking at — "No plays yet" for a history with nothing in it, "No plays match your filters" when the log has entries but your filters have hidden all of them.

**Activity** is the collection side of the story: a plain newest-first feed of what you've *done* to your crate — "Added *song* to *playlist*," "Hearted *song*," "Removed heart from *song*," "Removed *song* from *pocket*" — each with its own glyph and a relative timestamp. Tapping an entry opens the song wherever it still resolves in the catalog. It's deliberately outside the filter/sort machinery (those are play concepts), so the sort and filter toolbar buttons hide while Activity is showing.

**Affordances**
- **⌘H / ⏱** — opens History from anywhere.
- **Plays / Activity** — song plays, or collection activity (adds, hearts, un-hearts, removals).
- **Last played sort** — most-recent-first, the Plays default.
- **Date-range filter** — narrow the Plays timeline to a window.

**User story:** "Show me everything I've actually played — across every crate and every surface — sorted by when, so I can find that one track I mixed in on Friday without remembering which pocket it lived in — and what I've been adding and hearting while I dig."

---

## ♥ Favorites — mark the ones you love

Every song row in the native app now carries a small **♥**, sitting just left of the ▶/⤓
transport. It's the *same* heart everywhere a song row appears: the **Browser**, inside a
**playlist**, **pocket** or **set list**, on the **History** timeline, and in an album's
**track table**. Tap it and it fills in; tap it again and it empties. Tapping the heart never
opens the song — it stays put and only toggles. The **song detail** page carries the same
control, larger, in its **Play** action row, so you can heart the track you're reading about
without going back to a list.

**Favorites are yours, and they follow you.** They live in your own profile and travel between
*your* devices through iCloud — heart something on the phone and it's hearted on the iPad and
the Mac. They never reach another DJ. A ♥ you put on a **vinyl** rip, a **My Digital** file, or
something you made in the **Studio** stays on your own devices entirely: those tracks have no
Apple Music identity, so there's nothing anywhere else to sync them to.

For the owner's install, a ♥ also travels **up to Apple Music** — and un-hearting there is
**not fully reversible**. That whole story, including exactly what survives an un-favorite,
lives in [Favorites and Apple Music — the two-way sync](native-and-system-integration.md#favorites-and-apple-music--the-two-way-sync).

**Filter by it.** The Browser's **Filter** sheet gains a **Favorites** section, right above
the collection-membership controls, with three choices:

- **Any** — no constraint (the default),
- **Favorites only** — show just the songs you've hearted,
- **Not favorited** — show everything you *haven't*, which is the "what's left to go
  through?" view.

It's a **Songs-mode** filter (albums and artists don't carry a ♥) and it's off the History
timeline. It reads the **current** state, so a song you hearted and later un-hearted counts as
"not favorited" — the filter is about where things stand now, not what you've ever done.
**Clear All** in the filter sheet releases it along with your other clauses, and the toolbar's
filter glyph reads as *on* while it's constraining — even when it's the only filter you have.

**Affordances**
- **♥ on any song row** — favorite / unfavorite in one tap, without opening the song.
- **♥ in the song detail Play row** — the same toggle as a primary action.
- **♥ in an album's track table** — heart a track while scanning the record.
- **Filter ▸ Favorites** — Any / Favorites only / Not favorited.

**User story:** "Let me flag the records I actually reach for as I dig — one tap, anywhere I
see a song — and then show me just those when I'm building a set, or just the ones I haven't
judged yet when I'm still digging."

---

## Browse — genre & collection-membership filters, per-clause remove

The native Browser's **Filter** sheet composes the same rich filtering as the web app (and a little more).

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

**Favorite filter (Songs mode).** A **Favorites** section sits just above the membership one —
**Any / Favorites only / Not favorited** — and stacks with everything else, so *"disco I've
hearted that isn't already in Saturday Set"* is one query ([♥ Favorites](#-favorites--mark-the-ones-you-love)).

**Per-clause remove.** Every filter clause has its **own remove** — a **trash** button (and
a left **swipe**) on the row — alongside the existing **Clear All**. So you can drop a single
clause without tearing down the whole query.

**User story:** "Filter by the genre buckets I think in, slice by what's already in my sets,
keep to the ones I've hearted, and peel off one filter at a time instead of starting over."

---

## Keyboard navigation (desktop)

On the Mac (and an iPad keyboard), the Browser is fully **keyboard-drivable**:

- **↑ / ↓** move a **focus cursor** that highlights a row — across the **song list**
  *and* the **album grid/list** (the album grid walks album order linearly). It works
  **live during search**: type a query, then arrow into the results.
- **⌥⌘P** plays (or pauses/resumes) the **focused song** (plain ⌘P belongs to the
  Performance tab).
- **Return** or **⌘O** **opens** the focused item — an album → its detail, a song →
  its song detail — the same destination a click reaches.

Other shortcuts round it out: **⌘1 / ⌘2 / ⌘3** Albums / Songs / Artists, **⌘L** focus
search, **⌘V** grid/list, **⌥⌘F** Filter, **⌥⌘S** Sort.

**User story:** "On a laptop I want to fly — Spotlight-style: type, arrow down,
hit Return to open or ⌥⌘P to play, hands never leaving the keyboard."
