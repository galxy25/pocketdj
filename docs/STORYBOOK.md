# PocketDJ — Product Storybook

**PocketDJ** "puts a DJ in your pocket": it turns a personal music collection — a
digitized **vinyl** crate (1,361 albums / 12,525 songs) alongside an **Apple Music**
library — into something you can *explore*, *perform from*, and *mix* on a phone, iPad
or Mac, even with no signal. Every album and song is enriched with metadata, mood
keywords, and **audio analysis** (BPM, musical key, Camelot code); cover art and burned
audio are cached locally so the app is fully usable offline and durable across restarts.

This is the **outside-in, customer/product** view — what the DJ *sees and does*,
screen by screen. Its inside-out complement is the
[**Architecture Book**](./ARCHITECTURE.md), which asks *"what are the moving parts, and
how does a byte get from a vinyl rip on the iMac to a planet orbiting an album on a
phone?"* Where a capability shows up in both, each chapter links across to the other.

The storybook is organized by **capability**, not by release date — one chapter per
coherent slice of the product, mirroring the seven architecture pillars. Web
screenshots are from the real local app at mobile width (402×874) unless labeled
*desktop*; native-only surfaces (Mix, the Studio, CarPlay, and most transport/offline
features) are described in prose, since screenshots aren't captured yet.

---

## The journey — how the chapters compose

```
   explore the crate ──▶ shape a set ──▶ make it audible ──▶ mix it ──▶ make your own
  ┌────────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────┐  ┌────────────┐
  │ Explore &      │  │ Pockets ·    │  │ Play · Rip · │  │ Mix &  │  │ The Studio │
  │ Discover       │─▶│ Playlists ·  │─▶│ Burn         │─▶│ Stems  │  │ (samples,  │
  │ star map ·     │  │ Setlists     │  │ rip-on-demand│  │ two    │  │ loops,     │
  │ browser · edit │  │ realize a    │  │ · offline    │  │ decks ·│  │ sequencer, │
  │ · history      │  │ performance  │  │ burns        │  │ stems  │  │ instruments)│
  └────────────────┘  └──────────────┘  └──────────────┘  └────────┘  └────────────┘
                                                                 │
    Native & System Integration ── recognizer · Siri/Shortcuts · CarPlay · Jukebox Hero · Settings
```

The top row is the DJ's path: **explore** the collection, **shape** it into a set,
make that set **audible** anywhere, **mix** it live, and **make your own** material to
drop into it. Underneath sits **Native & System Integration** — the places PocketDJ
meets the phone and the operating system.

---

## The chapters

| Chapter | Pillar it mirrors | What you'll find |
|---|---|---|
| [**Explore the Crate**](./storybook/explore-and-discover.md) | Catalog · Search & Discovery | The two lenses on your catalog — the spatial **star map** (genre / BPM / key) and the filterable **browser** — plus the per-album **solar system**, the single-album track table, the in-place **edit** modals, **browse by artist**, **play history**, and multiple sources + **online search**. |
| [**Perform From the Crate**](./storybook/perform-pockets-playlists-setlists.md) | Performance Engine (producer) | The three performance nouns — **Pockets**, **Playlists** (templates of sequences), and **Setlists** (the realized, frozen take) — the shared **＋ Add to…** picker, folders, Play / Shuffle, and tracklist export. |
| [**Play, Rip & Burn**](./storybook/play-rip-burn.md) | Playback & Rip-on-Demand | Making the catalog audible: the inline / mini **player**, **rip-on-demand** with live streaming, whole-set **Rip** and **Burn** for offline, the **device/cloud** toggle, the length-aware **transport**, the offline-first catalog, the home **Now Playing** deck, and **durable playback sessions** (force-quit or restart — reopen and the set is cued right where you left it). |
| [**Mix & Stems**](./storybook/mix-and-stems.md) | Performance Engine (Mix) | The two-deck **DJ console** — per-deck controls, effects, crossfader, beat-match **Sync**, the **Auto-Mix** auto-DJ with FX/Mix glide — plus **stems** (audition, mix decks, offline burn) and session recording + replay. |
| [**The Studio**](./storybook/studio.md) | Performance Engine (Studio) | Make your own material: **samples** (from a track, the mic, a file, or an external input), **loops**, a 16-step **sequencer**, seven **virtual instruments** with sheet music, **instrumentals**, **cue points**, and how your creations live inside collections. |
| [**Native & System Integration**](./storybook/native-and-system-integration.md) | Distribution & Clients | Where PocketDJ meets the OS: the **"?♪?" recognizer**, **streaming-account** linking, **Siri / Shortcuts / Spotlight**, **CarPlay**, the **Now Playing widgets**, **Jukebox Hero** (a QR-code request line for the room), and the Settings utilities — the storage manager and remote-debug capture. |

---

## What's native vs. cross-client

PocketDJ ships as an offline-first **web PWA** and a **native SwiftUI app** (iPhone /
iPad / Mac), reading the same catalog, rips, and collections. The Explore and Perform
surfaces exist on both; the modern DJ features — the **Mix** engine, **stems**, the
**Studio**, **CarPlay**, App Intents, and the offline burn/transport layer — live in the
native app. Each section notes when a surface is native-only.
