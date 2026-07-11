# Performance — The Studio

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). Everything else in the
> product is about *records* — finding them, shaping them into a set, ripping, burning
> and mixing them. **The Studio is where you make your own.** The native iPhone / iPad /
> Mac app carries a fifth top-level tab — **Performance** (the piano-keys icon) — a
> little studio for your own material: **sample** any track or an external input, slice
> beat-synced **loops**, program a 16-step **sequencer**, play seven **virtual
> instruments** and keep the take as a **score** or an **instrumental**, and drop **cue
> points** on any track. Samples, loops, sequences and instrumentals become **collection
> items** that live in your pockets and playlists beside real records.
>
> The Studio is **native-only** (the web client simply skips a studio item in a shared
> collection) and reads the **same catalog, rips and collections** as everything else: a
> sample is carved from the *same* rip a burn would download, a cue seeks the *same*
> file a row ▶ plays. The systems-side complement is
> [Performance Engine [Single-album view](explore-and-discover.md#single-album-view-albumid) (the Studio)](../architecture/04-performance-engine.md#8-the-performance-tab-studio--distinct-from-the-realize-engine-above).
> These sections are prose-only — no screenshots captured yet.

## The Performance tab — a studio in your pocket

The native app has a **fifth top-level tab**: **Performance** (the **piano-keys** icon, beside
Browser · Playlists · Mix · Settings), and **⌘P** jumps straight to it. That one physical key has three deliberate homes: **⌘P**
opens Performance, **⇧⌘P** opens Playlists, and **⌥⌘P** is Browser's play-focused ▶.

Inside, a **segmented picker** across the top splits the Studio into **five sub-tabs**, and **⌘1–⌘5**
step between them (scoped to this tab, so they never fight Browser's own ⌘1/⌘2):

**Affordances**
- **Samples** (⌘1, waveform) — capture audio from a track or the mic and shape it.
- **Loops** (⌘2, repeat) — slice a sample into a beat-synced loop.
- **Sequencer** (⌘3, grid) — a 16-step drum-machine grid over your samples and loops.
- **Instruments** (⌘4, piano-keys) — play and record the virtual instruments.
- **Cues** (⌘5, flag) — set jump-to points on any track.

On a **narrow iPhone in portrait** the five segments show **just their symbols** (five text labels
won't fit); a **wider** screen shows symbol *and* word. The Studio **remembers the sub-tab** you were
last on and reopens there, and — the toolbar-overflow lesson from Playlists — its important controls
stay **in the content**, never buried behind a `•••`.

**User story:** "I hit ⌘P, land on Samples where I left off, and the whole Studio is one number-key
away — 1 to grab a sample, 3 to drop it into a beat — without ever reaching for the mouse."

---

## Samples — grab a piece of any track, or the room

A **sample** is a piece of audio you own — carved out of a song in your crate, or recorded from the
**microphone**.

**From a track** (**＋ from track**). Pick a song — a search field, with a **burned badge** on the
ones already on your device — then land in the **region editor**: the song's **waveform** (drawn from
the local file when there is one), **start and end handles**, **in / out** mark buttons you can tap
while it auditions, and **fine nudges** (±10 ms, or ±1 beat when the song's grid is known; on iPhone
portrait the fine controls pop into the fixed-width popover from [Export a tracklist — PocketDJ or CSV](perform-pockets-playlists-setlists.md#export-a-tracklist--pocketdj-or-csv)). How the Studio *reaches* the
audio depends on what you've already got, and it never dead-ends:

- **Burned** — it carves straight from the on-device file.
- **Ripped but not burned** — it **burns the song on demand** first, showing the same **burning →
  ready → failed + Retry** panel the stem audition uses.
- **Apple-Music-only, never ripped** — it says **"Rip first"** and points you at the existing rip
  flow, rather than silently doing nothing.

The carved sample **inherits the parent song's beat grid** — offset-shifted so beat one lands where
*your* clip begins — so a slice out of a 120-BPM track already knows it's 120 BPM.

**From the microphone** (**● record**). Grant permission once, watch the **level meter**, record and
stop, and name the take. A mic sample has **no grid** until you give it one — **tap the tempo** out on
the tap-tempo button or **type a BPM** (the same affordance waits in the Loops empty state).

### From audio in — capture an external input

A Studio sample doesn't have to come from the built-in mic. The **Record-sample** sheet always shows an input affordance before you hit record: plug in a **USB-C audio interface**, a line-in, or a **TX-6** mixer, and the sheet turns into a tappable menu listing every available input — each one labelled with a cable or mic glyph, a checkmark marking the one currently selected. With only the built-in mic present, the same spot shows a static chip and a hint: "Connect a USB-C audio interface — like your TX-6 — to sample its output instead of the mic." The sheet header itself changes to match — "From the microphone" or "From TX-6" — and the input list refreshes live as you plug or unplug. Once captured, the sample remembers its source ("Recorded from TX-6" / "Recorded from audio in"), and it's written through the same crash-safe recorder as any mic sample. (On macOS the system's default input is used automatically, so there's no selector to show.)

**User story:** "I want to sample straight off my TX-6's output — not the room through a phone mic — and have the app show me it's listening to the right input before I hit record."

### More sample sources — a file, a download, or the stems

Beyond a track or the microphone, a small **⤓ menu** on the Samples bar opens two more
doors. **Import audio file…** opens the system file browser — pick any mp3 / m4a / wav /
aiff / caf and it's transcoded and dropped in as a new sample (a purchased, DRM'd track is
politely refused — it can't become a sample). **From downloaded track** is the offline
door: it lists only tracks you've already downloaded, so you can carve a stab on a plane
with no signal. And for a track that's been **stemmed**, the carve screen grows a **"Stem
source"** toggle — flip it on and the four stems (**drums · bass · vocals · other**) become
chips you can turn on and off. Grab just the **drums**, or **drums + bass**, and PocketDJ
mixes only those parts into your sample (the name remembers the recipe: "*Song · drums+bass*").

### Auto-detect the tempo, on the device

A sample that didn't inherit a beat grid (a mic take, an import) can still find its own
tempo: an **Auto-detect tempo** button listens to the sample **on the phone** (no server,
works offline) and reads its BPM, so loops and slices snap to the groove without you
counting it out.

**Editing is non-destructive.** Open a sample and you can **rename**, **trim**, and dial **gain**,
**playback rate** (½–2×), **pitch** (±12 semitones), and **reverb** and **delay** — all auditioned
live through the Studio's chain, and **none of it written into the file** until something that needs a
finished file asks for one (a loop, a sequenced hit, or playing the sample inside a collection).
Change an edit and the render just refreshes.

### Slice a sample into pads

Open a sample and tap **Slice into pads**. A waveform appears with up to **eight numbered
markers** you can drag, and an **Auto-slice** that chops the sample into N pieces — **on the
beat grid** if it has one, an even split if it doesn't. Each pad is a **tap-to-play** slice
(from its marker to the next). **Make sample** bakes a pad into a normal sample, and **Send
pads to sequencer** turns the whole set into a new 16-step pattern — so a one-bar break
becomes eight pads you can re-sequence.

**User story:** "I loop back to the four bars I love in a record I haven't even burned yet — the
Studio burns it, I drag the handles onto the break, nudge the start to the downbeat, and now I've got
a clean sample that still remembers it's 118 BPM."

---

## Loops — a seamless bar you can lean on

A **loop** is a **beat-synced slice of a sample** that repeats forever with **no click at the seam**.
Pick a sample, choose a **length in beats** — **½, 1, 2, 4, 8, 16 or 32** — set the **anchor**, and
the Studio snaps the window to the sample's real **downbeats** and renders it. Save, rename, delete;
the audition **loops** so you hear exactly what you'll get.

Two things make a loop dependable. First, it's **rendered to its own standalone file with your edits
baked in**, so it **plays offline** and — crucially — **outlives its source**: delete the sample it
came from and the loop keeps playing (you just can't *re-slice* it anymore, and the row notes the
source is gone). Second, that file is written in a **lossless, gapless format** on purpose: a
compressed loop file would add a tiny hiccup of silence at the loop point and **tick** on every pass —
so loops are the one Studio artifact that isn't an `.m4a`, and they come back around clean, bar after
bar.

**User story:** "I slice a two-beat stab out of a horn sample, hit audition, and it just breathes —
round and round with no tick — so I know it'll hold a groove under a whole set."

---

## Sequencer — sixteen steps, your samples on the grid

The **Sequencer** is a **16-step** drum machine. **Add rows** — each row is a **sample or a loop** —
and **tap the steps** under each to place a hit on that sixteenth of the bar. Set the **pattern BPM**,
hit **play**, and it cycles the bar; **name and save** patterns, and load them back later.

It behaves like a real step sequencer. Hits **choke themselves** — retrigger a row and it cuts its
own ringing tail, the classic mono-voice feel. On a **narrow iPhone** the 16 steps **wrap to two rows
of 8** with a group separator every four steps so your thumb can find the beat; a **wide** screen
lays all 16 in a single line. You can **bounce** a pattern to a single audio file whenever you want a
finished loop of the whole thing (it re-bounces the moment you edit it).

It's also **forgiving of your own housekeeping**: a row whose sample or loop you later **deleted**
shows up as a **muted "missing" row** and is simply **skipped** — never a crash — and a pattern with
**nothing switched on** politely **declines** to play or bounce rather than choking on an empty
schedule.

**User story:** "I drop my kick sample on row one, the horn loop on row two, tap out a pattern on my
phone in two rows of eight, and bounce it — and even after I've thrown away the original samples the
beat still plays."

---

## Virtual instruments — play it, score it, keep it

The **Instruments** sub-tab turns the app into a small **MIDI instrument**. Seven voices —
**piano, violin, bass guitar, acoustic guitar, trumpet, clarinet, harp** — play from a **wired / USB
MIDI keyboard** or the **on-screen keys**. (Network and Bluetooth MIDI aren't in this version.) The
on-screen keyboard spans **six octaves** and opens on **C3**; it **scrolls**, and the **‹ ›** buttons
on either side jump a whole octave at a time (on a Mac, the **left / right arrow keys** do the same).

**The sounds are one download.** All seven voices live in a single **~32 MB General MIDI sound bank**
(**GeneralUser GS** — its license asks for credit, so the packs screen shows the attribution), so the
**Sound packs** section shows **one row** — get it once and **every instrument** is ready. (Tapping a
locked instrument kicks off that same shared download.) The bank plays **offline**, and you delete it
from the packs screen or Settings ▸ Storage.

**Recording a take.** A **metronome click** and a **one-bar count-in** (both on by default, both
switchable) lead you in, then you play. The Studio captures the **actual notes** — not just the audio
— so a take renders to **real sheet music**: a **grand staff** for piano and harp, a **treble staff**
for the melodic voices, **bass clef** for bass guitar, with note heads, stems, flags, ledger lines,
chords and rests. **Replay** plays those same notes back through the instrument, so **the page and
the sound always agree**.

And a take doesn't have to stay a take:

**Affordances**
- **Export PDF** — real, vector **sheet music** (not a screenshot).
- **Export MIDI** — a standard MIDI file, from your **raw** performance (before the score rounded it
  to the grid).
- **Use as sample** — **copies** the take's audio into a **new sample** with a grid from its tempo,
  handing you the whole **play it → sample it → loop it** path.

### Write on the staff — live and recorded

The **Score** screen is editable, not just read-only notation. Its **Edit** button lets you
**tap the staff to place a note**, tap a note to select it (it gets a ring), then set its
**length** (𝅘𝅥𝅮 · 𝅘𝅥 · 𝅗𝅥 · 𝅝), toggle its **accidental** (♮ · ♯ · ♭ — a flat draws as a real
flat, not a sharp), or **delete** it — and Replay and the PDF/MIDI export follow your edits.
On **Instruments**, a **Live score** fills in *as you play* the keys (or a connected MIDI
keyboard) — the same staff, the same editing — and **Save** files it as a take. Play a
phrase, fix the one note you fluffed by tapping it on the staff, and keep it.

**User story:** "I count myself in, play a bass line on my keyboard, and there it is as sheet music I
can export as a PDF — or turn straight into a sample and slice into a loop for the sequencer."

---

## Instrumentals — one recording, rendered anywhere

Every take you record — or save live — from a virtual instrument becomes an **Instrumental**, and Instrumentals collect in their own list (rename, delete). What's actually stored is lean: just the note events of the performance. PocketDJ renders those notes into real audio **on demand**, through the take's own instrument sound bank, so an Instrumental sounds exactly like the Replay you heard when you played it — no matter where it ends up.

That one design choice unlocks three things. On the **Score** screen, an **Export Audio** button sits alongside **Export PDF** and **Export MIDI** — it renders the take and saves a real audio file. On the Instrumentals list, an in-row **Sample from instrumental** button (mirrored as a **＋ Sample from instrumental…** entry in the Samples ⤓ menu) mints a new, self-contained **sample** from the performance in one tap — complete with a grid built from its tempo, so the sample keeps playing even after the source Instrumental is deleted. And an Instrumental dropped into a **collection** renders to audio the first time it's needed to play. Instrumentals go into a **playlist** or **pocket** like any other track, and — like your other media — you can point their storage at a folder of your own in Settings ▸ Storage. Edit the score and the audio re-renders to match.

**Affordances**
- **Instrumentals list** — every recorded/saved take, renamed or deleted here
- **Export Audio** (Score screen) — render the take to a real audio file, next to Export PDF / Export MIDI
- **Sample from instrumental** — in-row button, or ＋ Sample from instrumental… in the Samples ⤓ menu; mints a standalone sample with its own tempo grid
- **Play in a collection** — renders to audio automatically the first time it's needed

**User story:** "I record a take once, and from there I can export it, sample it, drop it in a collection, or file it in a pocket — it always plays back exactly like it sounded when I played it."

---

## Cue points — tap to drop the needle

**Cues** let you mark up to **eight jump-to points on any track** and start playback from any of them
with one tap. Pick a song and its **timeline** appears — a **digital** song draws its own **waveform**;
an **analog** song's waveform is the **whole album side**, cropped to just this song's slice. Below the
timeline is a **transport — play/pause + a scrub bar** — so you can **audition and scrub the track to
find each spot**, then drop a cue there: no more setting one cue at 0:00, playing from it, and having to
listen through the whole song to place the next one. **Tap a slot** to drop a cue at the playhead;
**tap it again to jump there and play**. Long-press or ⋯ to **set-at-playhead**, **rename**, **nudge**
a cue a hair earlier or later, or **delete** it — each of the eight **slots keeps its own stable
color**. (Scrubbing needs a seekable source — a burned file or a ready stream; a track that's still
ripping can still be **played from the top** to audition, just not scrubbed into.)

The cues you drop here also surface **in the Mix tab**: load that track onto a deck and its cue points
appear as **jump-to-cue buttons** under the deck's scrubber ([Per-deck controls — seek, tempo & pitch](mix-and-stems.md#per-deck-controls--seek-tempo--pitch)), in the same colours.

A cue plays through the **same playback path** a row ▶ uses, so it behaves like the rest of the app:

- a **burned local file** jumps **exactly**;
- a **streamed** track plays-then-**seeks** (Apple Music lands within about a second);
- a track that's **still ripping** right now **can't seek yet** — its cue buttons show a **"still
  ripping"** state until the capture finishes.

**User story:** "I mark the drop, the last chorus and the outro on a record, and mid-set I just tap
the flag for the drop — and it's there, whether that track's burned on my phone or streaming."

---

## Studio in your collections & storage — where your creations live

Your Studio creations are **first-class collection items**. A **sample, loop, sequence or
instrumental** — all four kinds — can be **added to a pocket or playlist** exactly like a song: the
**Add-to** sheet lists them alongside your catalog. In a set-list, each one gets a full track row of
its own: a **PocketDJ-app-icon artwork** tile stands in for the album cover a studio item doesn't
have, next to the title, a **kind badge** (**Sample / Loop / Sequence / Instrumental**), its **BPM**,
its own compact **waveform** strip, and its length. **Counts and runtimes include them**, using their
real, rendered lengths.

Every row carries an always-visible **N×** capsule — the **repeat count**. Tap it (or reach the same
control from the row's context menu) for a preset picker — **1 / 2 / 3 / 4 / 6 / 8 / 16** — and the
item plays that many times in a row before the set advances to the next track; runtime totals fold
the repeats in, so a 4× loop counts as four passes' worth of time. The **artist** on every studio
row is **your PocketDJ name** — set it in **Settings ▸ PocketDJ name**; leave it blank and your
creations are simply credited to **"Studio."**

Adding a performance item to a collection also **prepares it for offline play**. PocketDJ renders it
to real, playable audio the moment it lands in the set — an **instrumental renders its notes**, and a
**sequence that's never been bounced auto-bounces** (loops and samples already carry rendered audio)
— and it **works out the item's musical key on the device**, a **Camelot** code, from its exact notes
(instrumentals) or an audio chromagram (samples, loops, sequences). That key is what makes the item
**harmonically mixable** the same as any record: it can be **loaded onto a Mix deck**, picked up by
**Auto-Mix**, and **glide** key-to-key into and out of whatever's playing next to it.

The Studio deliberately stays out of the parts of the app that talk to the cloud or the wallet.
**Rip**, **Burn** and **Stemify** on a collection **skip** your studio items, the **tracklist CSV**
export leaves them out, and **Auto-Mix's autofill** won't reach for one of your loops as a "harmonic
bridge" in some other set — they're already on the device, so there's nothing to fetch and nothing to
push to the public cache.

**Storage.** Settings ▸ Storage grows a **folder picker** for each user-relocatable family —
**samples**, **loops**, **sequences** — plus **usage rows** for those three and for **takes** and
**instrument packs**, and a **delete-all** for each family. **Takes and instrument packs stay
app-managed** (no folder to lose them in), and the same safety rules as your burns apply: the Studio
**only ever counts and deletes files it wrote**, so your own audio in a folder you pointed it at is
never touched, and it **never auto-prunes** anything you made.

**Affordances**
- **Add-to sheet** — lists samples, loops, sequences and instrumentals alongside songs.
- **Kind badge** — Sample / Loop / Sequence / Instrumental, on every studio row.
- **N× repeat capsule** — tap for presets (1/2/3/4/6/8/16); also on the row's context menu.
- **PocketDJ name** (Settings) — the artist credited on your studio rows; blank shows "Studio."
- **Camelot key** — detected on-device when an item joins a collection, enabling Mix-deck loading and glide.
- **Storage folder pickers** — per-family location + usage + delete-all for samples, loops, sequences.

**User story:** "My loop sits in tomorrow's warmup playlist right next to real records, set to play
twice before the set moves on, its key already worked out so it glides into whatever's next on the
deck — and when I hit *Rip collection* or export the CSV, PocketDJ knows it's mine and leaves it
alone."
