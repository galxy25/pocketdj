# Perform From the Crate — Pockets, Playlists & Setlists

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). The Explore chapter is
> about *finding and maintaining* the crate; this one is about **performing from it**.
> Three nouns build a set:
>
> - A **Pocket** is a reusable, harmonically-coherent grouping of songs and albums that
>   can nest other pockets (a DAG) — think *"Classic Soul Anthems."*
> - A **Playlist** is a **template**: an ordered set of **sequences** ("chapters"), each
>   holding songs, albums, or pocket references and an optional **time budget**.
> - A **Setlist** is a **frozen instance**: hitting **▶ Play** *realizes* the template
>   into a concrete, ordered track list — expanding albums, **sampling** over-budget
>   pockets to fit their slot, and **autofilling** gaps with harmonic bridge tracks —
>   then persists it so you can read it off, export it, rip it, and burn it.
>
> The systems-side complement is
> [Performance Engine](../architecture/04-performance-engine.md).

## Pockets — list

![Pockets list](18-pockets-list-mobile.png)

The Pockets mode landing screen: a **New pocket** creator and a list of existing
pockets, each a card with a **kind badge** (`HARMONIC`), the name, and member
counts (*songs · albums · child pockets*).

**Affordances**
- **New pocket name… + Create** — make a pocket, then jump into it.
- **A pocket card** — open its detail ([Pocket — detail](#pocket--detail)).
- The new **bag** icon marks the Pockets tab; the **▶ play** icon marks Playlists.

**User story:** "keep a few reusable crates of records that mix well together, so I
can drop a whole vibe into any set."

---

## Pocket — detail

![Pocket detail](19-pocket-detail-mobile.png)

Inside a pocket: an editable **name**, an **⤓ Export**, a **Delete**, and the
**Members** list. **Export** writes a portable `.pocket.pocketdj.zip` (the pocket plus
any nested child pockets, DAG-expanded) that any client — browser or the native apps —
can import; ids are reminted on import so it never clobbers an existing pocket. Each
song is a **two-line row** — title + artist on top, then its **BPM** and
**Camelot key** badges (e.g. `57 BPM · 9A`) so the harmonic coherence of the pocket
is visible at a glance. A **Child pockets** section nests other pockets (cycle-
guarded). Tapping a song opens the same **song detail** popover used everywhere
else ([Setlist — tap a track for song detail](#setlist--tap-a-track-for-song-detail)).

**Affordances**
- **⤓ Export** — download the pocket (with its nested pockets) as a `.pocket.pocketdj.zip`.
- **Tap a song** — open its detail popover.
- **Remove** — drop a member.
- **Add child pocket** — nest another pocket (rejected if it would create a cycle).
- Members are added from anywhere via **＋ Add to…** ([Add to a pocket or playlist](#add-to-a-pocket-or-playlist)).

**User story:** curate the crate and *see the key/tempo spread* while you do it — a
pocket is only as good as how well its records mix.

---

## Add to a pocket or playlist

![Add-to-collection picker](20-add-to-collection-picker-mobile.png)

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

The picker surfaces your **last-used** playlist/pocket first (with a *last used* badge) and
defaults to the sequence you last added into — fewer taps when you're building a set fast.
On the native apps this has grown into a **Recent** section: the **last three** collections you
added to, most-recent first, each a one-tap re-add (a deleted collection simply drops out of the
row); tapping a playlist by name lands in its **default chapter**, with any extra chapters listed
beneath for when you want a specific one.

Every add is also **remembered as activity**: the native **History** screen carries a
**Plays | Activity** segmented control, and the **Activity** side is a reverse-chronological
timeline of how your crates were built — *"Added X to Y"*, *"Removed X from Y"*, plus hearts and
un-hearts — kept in its own append-only, device-local log, separate from the play history. Tap a
row to jump to the song.

Below your own collections the native picker adds a **"From your sources"** section listing the
playlists that came from Apple Music (and your other sources) — see
[Add a song to an Apple Music playlist](#add-a-song-to-an-apple-music-playlist--it-goes-upstream-too) for what happens when you tap one.

**User story:** wherever you find a record, you're one tap from filing it into a set
or a crate.

---

## Playlists — list

![Playlists list](21-playlists-list-mobile.png)

The Playlists mode landing: a **New playlist** creator and the list of playlist
**templates**, each showing its sequence and item counts.

**Affordances**
- **New playlist name… + Create** — start a template and open it.
- **A playlist card** — open its detail/editor ([Playlist — the template](#playlist--the-template-sequences)).

**User story:** "keep the sets I perform — Family BBQ, Sunday Brunch — as living
templates I can re-roll any time."

---

## Playlist — the template (sequences)

![Playlist detail / template](22-playlist-detail-mobile.png)

The template editor. The header has the editable **name**, the primary **▶ Play**
button, and **Delete**. Below are the **Sequences** (chapters): here *Warm-up
(pocket)* carries a **10:00 target** and holds the **Soul Anthems** pocket (10
items); *Closers (songs)* holds two hand-picked songs. Each item can be **moved**
between sequences or **removed**, and **＋ Add sequence** adds a chapter. At the
bottom, **Set lists** is the history of everything you've generated from this
template.

**Affordances**
- **▶ Play** — realize the template into a new Setlist ([Setlist — a generated performance](#setlist--a-generated-performance-the--play-payoff)) and open it.
- **target (m:ss)** — give a sequence a time budget; pockets sample to fit it.
- **Move to / Remove / ＋ Add pocket / ＋ Add sequence** — shape the chapters.
- **A set list row** — open a previously generated performance.

Each item row carries its **album cover art** and **BPM / Camelot** badges, and the header
shows a **song count + total runtime** both **per chapter** and for the **whole playlist**.
Every item can be **reordered** with **▲ / ▼** within its chapter (disabled at the ends) or
moved between chapters with the **→ chapter** dropdown; **＋ note** attaches an inline
**performer note** (*"open cold — let it breathe"*); and tapping the item's **name** opens its
full **song metadata**. You can also drop a **free-text cue** that isn't a catalog item —
*"sample of This Land Is Mine"* — straight into a chapter as a **CUE** row, and **⤓ Export**
saves the whole playlist to a portable file.

**User story:** compose the *shape* of the night — a warm-up pulled from a pocket,
a fixed pair of closers — without nailing down the exact tracks yet.

---

## Setlist — a generated performance (the ▶ Play payoff)

![Setlist](23-setlist-take2-mobile.png)

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
  Columns: `#, Artist, Title, BPM, Key, Length, Source, Sequence, Note, Song ID` — the
  **Song ID** lets a downstream process resolve each track's audio segment in O(1).
- **Delete** — discard this take.
- **Tap a track** — open its song detail ([Setlist — tap a track for song detail](#setlist--tap-a-track-for-song-detail)).

The realized set list has an **editable name**, **per-track performer notes**, and renders
any **free-text cues** as no-audio rows; the **Save CSV** export carries a **Note** column, so
your cues and notes travel to whatever you spin from.

**User story:** the mission payoff — a real, saved set list you can read off ("spin
these, in this order"), export, or regenerate for a different feel.

---

## Setlist — tap a track for song detail

![Setlist song detail](24-setlist-song-detail-mobile.png)

Tapping any setlist track (or pocket member, or browser row) opens the shared
read-only **song detail** popover — track #, artist, album, genre, year, length,
explicit flag, **BPM / Key / Camelot**, sentiment tags, the analog **plug-in**
pointer, and lyrics — closed by a **mobile-friendly ✕** in the top-right.

**Affordances**
- **✕ (top-right) / Close / Escape / backdrop** — dismiss.
- **＋ Add to…** — file this track into a pocket or playlist ([Add to a pocket or playlist](#add-to-a-pocket-or-playlist)).

The card shows the **album cover** and an **Album → ↗** link that opens the album view, so you
can jump from a track straight to its record.

**User story:** one consistent detail card everywhere, so you can always check a
track's key/tempo before you commit it to a mix.

---

## Press Play on a playlist or pocket — hear it now, in order or shuffled

A playlist and a pocket aren't just things you *shape* — you can also **hear them straight away**.
Each playlist and pocket detail screen carries two side-by-side buttons:

- **▶ Play** — play its songs **in their listed order**, top to bottom,
- **🔀 Shuffle** — play the same songs in a **random order**.

Tap either and the app jumps you to a single reusable **"Now Playing"** set and **starts playing
at once** in the inline player, auto-advancing track to track. It's built **literally from the
songs you're looking at** — the exact list, in order (or shuffled) — not the "realized" set the
**make-a-set-list** button produces ([Make a set list — freeze a take from a playlist](#make-a-set-list--freeze-a-take-from-a-playlist)): no sampling, no harmonic autofill, no dedup. A song
that can't be resolved to anything playable is simply dropped from the run. Because it's **one
shared set** that's **reused** every time, hitting **▶ Play** or **🔀 Shuffle** anywhere just
**replaces** what's in Now Playing rather than piling up a new set each time — and it's **hidden
from your set-list history** and **cleared on launch**, so it never clutters the sets you've
deliberately saved.

**Read-only source playlists shuffle in place too.** A playlist that came from one of your
sources — e.g. an **Apple Music** user playlist — is read-only, so it used to offer only **▶
Play**; to shuffle it you first had to **Duplicate as editable playlist**. Now the read-only
detail screen carries its own **🔀 Shuffle** button right next to **▶ Play**, so you can
shuffle an Apple Music playlist **without duplicating it first** — it drops straight into
Now Playing and starts.

Landing in **Now Playing** drops you into the normal setlist screen ([Setlist ▸ ▶ Play — play the whole set in order](play-rip-burn.md#setlist---play--play-the-whole-set-in-order)), so you can **see
what's next and reorder it on the fly** while it plays — exactly the controls you'd want with a
set running.

**User story:** "I just want to *hear* this crate right now — one tap to play it in order, one
to shuffle it — and still see and nudge what's coming up next."

---

## Converted pockets & duplicated playlists stay in sync with their source

**Convert once, follow forever.** When you **Convert** a read-only source playlist (say, an
Apple Music playlist) into a pocket — or **Duplicate** it **as an editable playlist** — the
copy now **remembers where it came from**, and as the catalog refreshes it **follows the
source**: songs you add to that playlist in Apple Music show up in your copy; songs you remove
there disappear from it. Your **own edits are safe** — tracks you added yourself stay put,
tracks you removed yourself don't come back, your reordering and your extra chapters are
preserved (source additions land in a playlist's first chapter). Sync happens automatically
whenever the app picks up a fresh catalog (including right at launch from the offline cache).

**You're in control, three ways:**

- **Globally** — Settings ▸ **Sync** ▸ "Sync converted playlists & pockets" (on by default)
  turns the automatic follow on or off for everything at once; the same panel's **"Sync from
  sources now"** button runs one pass immediately and reports how many items changed.
- **Per item** — the pocket's or playlist's **⋯ menu** has a **"Sync with source"** toggle, so
  one item can freeze while the rest keep following.
- **On demand** — the same menu's **"Sync from source now"** pulls the latest source membership
  immediately, even when automatic sync is off, and tells you whether anything changed.

Items made by hand (or converted before this shipped) have no source and are never touched.

**User story:** "I built this pocket from my Apple Music party playlist. I keep adding songs to
that playlist on my phone — I want the pocket to just keep up, without flattening the tweaks
I've made to it, and I want one switch to freeze it before a gig."

---

## Add a song to an Apple Music playlist — it goes upstream too

Following a source used to be a **one-way street**: changes made in Apple Music flowed down
into your copy, and nothing you did in PocketDJ ever flowed back. Now it goes both ways.

The **＋ Add to…** picker ([Add to a pocket or playlist](#add-to-a-pocket-or-playlist)) lists a
**"From your sources"** section under your own collections — your Apple Music playlists, each
with a line saying what tapping it will do: *"Apple Music (Local) · adds to your local copy"*
if you already have an editable copy of that list, or *"· makes a local copy"* if this is the
first time. Tap one and **two** things happen:

1. **On this device** — PocketDJ finds (or makes) the editable copy of that playlist and adds
   the song to it. The copy keeps following the original, exactly as before, and this is the
   *same* copy the **Duplicate as editable playlist** button makes — you never end up with two
   competing copies of the same list.
2. **In Apple Music** — the song is also added to the **real** playlist in your Apple Music
   library, so it's there in the Music app, on your other devices, and in the car.

An alert tells you which of those actually happened, in plain words, every time — including
the honest cases:

- **Already there** — the song is already in the Apple Music list, so nothing is sent upstream
  (sending it would put a *second* copy of the track in your real playlist).
- **"…isn't an Apple Music track, so it stays in your copy only"** — a **vinyl**, **My
  Digital**, or **Studio** song has no Apple Music identity to add, so the local add is the
  whole of it.
- **"Apple Music playlists can't be edited from this device"** — on the **Mac**, Apple gives
  apps no way to write to a library playlist at all. The local add still stands; the upstream
  half simply doesn't exist there. On iPhone, iPad, and Vision Pro it does.

If you're **offline** or not signed in when you tap, nothing is lost: the upstream add is
**remembered and retried** the next time the app opens or comes forward, and it retries a few
times before it gives up. Until it lands, the worst case is exactly *"the add stayed local"* —
your copy has the song, Apple Music doesn't yet, and nothing you added ever gets deleted by the
sync that follows the source back down.

**Affordances**
- **＋ Add to… ▸ From your sources** — one row per source playlist, with a ✓ when the song is
  already in it.
- **Row subtitle** — says up front whether tapping makes a new local copy or adds to an
  existing one.
- **Result alert** — names exactly what happened locally and upstream.

**User story:** "I'm digging in PocketDJ and I find one for the Friday list. I want it in my
Friday list — the real one, the one on my phone in the car — not in some parallel copy I have
to reconcile later."

---

## Make a set list — freeze a take from a playlist

**Realizing** a playlist into a frozen, saved take — expanding albums, sampling over-budget
pockets to fit, autofilling harmonic bridges ([Playlist — the template](#playlist--the-template-sequences)–[Setlist — a generated performance](#setlist--a-generated-performance-the--play-payoff)) — lives on its own toolbar button marked
with the **list.bullet.clipboard** icon. Tap it to generate a concrete, persisted **set list**
from the template; the plain **▶ Play** beside it is the play-it-now button above.

**User story:** "Keep the two ideas separate: one button just plays the crate, the other builds
me a real, saved set list I can tweak, rip, and burn."

---

## Your playlists on top; folders to organize them

**Yours | Shared tabs.** The Collections screen (the tab that holds your pockets, playlists, set lists, and folders) splits into two segmented tabs: **Yours** — the
playlists and pockets you build, plus your folders — and **Shared** — the read-only **"From your
sources"** playlists. The sets you build are what you reach for, so **Yours** is where you land,
with **Your playlists** on top; on **Shared**, the source playlists are **grouped by source**
(Apple Music (Local), vinyl, imports…) into **collapsed-by-default** groups that **remember which
ones you expanded**, so a giant source library stays one tidy row until you open it. **Your
playlists** and **Your Pockets** now fold the same way — each is a header with a member count and a
disclosure triangle, **expanded by default** (your own sets are what you land on) and remembered
across launches — so a long crate of your own collections tucks away as neatly as a source group.

**Sort them your way.** A toolbar **sort menu** orders the collection lists by **Recently
played**, **A–Z**, or **Last updated** — the choice **persists** and applies to your playlists,
your pockets, folder contents, and each Shared source group alike.

**Folders.** You can group playlists into **folders**:

- **＋ New folder** — create one and name it,
- **rename** or **delete** a folder — deleting it **keeps the playlists**; they simply fall back
  to the top level,
- **move** a playlist into (or out of) a folder.

Folders show as **collapsible sections** ordered by name, and **each section remembers whether
you left it collapsed** — so a long shelf of sets stays tidy. Folders ride along through
**import/merge** and the **backup zip**, so the way you've organized your sets travels with them
to another device.

**Search by name.** At the top of the Collections screen is a **search bar** (the same one the
Browser uses). Type any part of a name and the **active tab** narrows to its matches —
**playlists and pockets** on Yours, **source playlists** on Shared; the field's prompt says
which — a case-insensitive substring match. While you're searching the **folders and source
groups flatten away**: a match shows up under its section header no matter which folder or group
holds it, so you never have to remember where you filed something to find it. Clear the field and
your folders and groups snap back; a search that matches nothing shows a plain "No Results".

**User story:** "I've got a lot of sets — let me file them into folders I can fold shut, keep the
ones I made up top where I actually look, and just type a few letters to pull up any set by name
without digging through folders."

---

## Export a tracklist — PocketDJ or CSV

Exporting a **playlist**, **pocket**, **set list**, or a **session's tracklist** asks for a **format**:

- **PocketDJ (full metadata)** — the existing re-importable bundle (`.pocketdj.zip`) that keeps
  *everything* PocketDJ knows and can be loaded straight back into the app. This is the **default**.
- **CSV (tracklist)** — a **universal** comma-separated list any spreadsheet, DJ app, or database can
  read, with just the columns **everyone** shares: **play track # · Title · Artist · Album · Year ·
  Genre**. It deliberately **leaves out** PocketDJ's own metadata (BPM/key/segments/provenance) —
  that's what the PocketDJ format is for — so the CSV stays portable.

The format picker appears after you tap **Export**; pick **PocketDJ** to keep working inside the app,
or **CSV** to hand your tracklist to the outside world. A single **playlist** or **pocket** in the
PocketDJ format is a **`.playlist.pocketdj.zip`** / **`.pocket.pocketdj.zip`** that references the
catalog by id AND bundles a slim **catalog snapshot** (`items.json` — title/artist/album, BPM/key,
length, streaming ids; never audio or art blobs), so it is **portable across DJs**: import it on a
device whose sources don't carry those songs — even a fresh install that only enabled Vinyl — and
the unknown songs land as a provisional **"Imported"** source, browsable and playable immediately,
burnable **with stems** straight off the shared rips library. Enable the real source later and it
quietly takes over those ids; un-enable it and the imported fallback is still there. An import
always lands as *"… (imported)"* without clobbering what's already there, and the same zip imports
into the web PWA too.

**User story:** "Export a set as PocketDJ when I'm round-tripping it in the app — or as a plain CSV
with just the universal columns when I need to drop the tracklist into a spreadsheet or another DJ
tool."
