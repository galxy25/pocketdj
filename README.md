# PocketDJ

**Portable, Personal, Musical Performance Playlists Producer** — an offline-first
app that *puts a DJ in your pocket*.

PocketDJ organizes your whole music world — across vinyl, CDs, local files, cloud
storage, and streaming — into one browsable, filterable, performable library, and
runs anywhere: phone, tablet, or desktop, online or off.

> This iteration ships the foundation: the first **data source** type — **analog**
> (vinyl you've recorded) — its **indexer**, and a **browser** with a **star-map**
> visualization. Playback, mixing, and other source types come next.

---

## What it does today

- **Data sources.** Your library is organized into sources. The first is **analog**:
  vinyl records you've recorded. (Digital files, S3, and streaming are on the roadmap.)
- **A real index of your records.** The analog *indexer* turns a list of your vinyl
  recordings into an index of **albums** and **songs** with artist, title, cover art,
  genre, year, country, tracklist, length, explicit flags, lyrics, and AI-generated
  **mood/sentiment keywords**.
- **Browse, filter, sort, edit.** View albums or songs, filter on any field with
  **is / is-not / in-list / between** (between works on numbers like year and track
  length), sort, and **edit any field** inline to fix or enrich metadata.
- **Star-map view (the default).** Your collection as a night sky: every **star is an
  album cover**, every **constellation is a genre**, height is the **year**, and each
  constellation has its own unique shape. **Tap a star** and the album blooms into a
  **solar system** — its songs orbit the cover like planets.
- **Offline-first & portable.** Everything lives in your device's local storage. No
  account, no server. **Export** your whole library (data + cover art) to a single
  `.zip`, move it to another device, **import**, and it all works offline instantly.
- **Installable PWA.** Add it to your home screen / desktop; it runs full-screen and
  offline like a native app.

## "Plug in" your analog records

PocketDJ can't *play* a vinyl record through your phone — so analog tracks show a
**"⏚ plug in"** badge. Tap it and PocketDJ tells you where to find the record
(crate, disc, side). The intended setup: a 2-channel mixer with PocketDJ on
channel 1 and your turntable on channel 2 — **fade to channel 2** to drop the
needle, then back. PocketDJ is the brain of the set; your decks are the hands.

## Getting started

1. **Open the app** (`npm run dev`, then visit the local URL — or your deployed
   PocketDJ URL). Install it from your browser's "Install app" prompt for the full
   offline PWA experience.
2. **Get some music in.** Either:
   - **Load demo data** — the *Load demo data* button fills the library with a large
     sample so you can explore immediately, or
   - **Import** an index produced by the analog indexer (`index-out/index.json`) or a
     previously exported `.zip` via the **Import…** button.
3. **Explore.** Switch between **Star Map** and **Browser** in the top bar. In the
   Browser, pick a **source** (or *All*), toggle **Albums / Songs**, add **filters**,
   **sort**, and **edit** anything. In the Star Map, click a star to open its solar
   system.
4. **Take it with you.** Hit **Export** to download your library as a `.zip`. On
   another device, open PocketDJ and **Import** it — fully offline.

## Building your own index from your records

The analog indexer is a tool that reads a simple text list of your vinyl recordings
(named `ArtistNameAlbumNameRaw.<ext>`) and looks each one up to build the index. See
[`.claude/skills/analog-indexer/SKILL.md`](.claude/skills/analog-indexer/SKILL.md)
for how to run it. It fills everything findable online; things that need the actual
audio file (BPM, musical key, per-track timestamps) are left blank for now and you
can fill them in by editing.

## Privacy

PocketDJ is local-first. Your library lives in your browser's storage on your device.
Nothing is uploaded anywhere — the only network use is fetching public metadata/cover
art when you build or import an index. Your exported `.zip` is yours to move around.

---

Developers: see [Development.md](Development.md).
