# PocketDJ

**Portable, Personal, Musical Performance Playlists Producer** — an offline-first
app that *puts a DJ in your pocket*.

PocketDJ turns your music collection into one browsable, filterable, *playable*
library — and then lets you **perform** with it: rip or stream any track on
demand, take a whole set offline, and **mix two decks** with tempo-sync, effects,
and per-stem control. It runs anywhere — phone, tablet, or desktop, online or off.

It comes in two flavors that share **one catalog**:

- a **web app (PWA)** — the offline-first crate browser and star-map explorer,
  installable on any device;
- a **native app** (iPhone · iPad · Mac) — everything the web app does **plus**
  the full performance + DJ engine: rip-on-demand, live streaming, offline
  "burns", the two-deck **Mix** console, and **stems**.

> **A picture tour:** see the **[Product Storybook](docs/STORYBOOK.md)** — a
> screen-by-screen walkthrough with real screenshots of every view and state. For
> the how-and-why, read the **[Architecture Book](docs/ARCHITECTURE.md)**.

## Open it

### Web app

PocketDJ is a live, installable web app. Open it in any modern browser:

- **dev:** https://djictbz9w796r.cloudfront.net
- **prod:** https://d2p4cubg6se03u.cloudfront.net

It loads with a real catalog already on board — **1,361 albums / ~12,800 songs**
of recorded vinyl, every album matched and mood-tagged — so there's something to
explore the moment it opens; no sign-in, no setup.

> **Install it.** Use your browser's **Add to Home Screen / Install app** prompt.
> PocketDJ is a full **PWA**: it runs full-screen like a native app and works
> **offline** once installed. The catalog and every cover thumbnail are cached in
> your device's local storage (with *persistent storage* requested so they aren't
> evicted), and the library renders with art even on a plane — covers fill in
> **progressively** so the app is interactive immediately.

### Native app (iPhone · iPad · Mac)

The native app under [`apple/`](apple/) is a single universal **SwiftUI** build
that runs on iPhone, iPad, and Mac, distributed via **TestFlight**. It reads the
same catalog and adds the layers that make the crate *audible* and *performable*:
rip-on-demand, streaming, offline burns, the **Mix** DJ console, and stems (see
below). Developers: [`apple/README.md`](apple/README.md) and
[Development.md](Development.md).

## The crate — browse, explore, filter, edit

### The star map (the default view)

Your collection is a night sky you can regroup three ways with the **Genre / BPM /
Key** toggle:

- **Genre.** The default. On a phone, a **scrolling grid of constellation cards** —
  each genre a big title, an album count, and a **mosaic of covers**; **tap to drill
  in** to its sub-genres, where every star is a real, clickable **album**. (On
  desktop it's the full pan/zoom night sky — pinch, wheel, and drag all work.)
- **BPM.** Regroups into **tempo bands** — the answer to *"what's around 120 BPM?"*
  when you're beat-matching.
- **Key.** Regroups by **musical key**, each card **tinted by its Camelot color** so
  harmonically-adjacent (mixable) keys read alike; a **Camelot / Musical** sub-toggle
  switches the notation.

**The solar system.** Tap any album and it blooms into a **solar system**: the cover
becomes the sun and each song **orbits** it as a planet. Tap the sun for the album's
audio analysis, a planet for a song's details.

### Browse, filter, sort, edit

Switch to the **Browser** for a spreadsheet-style view: pick a **source** (or **All**),
toggle **Albums** ↔ **Songs**, and **filter** any field with **is / is-not / in-list /
between** (*between* works on year, BPM, and length; you can also filter by **genre**
and by **playlist / pocket membership**). **Sort** by any field, and **edit** any
field to fix or enrich the metadata the indexer found. Both views are virtualized, so
they stay smooth across the whole catalog. An optional **online search** mode queries
a server-side index (with server-side sort + load-more paging) when you want results
beyond what's on the device.

## Make it audible — rip, stream, burn, offline

PocketDJ can plan a set from analog records *and* play digital ones — and either
way, take the whole thing offline.

- **"⏚ plug in" analog.** PocketDJ can't spin a vinyl record through your phone, so
  analog tracks carry a **plug-in badge** that tells you where the record physically
  lives (crate, disc, side/track) for a 2-channel-mixer setup — *or* you can rip it.
- **Rip on demand.** Tap **▶** on any song and, on a cache miss, the app asks your
  **rip server** (a small service on your iMac, reachable over Tailscale) to **rip**
  it — analog from a local recording, or **Apple Music** captured in real time — then
  **stream it back**. It even **plays while it rips** via a live **HLS** stream
  (● LIVE) and uploads a durable, seekable **mp3** (plus BPM/key analysis and a
  clickable **waveform**) to a cache so every later play is instant, from anywhere.
- **Stream.** Catalog songs matched to **Apple Music** stream directly from your
  subscription; **⤓ Download** saves any track to a location you choose.
- **Discover & add.** Search the **Apple Music catalog** by **song _or_ album** and
  **＋ Add** the result into your crate. Adding a song rips just that track; adding an
  **album** fans out a **per-track rip** of every song (no Apple Music subscription
  needed — the rip server expands the album's tracklist itself) and materializes a
  provisional album that the real indexed album later supersedes by shared catalog id.
- **Burn it offline.** **Burn** a song, a setlist, or a whole collection to a
  **folder you choose** (or app storage) for fully-offline playback — background
  downloads survive app suspension, and the burn includes per-song cuts **and the
  stems**, so a burned collection can be **played _and_ mixed with no network**.

## Perform — pockets, playlists, setlists

PocketDJ is built to *perform* a crate, not just browse it:

- **Pockets** are collections of music (a DAG, so a pocket can contain pockets).
- **Playlists** are templates — ordered sequences you arrange.
- **Setlists** are frozen performances: tap **▶ Play** on a playlist and PocketDJ
  *realizes* it into a setlist you can run start-to-finish, with a **persistent Now
  Playing** player that follows you across the app, shuffle, play modes, folders, and
  per-item notes. Any collection can be **Ripped**, **Burned**, or **Stemified** in
  one action.

The **Playlists screen** splits into **Yours** and **Shared** tabs — your own
collections versus the ones mirrored from your sources' playlists, where each source
**group collapses and remembers** its open/closed state. **Sort** either tab by
**Recently played**, **A–Z**, or **Last updated** (your choice is remembered); playing
a saved setlist also stamps its **parent** playlist's "recently played", and that
recently-played history rides your **per-profile** iCloud collection document so it
follows you across devices.

- **♥ Favorite** any song, and the heart is everywhere the music is — the in-app
  **Now Playing** card, the **lock screen / Control Center** (a like-style toggle), the
  **Now Playing widget**, and **CarPlay**. Favorites are per-profile and, when you're
  the owner, sync two-way with your Apple Music library.

## Mix — two decks, in your pocket

The native app's **Mix** tab is a real two-deck DJ console driven by a first-party
audio engine (no third-party SDK):

- **Two decks**, each with **tempo** (time-stretch, pitch preserved), **pitch** shift
  (tempo preserved), sample-accurate **seek**, a **2×2 effects grid** (compressor ·
  reverb · flanger · filter, each with a continuous **strength**), and a **volume**
  trim. One equal-power **crossfader** spans both, and one master **Play/Pause** runs
  the pair.
- **Beat-matching.** Make one deck the **Lead** (★); the other's **Sync** matches its
  tempo to the lead's effective BPM and best-effort aligns the downbeats — preferring
  each track's **measured beat grid** over the catalog BPM.
- **Auto-Mix (auto-DJ).** Flip to **Auto**, pick a collection, and PocketDJ mixes it
  end-to-end across the two decks with timed crossfades, loading the next track ahead.

**Mix from Now Playing.** When a mixable **local** track is playing (and no full Mix
session is running), the **Now Playing** card reveals a **mini mixer** — PocketDJ
**swaps its plain player for the Mix DSP engine on your first touch**, giving you
**stems, effects, tempo, pitch, and gain** for the current track without leaving the
player. It resets for each new song.

### Stems

Songs can be separated into four **stems** — **vocals · drums · bass · other**
(Demucs) — and PocketDJ lets you play with them:

- **Audition** them from **song detail**: tap the stem glyph and a panel slides out
  that **burns the stems locally** then plays all four in perfect sync, with **solo**,
  **mute**, and **Play All**.
- **Mix** with them: load a stemmed track onto a deck and flip **stem mode** for a
  colored **2×2 stem grid** (vocals · drums · bass · other). The stems play **through
  the deck's effects and crossfader**; **tap** a pad to mute it, **long-press /
  right-click** for its volume.

Stems are created server-side (a **Stemify** action) and **burned locally** for
playback, so stem mixing — like everything else — works fully offline.

## Produce — the Studio

The native app's **Producer** tab is a small studio (samples, beat-synced loops, a
16-step sequencer, MIDI instruments, cue points) plus the **Demux** workbench. Two
things you can do there:

- **Extract an instrumental.** In **Demux**, turn any track into a playable
  instrumental — either a **beat-quantized chord comping** (chords played in time on
  the song's grid) or an **on-device true-melody** line (pitch-tracked note-for-note),
  with a **long-press / right-click** to switch between them. Its **follow-score**
  scrolls in sync right alongside the drum pattern.
- **Organize your samples.** The **Samples** view supports **folders** — create,
  rename, and delete them, and **move** samples in (an always-present *Unfiled*
  section holds the rest).

## Take it with you

Everything in the web app lives in your device's local storage — no account, no
server. **Export** your whole library (data **plus** cover art) to a single `.zip`,
move it to another device, **Import** it, and it works **offline instantly**.

## Build your own index from your records

The bundled catalog is one example; you can index your *own* music. The **analog
indexer** reads a list of recordings (`ArtistNameAlbumNameRaw.<ext>`) and looks each
one up online to build the catalog — artist, title, cover, genre, year, country,
tracklist, length, explicit flag, lyrics, and mood/sentiment keywords. Separate
stages analyze the actual audio to fill in **BPM, musical key, Camelot code,
per-segment timestamps**, a **beat grid** (downbeats, for sync), and **stems**;
**digital** libraries are imported straight from an **Apple Music** (iTunes)
`Library.xml`, and loose **raw audio files** ("My Digital") are ingested by *staging*
the audio to the cloud — the iMac only transcodes and uploads, and the **cloud workers**
run the BPM / key / beat-grid / waveform analysis, so digital ingest never needs a local
audio toolchain. Anything a stage can't determine stays blank and is editable in the
app. See [`.claude/skills/analog-indexer/SKILL.md`](.claude/skills/analog-indexer/SKILL.md).

## Privacy

PocketDJ is local-first. Your library lives on your device; the catalog itself is
never uploaded. Network use is your own: fetching public metadata and cover art when
an index is built, talking to **your** rip server, and streaming from **your** linked
accounts. Ripped/streamed audio is cached to storage **you** control, and your
exported `.zip` is yours to move around.

---

A full screen-by-screen tour with screenshots: **[Product Storybook](docs/STORYBOOK.md)**.
How it all fits together: **[Architecture Book](docs/ARCHITECTURE.md)**.
Developers: **[Development.md](Development.md)** · **[apple/README.md](apple/README.md)**.
