# PocketDJ

**Portable, Personal, Musical Performance Playlists Producer** — an offline-first
app that *puts a DJ in your pocket*.

PocketDJ turns your music collection into one browsable, filterable, *navigable*
library that runs anywhere — phone, tablet, or desktop, online or off. This
iteration ships the foundation: the first **data source** type — **analog** (the
vinyl you've recorded) — its **indexer**, and a **browser** fronted by an
explorable **two-tier genre star map**.

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

## The star map (the default view)

Your collection is a night sky, and it's explorable in two tiers:

- **Tier 1 — genre categories.** The map opens on ~14 top-level genre
  **constellations** (hip-hop, rock, jazz, electronic, soul, disco, country,
  classical, world… plus an **Other** catch-all for the unlabeled). Each
  constellation is a hazy, glowing cluster; the album stars inside it are dimmed.
  There's no slider or menu — exploration is by **clicking**.
- **Tier 2 — sub-genres.** **Click a constellation** to drill in. It expands into
  that category's **sub-genres**, and now every star is a real, clickable
  **album** — labeled with its name and showing its **cover art**. Height encodes
  the **year** (newer = higher). Hit **"← All genres"** to zoom back out.
- **The solar system.** **Click an album star** and it blooms into a **solar
  system**: the cover becomes the sun and each song **orbits** it as a planet
  (orbit by track number, size by length, color hints at mood/explicit). Click a
  planet for the song's details.

Move around freely — **pinch-zoom**, **scroll/wheel-zoom**, and **drag-to-pan**
all work, on touch and desktop.

## Browse, filter, sort, edit

Switch to the **Browser** for a spreadsheet-style view of the same data:

- **Pick a source** (or **All**) and toggle between **Albums** and **Songs**
  (both grids are virtualized, so they stay smooth across the whole catalog).
- **Filter** any field with **is / is-not / in-list / between** — *between* works
  on numbers like **year** and **track length**; sentiment keywords filter by
  set-intersection.
- **Sort** by any sortable field, and **edit any field inline** to fix or enrich
  the metadata the indexer found.

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
explicit flag, lyrics, and mood/sentiment keywords. Things that need the actual
audio file (BPM, musical key, per-track timestamps) are left blank for now; you
can fill those in by editing. See
[`.claude/skills/analog-indexer/SKILL.md`](.claude/skills/analog-indexer/SKILL.md).

## Privacy

PocketDJ is local-first. Your library lives in your browser's storage on your
device; nothing is uploaded. The only network use is fetching public metadata and
cover art when an index is built or first imported. Your exported `.zip` is yours
to move around.

---

Developers: see [Development.md](Development.md).
