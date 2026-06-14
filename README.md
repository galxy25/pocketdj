# PocketDJ

**Portable, Personal, Musical Performance Playlists Producer** — an offline-first
app that *puts a DJ in your pocket*.

PocketDJ turns your music collection into one browsable, filterable, *navigable*
library that runs anywhere — phone, tablet, or desktop, online or off. This
iteration ships the foundation: the first **data source** type — **analog** (the
vinyl you've recorded) — its **indexer**, full **audio analysis** (BPM, musical
key, and Camelot code per track), and a **browser** fronted by an explorable
**star map** you can group by **genre, tempo, or harmonic key**.

> **A picture tour:** see the **[Product Storybook](docs/STORYBOOK.md)** — a
> screen-by-screen walkthrough with real screenshots of every view and state.

## Open it

PocketDJ is a live, installable web app. Open it in any modern browser:

- **dev:** https://djictbz9w796r.cloudfront.net
- **prod:** https://d2p4cubg6se03u.cloudfront.net

It loads with a real catalog already on board — **1,361 albums / ~12,800 songs**
of recorded vinyl, every album matched and mood-tagged — so there's something to
explore the moment it opens; no sign-in, no setup.

> **Install it.** Use your browser's **Add to Home Screen / Install app** prompt.
> PocketDJ is a full **PWA**: it runs full-screen like a native app and works
> **offline** once installed (it's served over HTTPS so the offline service worker
> can register).

### Works offline — and stays that way

PocketDJ is **offline-first**. The catalog (albums + songs) lives in your device's
local database, and every **cover thumbnail is cached locally** the first time it
loads, so the whole library renders with art even on a plane. Cached covers are
**durable across app and phone restarts** — PocketDJ asks the browser for
*persistent storage* so the blobs aren't evicted under pressure. Covers fill in
**progressively**: the app is interactive immediately and each thumbnail pops in as
it finishes caching in the background, rather than blocking on a wall of downloads.

## The star map (the default view)

Your collection is a night sky you can regroup three ways with the **Genre / BPM /
Key** toggle:

- **Genre.** The default. On a phone the map is a **scrolling grid of constellation
  cards** — each genre is a big title, an album count, and a **mosaic of ~16 covers**
  from that genre. **Tap a card to drill in** to its **sub-genres**, where every
  star is a real, clickable **album** showing its cover; **"← All genres"** zooms
  back out. (On desktop the genre map is the full pan/zoom night sky — **pinch-zoom**,
  **wheel-zoom**, and **drag-to-pan** all work.)
- **BPM.** Regroups the collection into **tempo bands** (each card a BPM range with a
  metronome). Tap a band to jump to those songs — the answer to *"what's around 120
  BPM?"* when you're beat-matching.
- **Key.** Regroups by **musical key**, each card **tinted by its Camelot color** so
  harmonically-adjacent (mixable) keys read alike; a **Camelot / Musical** sub-toggle
  switches the notation. This is the harmonic-mixing view.

**The solar system.** Tap any album and it blooms into a **solar system**: the cover
becomes the sun and each song **orbits** it as a planet (size by length, color hints
at mood/explicit). **Tap the sun** for the album's audio analysis; **tap a planet**
for a song's details; **☰ Browser** jumps to the album's track table.

## Browse, filter, sort, edit

Switch to the **Browser** for a spreadsheet-style view of the same data:

- **Pick a source** (or **All**) and toggle between **Albums** (a cover grid) and
  **Songs** (a dense list showing each track's **BPM / key / Camelot**). Both are
  virtualized, so they stay smooth across the whole catalog.
- **Filter** any field with **is / is-not / in-list / between** — *between* works
  on numbers like **year**, **BPM**, and **track length**; sentiment keywords
  filter by set-intersection.
- **Sort** by any sortable field, and **edit any field** to fix or enrich the
  metadata the indexer found (the **Key** and **Camelot** fields are dropdowns of
  valid values, kept in sync).

### Single-album view

Tap an album card to open its **track table**: every track with its **BPM, key, and
Camelot** code, an **album audio-analysis** footer, and quick buttons to its
**◎ Solar** system, **✎ Edit album info**, and **✎ Edit audio analysis**. **← Back**
returns to the browser **with your filters and sort preserved**.

## "Plug in" your analog records

PocketDJ can't *play* a vinyl record through your phone — so analog tracks carry
a **"⏚ plug in"** badge. Tap it and PocketDJ tells you where the record physically
lives (crate/location, disc, side/track). The intended setup is a **2-channel
mixer**: PocketDJ on channel 1 as the brain of your set, your turntable on channel
2 — **fade to channel 2** to drop the needle, then fade back. PocketDJ plans and
navigates; your decks do the playing.

## Take it with you

Everything lives in your device's local storage — no account, no server. **Export**
your whole library (data **plus** cover art) to a single `.zip`, move it to another
device, **Import** it, and it all works **offline instantly** (the art travels with
the data, so a fresh device needs zero network). The same **Import** button also
accepts a raw `index.json` straight from the indexer.

## Build your own index from your records

The bundled catalog is one example; you can index your *own* vinyl. The **analog
indexer** reads a plain text list of your recordings (filenames of the form
`ArtistNameAlbumNameRaw.<ext>`) and looks each one up online to build the index of
albums and songs — artist, title, cover, genre, year, country, tracklist, length,
explicit flag, lyrics, and mood/sentiment keywords. A separate **audio stage**
analyzes the actual recordings to fill in **BPM, musical key, Camelot code, and
per-segment timestamps**; anything it can't determine stays blank and is editable
in the app. See
[`.claude/skills/analog-indexer/SKILL.md`](.claude/skills/analog-indexer/SKILL.md).

## Privacy

PocketDJ is local-first. Your library lives in your browser's storage on your
device; nothing is uploaded. The only network use is fetching public metadata and
cover art when an index is built or first imported. Your exported `.zip` is yours
to move around.

---

A full screen-by-screen tour with screenshots: **[Product Storybook](docs/STORYBOOK.md)**.

Developers: see [Development.md](Development.md).
