# Producer — The Studio

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). Everything else in the
> product is about *records* — finding them, shaping them into a set, ripping, burning
> and mixing them. **The Studio is where you make your own.** The native iPhone / iPad /
> Mac app carries a fifth top-level tab — **Producer** (the piano-keys icon; it began
> life as *Performance*) — a
> little studio for your own material: **sample** any track or an external input, slice
> beat-synced **loops**, program a 16-step **sequencer**, play seven **virtual
> instruments** and keep the take as a **score** or an **instrumental**, drop **cue
> points** on any track, and **demux** any audio into lyrics, chords, a drum pattern
> and a melody. Samples, loops, sequences and instrumentals become **collection
> items** that live in your pockets and playlists beside real records.
>
> The Studio is **native-only** (the web client simply skips a studio item in a shared
> collection) and reads the **same catalog, rips and collections** as everything else: a
> sample is carved from the *same* rip a burn would download, a cue seeks the *same*
> file a row ▶ plays. The systems-side complement is
> [Performance Engine — the Studio](../architecture/04-performance-engine.md#8-the-performance-tab-studio--distinct-from-the-realize-engine-above).
> These sections are prose-only — no screenshots captured yet.

## The Producer tab — a studio in your pocket

The native app has a **fifth top-level tab**: **Producer** (the **piano-keys** icon, beside
Browser · History · Collections · Mix · Jukebox Hero · Settings), and **⌘P** jumps straight to it. That one physical key now has two deliberate homes: **⌘P**
opens Producer and **⌥⌘P** is Browser's play-focused ▶ (the Collections tab has since moved to its own **⌘C**).

Inside, a **segmented picker** across the top splits the Studio into **seven sub-tabs**, and **⌘1–⌘7**
step between them (scoped to this tab, so they never fight Browser's own ⌘1/⌘2):

**Affordances**
- **Samples** (⌘1, waveform) — capture audio from a track or the mic and shape it.
- **Loops** (⌘2, repeat) — slice a sample into a beat-synced loop.
- **Sequencer** (⌘3, grid) — a 16-step drum-machine grid over your samples and loops.
- **Instruments** (⌘4, piano-keys) — play and record the virtual instruments.
- **Cues** (⌘5, flag) — set jump-to points on any track.
- **Demuxer** (⌘6, waveform-under-a-magnifier) — take any audio apart: lyrics, chords, stems, drum pattern, melody.
- **Tracks** (⌘7, stacked-lanes) — arrange everything you've made into a **multitrack** — play it, record into it, bounce it down.

On a **narrow iPhone in portrait** the seven segments show **just their symbols** (seven text labels
won't fit); a **wider** screen shows symbol *and* word. The Studio **remembers the sub-tab** you were
last on and reopens there, and — the toolbar-overflow lesson from Collections — its important controls
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
portrait the fine controls pop into the fixed-width popover from [the effects grid](mix-and-stems.md#the-effects-grid--tap-to-toggle-dial-the-strength)). How the Studio *reaches* the
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

Beyond a track or the microphone, a small **⤓ menu** on the Samples bar opens more
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

**Editing is non-destructive — a built-in mixer deck.** Open a sample and you get a **mixer deck**:
**Tempo** (½–10×), **Pitch** (±12 semitones), **Gain**, and a four-effect **FX rack** — **Compressor**,
**Reverb**, **Delay**, and a resonant **Filter** sweep — plus **trim** and **rename**. Everything is
auditioned live through the Studio's chain and **none of it is written into the file** until something
that needs a finished file asks for one (a loop, a sequenced hit, or playing the sample inside a
collection). Change an edit and the render just refreshes. There's also a **Loop** button that
seamlessly loops the trimmed region while you audition — a live performance tool that resets when you
close the editor (it doesn't bake into the file). It's the **same deck** the sequencer gives each of
its sample rows, so a sound you shape here sounds identical everywhere it plays.

### Folders — file your crate of samples

A growing crate needs shelves. A **folder button** on the Samples bar (the folder-with-a-＋
glyph) creates a named **sample folder**, and every sample's context menu grows a **Move to
folder** submenu — pick a folder, pick **Unfiled**, or pick **New folder…** to create one and
file the sample into it in the same gesture. Folders are **collapsible groups** in the list
(the app remembers which you've folded, across launches), and a folder's own menu lets you
**rename** or **delete** it — deleting a folder just un-files its samples, it never touches
audio. Folders are purely **organizational**: the sample's file **never moves on disk**, so a
relocated samples folder, a burn, or a sequencer row never notices you tidied up.

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

## Sequencer — your samples on the grid

The **Sequencer** is a step drum machine — **16 steps** (one bar) by default, and up to **365**.
**Add rows** — each row is a **sample or a loop** — and **tap the steps** under each to place a hit on
that sixteenth of the bar. Set the **pattern BPM** and its **Length** (in bars), hit **play**, and it
cycles the pattern; **name and save** patterns, and load them back later.

It behaves like a real step sequencer. Hits **choke themselves** — retrigger a row and it cuts its
own ringing tail, the classic mono-voice feel. Each **bar** of steps lays out on its own line — a
**narrow iPhone** splits each bar into two rows of 8 with a group separator every four steps so your
thumb can find the beat; a **wide** screen keeps the bar on one line — so a long multi-bar pattern
stacks its bars vertically. You can **bounce** a pattern to a single audio file whenever you want a
finished loop of the whole thing (it re-bounces the moment you edit it).

**A mixer deck on every sample row.** Each row that plays a **sample** has a collapsible **Mixer
deck** — the same deck the sampler editor uses, minus the gain slider and looper. Dial its **Tempo**,
**Pitch**, and **FX** (compressor · reverb · delay · filter) and they **bake into that row on the next
Play**. The row's own **live gain chip** stays in the header for instant loudness balancing while the
pattern runs, so you shape the *sound* in the deck and ride the *level* in the header.

**Preview one row at a time.** Tap a row's **header** (its icon + name) to **solo** just that row —
it loops on its own at the pattern tempo so you can hear a single sample or loop in isolation while
you dial in its steps; tap the header again (or the main transport) to stop.

**Set the length.** A **Length** stepper sets how many **bars** the pattern runs — from one bar (16
steps) up to **365 steps**. Growing keeps every step you've already placed and adds empty bars;
shrinking drops the tail. A longer pattern is simply a longer loop everywhere it plays — in a
collection its runtime grows to match.

**Live vs. static edits.** By default, step and tempo edits take effect the **next time you press
Play** — the running loop keeps playing what you loaded. Flip the **Live edits** toggle and your
**step** and **loop-mode** changes apply on the **next bar** while it's playing, so you can build a
groove by ear without stopping and starting. (Tempo, length, and Fit-to-steps spans still apply on
the next Play.)

Each hit has a **trigger mode**, too. Long-press (or right-click) any lit step for its menu:
flip it between **one-shot** (play once, the default) and **loop until retriggered**, and give
it a **Fit-to-steps** span — stretch the sample to last exactly **1 / 2 / 3 / 4 / 6 / 8 / 12 /
16 steps** (or leave it its natural length) at the pattern's tempo. A looping step wears a tiny **repeat** glyph, a fitted one a **×N** badge, and the
off-cells a fit sweeps through carry a faint wash so its musical footprint reads at a glance.
And a row isn't married to its sound: a **retarget** menu on the row swaps in **any other
sample or loop** while the steps, modes and gain all stay — program the pattern once, morph
the kit under it.

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
MIDI keyboard**, a **Bluetooth MIDI keyboard**, or the **on-screen keys**. The
on-screen keyboard spans **six octaves** and opens on **C3**; it **scrolls**, and the **‹ ›** buttons
on either side jump a whole octave at a time (on a Mac, the **left / right arrow keys** do the same).

**Connect a Bluetooth keyboard.** Tap **Connect Bluetooth MIDI…** to open a live scan list, put your
keyboard in pairing mode, and tap it to connect — its keys then play the current instrument and record
into a take exactly like the on-screen keys. This works the same on **iPhone, iPad, Mac, and Vision Pro**.
(Network MIDI still isn't in this version.)

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

The **Score** screen is editable, not just read-only notation. Its **Edit** button opens four
explicit modes:

- **Enter** — every tap **places a new note** at that spot; pick its **length** (𝅘𝅥𝅮 · 𝅘𝅥 · 𝅗𝅥 · 𝅝) and
  **accidental** (♮ · ♯ · ♭) first as the "pen."
- **Select** — every tap **snaps to the closest note** and rings it (tap more to build a
  multi-selection), or flip to **Bars** to grab a whole bar's notes in one tap. Under the switcher,
  **◀ / ▶** move a **cursor** one note (or one bar) at a time and select it — entering Select drops
  the cursor on the **last note** — and **＋ Bar / − Bar** grow or trim empty trailing bars (moving
  the cursor ▶ past the end adds one automatically).
- **Move** — nudge the whole selection **±a semitone** or **±a step** in time, or **Duplicate** it a
  bar later — all with buttons, so there's no fiddly dragging fighting the scroll.
- **Edit** — set the **length** and **accidental** (a flat draws as a real flat, not a sharp) of
  everything selected, or **delete** it.

An **Undo** button steps back through your edits one at a time (⌘Z on a Mac / iPad keyboard), and a
**Cancel** button throws the whole edit session away and restores the take exactly as it was before
you tapped Edit — and Replay and the PDF/MIDI export follow whatever you keep.
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

## Demuxer — take a record apart

The **sixth sub-tab** points the Studio the other way: instead of building something new, the
**Demuxer** takes existing audio **apart**. Pick a source from the picker's three groups —
**Imported audio** (your imported files), **Performance media** (a sample, loop or take), or
**Tracks** (a catalog track; burned ones listed first, with the same **burn-on-demand** ladder the
sampler uses; a track with no prepared audio is honestly "nothing to demux", never a silent fetch).
Each group is **collapsed by default** — the same tidy, remember-what-you-opened behavior as the
collection's playlists and pockets — and a **search** auto-expands them so nothing hides behind a
closed group. The chosen source resolves to a local file whose 0:00 is the *song's* 0:00 (an analog
album side is carved to just this song, once).

**The timeline.** A scrubbable **waveform** with the **chord timeline** laid over it as colored
blocks — the dominant chords, heard **on the device** (a chromagram detector, no server). **Tap
a chord block** for its detail sheet: the chord as **notation** on treble and bass staves, or as
a **guitar shape**. A transport (play/pause, restart, clock) drives it, and one shared
**Follow** toggle keeps every panel — timeline, drum grid, score — scrolled to the same
playhead, even while paused and scrubbing.

**Stems.** Flip the **Stems** switch and the four separated parts (**drums · bass · vocals ·
other**) become live **mute/solo rows**. Stems degrade gracefully: already **burned** → play
now; **stemmed server-side** → one-tap download; **not stemmed yet** → create them on the
import server (custom audio uploads your local file for separation). There is **no on-device
separation** — Demucs runs on the server — so with no server configured the panel says so
plainly.

**Lyrics.** A catalog song with a **cloud lyrics sidecar** (whisper, transcribed from its
vocals stem by the offload workers) fetches it automatically — timed **karaoke words** you can
tap to jump the playhead, with **Regenerate** always one tap away. A source *without* a cloud
sidecar gets a **Generate lyrics** button instead: it runs the **on-device transcriber over the
burned vocals stem** (far better recognition than the full mix, which is why it asks you to
download the stems first), words appear **as they arrive**, and the button honestly becomes
**Regenerate**, **Retry** (nothing recognized — probably instrumental) or **Resume** (a run the
app died in the middle of picks up where it left off).

**Drum pattern.** With the stems on the device, **Extract drum pattern** listens to the drums
(+ bass) stems and lays the hits out on a **bar-by-bar grid** — **kick · snare · perc · other**
lanes plus a **bass** lane — on the song's *measured* downbeats when it has a beat-grid
sidecar, an estimated grid when it doesn't. Then the remix move: **Send bar N to Sequencer**
exports the selected bar as a real **16-step pattern**, complete with kit samples carved from
the song itself — and from there the sequencer's **retarget** menu morphs any lane onto a
sample cut from a *different* record.

**Instrumental & melody.** Two panels turn the analysis into something you can *play*. The
**chord-comping instrumental** needs no stems at all — it beat-quantizes the chord timeline
into full triads on the song's grid, shown as synced **bars + a scrolling score** under the
shared Follow. The **melody** panel needs the stems: **Extract melody** pitch-tracks the
**vocals** stem (or "other" when there's no vocal) into a single-voice line on the same synced
score. Either one, **Extract** hands off a real take to **Instruments ▸ Instrumentals** — edit
it on the staff, change its sound pack, sample it, file it in a collection. And because the
take remembers its demux source, its context menu can later **switch modes** — comping ↔
melody — re-extracting the other reading of the same song in place.

**Cut sample.** A **scissors** row drops you into the sampler's region editor over *this*
audio — a catalog song gets the full carve flow (stem-mix included), an import or Studio item
gets in/out points over the file — closing the loop back to the start of this chapter.

**Affordances**
- **Source picker** — burned-first tracks, Performance media, Imported audio; search across all three.
- **Chord timeline** — on-device detection; tap a block for staves or a guitar shape.
- **Stems switch** — live mute/solo; download or create stems on the import server.
- **Generate lyrics** — on-device transcription from the vocals stem; cloud sidecars fetched automatically; Regenerate / Retry / Resume.
- **Extract drum pattern** — lane grid on measured bars; **Send bar to Sequencer** with carved kit samples.
- **Extract instrumental / melody** — chord comping (no stems) or pitch-tracked melody (stems) → a take in Instruments; comping ↔ melody switchable later.
- **Cut sample** — the region editor over the loaded audio.

**User story:** "I load the record, watch its chords roll by, solo the drums, pull one bar out
as a pattern, extract the melody as a take I can edit on the staff — and generate the lyrics
from its vocal stem — all off the same screen."

---

## Tracks — a multitrack arranger

Everything you make in the Studio wants to play *together*. **Tracks** (⌘7) is a lightweight
**multitrack arranger**: stacked **lanes** you lay clips onto, a shared timeline, and one **Play** that
sums them all. Its icon says it best — **four bars in the stem colours** (drums · bass · other ·
vocals), each **broken into discontinuous segments**, because a track is silence *and* sound: the gaps
are where the singer isn't singing, where the piano rests.

**Arrangements.** You work inside a named **arrangement** (it starts you on "Arrangement 1"); the menu
at the top switches, creates, renames, and deletes them, so a whole song idea — verse take, drum
loop, bass sequence — lives as one arrangement you can come back to.

**Tracks.** **＋ Track** adds a lane. Each lane carries a **mix strip** — **M**ute, **S**olo, and a
**gain** slider — plus a row menu to **rename**, **duplicate** (a real copy — its clips get their own
audio, so editing one never touches the other), or **delete** it.

**Clips — from anything you've made.** Tap **＋** on a lane and pick from a source list: any **sample,
loop, sequence, or instrumental** you've built. The Studio **bakes it into the lane** as a clip — an
**immutable snapshot**, so later tweaks to the original never disturb what you placed (re-add it to
pick up an edit). Each clip shows its **waveform** in the track's colour; **drag** it along the
timeline to slide it earlier or later — the empty space you open up *is* the gap.

**Record straight into a lane.** A lane's menu ▸ **Record** captures the **mic** right onto that track;
stop, and the take lands as a clip at the end of the lane.

**Play it.** **▶** starts every lane together, sample-locked, with a **playhead** sweeping the
timeline and a running **m:ss**. **Mute**, **solo**, and **gain** move the mix **live** while it plays.

**Bounce it down.** When the arrangement sounds right, **Bounce** mixes it to a single **master track**:
one lane's **Bounce this track**, the transport's **Bounce ▸ all tracks**, or **Bounce ▸ selected…**
(tick the lanes you want) — each drops a new **Master** lane holding the mixdown, ready to play, bounce
again, or build on.

**User story:** "I drop a drum sequence on lane 1, a bass loop on lane 2, sing a hook onto lane 3, nudge
the hook a bar late so it lands on the drop, solo-check each part, then bounce the whole thing to a
Master I can keep."

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
**samples**, **loops**, **sequences**, **takes** — plus **usage rows** for those four and for
**instrument packs**, and a **delete-all** for each family. **Instrument packs stay
app-managed** (no folder to lose them in; a take records into app storage and only *moves* to
your folder once it's cleanly finished), and the same safety rules as your burns apply: the Studio
**only ever counts and deletes files it wrote**, so your own audio in a folder you pointed it at is
never touched, and it **never auto-prunes** anything you made.

**Affordances**
- **Add-to sheet** — lists samples, loops, sequences and instrumentals alongside songs.
- **Kind badge** — Sample / Loop / Sequence / Instrumental, on every studio row.
- **N× repeat capsule** — tap for presets (1/2/3/4/6/8/16); also on the row's context menu.
- **PocketDJ name** (Settings) — the artist credited on your studio rows; blank shows "Studio."
- **Camelot key** — detected on-device when an item joins a collection, enabling Mix-deck loading and glide.
- **Storage folder pickers** — per-family location + usage + delete-all for samples, loops, sequences, takes.

**User story:** "My loop sits in tomorrow's warmup playlist right next to real records, set to play
twice before the set moves on, its key already worked out so it glides into whatever's next on the
deck — and when I hit *Rip collection* or export the CSV, PocketDJ knows it's mine and leaves it
alone."
