# Mix & Stems — The DJ Engine

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). Everything else gets you
> to a *set* — a crate explored, a playlist shaped, a set list ripped and burned for
> offline. **This chapter is where you actually mix it.** The native iPhone / iPad / Mac
> app carries a top-level **Mix** tab — a real **two-deck DJ console** — and **stems**: a
> track split into four parts (**vocals · drums · bass · other**) you can mute, solo and
> remix live. Both run on the *same* burned, on-device files everything else uses —
> nothing here streams — so a mix, stems and all, works in a basement with no signal. The
> Mix engine is **app-scoped**, so a mix keeps playing while you leave the tab and come
> back. The systems-side complement is
> [the Mix engine (architecture)](../architecture/04-performance-engine.md#7-the-mix-engine--the-two-deck-dj-board-native).
> These sections are prose-only — no screenshots captured yet.

## The Mix tab — two decks, one screen

The Mix tab is a **DJ main screen**: **two decks** — **Deck A** and **Deck B**, equal width — with
**one crossfader** spanning both beneath them and **one big master Play/Pause** at the bottom. On iPad
and Mac it's roomy and centered (the controls cap at a comfortable width), with the two decks side by
side.

**Deck layout (iPhone / iPad portrait).** In portrait you choose how the two decks are arranged, from
**Settings ▸ Mix ▸ Deck layout**: **Stacked** (the default) puts full-width decks one above the other,
so the sliders are finger-friendly; **Side-by-side** is the classic two-up board; and **Single** shows
one deck at a time flanked by tall **‹ ›** switch buttons (either chevron flips to the other deck, so
whichever thumb is nearer works) with **A · B** page dots beneath. Because the Mix engine is
app-scoped, the deck you *aren't* looking at in Single mode **keeps playing** — only its view is put
away, never its audio. iPhone **landscape** always uses side-by-side (there's width for it), and macOS
is always side-by-side.

**Load a track.** A deck plays a **burned / local** track — only **on-device (burned)** songs can be
mixed (the engine never streams). Each deck header carries a **deck letter** and a quick **source
menu** to point that deck at a **pocket** or **set list**; the two decks can share one source or each
hold its own. **Tap the header** (or **long-press / right-click** it) to open the **track-loader
sheet** — a searchable picker (by **artist · title · album**) of that source's burned tracks. If the
collection isn't burned yet, the sheet says so: *only burned songs can be mixed — burn the collection
first.* Tracks you've already spun this session are **hidden from the loader** by default — a
**"Show N played"** toggle brings them back, each marked ✓ (**Settings ▸ Mix ▸ Auto-hide played
tracks** turns the hiding off).

**The header reads like a deck.** Once loaded it shows a **waveform** image, the **album artwork**,
the **title · artist**, and a **key + BPM** readout — the Camelot chip when known, beside the
**measured beat-grid BPM** to one decimal (the exact number Sync beat-matches on, falling back to the
rounded catalog BPM) — so each deck shows at a glance what's cued and whether the two will mix.

**User story:** "Give me two real decks on my phone, loaded straight from the crates I already burned
for offline — pick a pocket per deck and drop a record on each."

---

## Per-deck controls — seek, tempo & pitch

Under each deck's header sits its control stack:

- a **seek scrubber** — drag to seek (sample-accurate), with **elapsed / duration** clocks at its
  ends,
- **jump-to-cue buttons** — if the loaded track has cue points (dropped in the Performance ▸ Cues
  tab — [Cue points — tap to drop the needle](studio.md#cue-points--tap-to-drop-the-needle)), they appear right under the scrubber as up to eight **colour-coded chips** (two rows of
  four, each chip the cue's stable colour); tap one to **jump the deck straight to that cue**,
- the **Lead · Sync · Reset** row (beat-matching — [Lead & Sync — beat-matching to a reference deck](#lead--sync--beat-matching-to-a-reference-deck); the **Stems** toggle joins it for a stemmed
  track — [Stems II — the Mix stem decks](#stems-ii--the-mix-stem-decks-the-coloured-22-grid) — and
  the **∞ loop** and **🎧 cue (PFL)** chips ride the same row, both below),
- a **Tempo** slider — live **time-stretch** from **0.5× to 2.0×** with **pitch preserved**,
- a **Pitch** slider — **±12 semitones** with **tempo preserved** (independent of the tempo slider),
- a **VU meter** — a level bar above the volume slider showing how hot the deck is running, with a
  live peak-dB readout; **long-press** (iOS) / **right-click** (macOS) it to switch between a
  **PRE-fader** reading (the deck's level *before* the volume/crossfader — for gain-staging) and a
  **POST-fader** reading (what the deck actually sends to the mix, the default),
- a **Vol** slider — **0–200%**: past 100% it's a real **gain boost** (the value turns gold with a
  **+dB** readout — not colour-only), backed by the deck EQ's global gain and a **master limiter**;
  a drag **snaps to unity** as it passes 100%,
- a **per-deck play/pause** for cueing one side on its own.

Every deck slider (Tempo · Pitch · Vol) is bookended by **− / ＋ steppers**, so a value can be
nudged one step at a time when a finger-drag is too coarse.

**Reset (↺)** wipes the deck back to neutral — clears tempo, pitch, every effect and the volume trim,
then rewinds — so you can recover a deck to a clean state in one tap. **Long-press** (iOS) /
**right-click** (macOS) the ↺ opens a **"Clear deck (eject track)"** action that goes one step
further: it **ejects the loaded track entirely** — stopping playback and returning the whole deck to
its **empty zero state** — for when you want to start the side over from nothing, not just re-neutralise
the track that's on it.

**Loop (∞).** Right of the stem toggle sits the **∞ loop** chip. **Tap** it and the deck snaps back
to the previous boundary and repeats a **2-unit loop** — **2 beats** when the track has a beat grid,
**2 seconds** when it doesn't; tap again to release. **Long-press** (iOS) / **right-click** (macOS)
opens a fixed-width popover with a **1–32** length slider plus **← →** nudges that walk the loop's
**start** and **end** edges one unit at a time (touching any of them engages the loop — you dial
what you can hear). Repeats are **pre-queued so the seam never clicks**, a **stem deck loops all
four stems in sync**, and an engaged loop is treated as a **hand-mix hold** — the Auto-DJ never
crossfades out from under it until you release.

**Cue (🎧 — pre-fade listen).** Just left of Reset, the **headphones chip** sends that deck to the
**cue channel**, so you can monitor it without touching the house mix; **long-press / right-click**
opens its own **cue-level** slider, independent of the deck's Vol fader. The cue is a **stereo
channel split**: **Settings ▸ Mix ▸ Cue output channel** routes the cue to one side (default
**right**) and leaves the house mix on the other — a splitter cable gives you a booth feed. It's
also why a recorded mix never contains what you were cueing ([Record your mix — the session recording](#record-your-mix--the-session-recording)).

**User story:** "Stretch a track to match a tempo without chipmunking it, nudge its key by a few
semitones to mix in harmonically, scrub to the drop — reset the deck clean when I want to start over,
or hold Reset to eject the track and clear the deck completely."

---

## The effects grid — tap to toggle, dial the strength

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

## The crossfader & the master transport

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

## Lead & Sync — beat-matching to a reference deck

Tap **Lead (★)** on a deck to make it the **tempo reference** — it's **exclusive** (tapping the
current Lead clears it). On the *other* deck, **Sync** matches its **tempo** (playback rate) to the
Lead's **effective BPM**, **octave-folded** into the 0.5–2.0× range — so a 70-BPM track half- or
double-times to lock against a 140 — then **best-effort phase-aligns the downbeats**.

Crucially, the match prefers each song's **MEASURED beat-grid BPM** (from the rips indexer, measured
on the *exact* burned file) over the catalog's **rounded** BPM — so a sync doesn't slowly drift the
way it would off a `120`-vs-`119.7` rounding error. **Sync** is only enabled when there's a Lead that
isn't this deck and **both decks have a known BPM**.

**See the beat — the pulse ring.** Flip on **Settings ▸ Mix ▸ Beat pulse** (off by default) and each
deck's border **flashes on every beat** — downbeats brighter — **phase-locked to the true audio
playhead** on the track's real measured beat grid, so even a tempo-drifting record pulses on its
actual beats and you can eyeball-align the two decks while beat-matching.

**User story:** "Pick one deck as the reference, hit Sync on the other, and have it actually lock —
to the tempo I measured off the record, not a rounded guess — with the downbeats lined up to mix on."

---

## Auto-Mix — the auto-DJ

A **Manual / Auto** toggle sits in the Mix toolbar — one tap flips the mode. In **Auto**, pick a
**collection** (a pocket or a set list) from the toolbar picker, then hit **▶ Play** (in listed
order) or **🔀 Shuffle**. The engine plays the whole collection **end-to-end across the two decks** —
**auto-loading the next track** onto the free deck and running a **timed crossfade** between them
(the lead-in and fade lengths come from Settings).

**Crate A + Crate B.** The setup row has two pickers — **A** and **B** (B defaults to *Same as A*).
Pick two different collections and the mix blends them: each crate shuffles on its own and the queue
alternates A, B, A, B… (a song in both plays once). Same crate-per-deck mix the Apple TV and CarPlay
Mix tabs offer, now on iPhone, iPad, Mac and Vision Pro.

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
    ([Lead & Sync — beat-matching to a reference deck](#lead--sync--beat-matching-to-a-reference-deck)), pulling the two tempos together on the **beat grid** with a best-effort **downbeat align**,
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
your hands-on stretch gets repeated. Pause and Resume both drop a marker on the session timeline ([Replay a session — the move-by-move timeline](#replay-a-session--the-move-by-move-timeline)),
so a replay shows exactly where you took over and handed back. Perfect for a long night: *auto-mix →
Pause for a bathroom break's worth of hand-mixing → Resume → repeat until sunrise.*

**Auto mode points both decks at the collection.** The moment you're in Auto with a collection chosen,
**both decks' load-source is set to that collection** — so when you Pause and want to hand-load more
tracks, the track browser is already scoped to the right crate on each deck, no re-picking.

**Skip — advance on your schedule.** While the Auto-DJ runs, a full-width **"Skip to next"** button
sits under the master transport. A **single tap** crossfades to the next queued track over the
**Settings ▸ Mix skip-fade** (default **15 s** — a deliberate, musical switch); a **double-tap** runs
the **fast 5 s sweep**.

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

## Stems I — the SongDetail stem-audition panel

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

## Stems II — the Mix stem decks (the coloured 2×2 grid)

On the Mix tab, load a **stemmed + burned** track onto a deck and a **"Stems"** toggle appears
**between Sync and Reset**. Tap it — it **burns the 4 stems first if they aren't on disk** (a brief
spinner) — to enter **stem mode**, which reveals a **2×2 STEM GRID** under the effects:

- **Vocals (purple) · Drums (yellow) · Bass (red) · Other (green).**

The four stems play **in sync through the deck's effects + crossfader** — so the **tempo, pitch, the
effects grid and the crossfade all act on the stem mix**, exactly as they do on a normal track.
**TAP** a pad to **MUTE** that stem (it **greys out**, with a speaker-slash); tap again to unmute.
**LONG-PRESS / RIGHT-CLICK** a pad for that stem's **VOLUME**. The grid **only shows in stem mode**,
so a normal deck stays compact.

The volume control follows the same screen-aware split as the effects ([The effects grid — tap to toggle, dial the strength](#the-effects-grid--tap-to-toggle-dial-the-strength)): **iPhone portrait** opens
the per-stem slider as a **fixed-width popover** (the in-place flip is too narrow to drag there,
dismissing on outside-tap or after 3 s idle), while **landscape / iPad / macOS** flip the pad **in
place**.

**User story:** "Drop a stemmed record on a deck, tap Stems, and now I'm muting the vocal and
riding the bass right inside the mix — through the same effects and crossfader as everything else."

---

## Stems III — burn a collection's stems · mix entirely offline

Stems are only useful in the field if they're **on the device**, so **burning a collection now also
pulls every stemmed song's 4 stems** into the burn folder — alongside the audio and sidecars ([Burned files are named so you can mix from them](play-rip-burn.md#burned-files-are-named-so-you-can-mix-from-them),
[Analog cut export — the full single-track list for your DJ software](play-rip-burn.md#analog-cut-export--the-full-single-track-list-for-your-dj-software)). The result: a **burned collection plays *and* mixes entirely offline**, stems included.

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

## The Mix mini-panel — deck powers on the Now Playing screen

You don't have to open the Mix tab to reach the DSP. The **Now Playing deck** carries a collapsible
**"Mix" mini-panel** (a chevron header, collapsed by default) exposing **Tempo · Pitch · Gain**
sliders (the same ranges and − / ＋ steppers as a Mix deck), the same **2×2 effects grid**, and —
when the current track's stems are burned — a **Stems** toggle with the four mute / volume pads,
all acting on the **track that's playing right now**.

It appears **only when it can actually work**: the current track must be a **local (burned / mixable)**
file, and no Mix-tab session may be actively playing (one DSP surface at a time). Otherwise the
section is **hidden entirely — never greyed**. The **first control you touch** performs a
**swap-on-touch hand-off**: the track's audio moves from the plain player into the mix DSP graph
**at the current position** (a small "engaged" dot lights on the header), and from then on every
tempo, pitch, gain, effect and stem move is live. The tweaks are **ephemeral** — everything resets
to neutral on the next track, so a nudged pitch never haunts the rest of the set list.

**User story:** "The song playing right now needs the vocal dropped and a little more low end —
flip open Mix on the Now Playing screen, mute the vocal stem, ride the gain, and it all snaps back
to normal on the next track."

---

## Record your mix — the session recording

Every sitting at the decks is a named **session** — a pill at the top of the Mix screen shows the
current session's name (**tap to rename**; **long-press / right-click** for the full menu: Rename ·
New Session · All Sessions). The toolbar **✕** files the current session away to Sessions and opens
a fresh one.

A **record button** (the ⏺ record icon) sits in the **Mix toolbar**. Tap it and it **pulses a purple→
red gradient** while it captures the **audio of your mix** — the house output, exactly what an audience
would hear (your monitoring **cue** in the headphones never leaks in). A live **"● Recording m:ss"**
strip shows the elapsed time with a **Stop**, so on an iPhone the state and the stop stay visible even
if the toolbar tucks the button away. Tap the button again (or Stop) to end the capture.

Recordings are filed **per session** into a **session folder** — one subfolder per mix session, so
each sitting keeps its own takes (and there's room to grow other session data later). By default that
lives in the app's private storage; in **Settings ▸ Storage** (the storage manager, [Settings ▸ Storage — the storage manager](native-and-system-integration.md#settings--storage--the-storage-manager)) you can
**pick your own folder** (just like the burnt-music folder) to browse the `.m4a` files yourself in
Finder / the Files app.

**It's written to survive a crash.** The take isn't held in memory and flushed at the end — it's
**streamed to disk continuously** (fragmented AAC), so if the app is killed, runs out of disk, or the
phone dies mid-set, **whatever played up to that moment is already a playable file**. On the next
launch the app **re-files any interrupted take** back onto its session automatically — from whichever
screen you open, and even a take that was mid-capture when you **quit the app** is filed on the way
out — so a crash never loses the recording.

**And it survives everything short of a crash, too.** Yank the headphones, switch to the speaker, hop
between Bluetooth devices mid-set — on the Mac, pick your AirPods from the menu bar and back again —
the audio engine the system kills comes **back by itself** within a beat, the mix picks up where it
stopped, and the take keeps rolling (dead air is never silently written into it — even the sneaky Mac
case where a deck *claimed* to be playing while producing silence is detected and revived). A
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
recordings** ([Settings ▸ Storage — the storage manager](native-and-system-integration.md#settings--storage--the-storage-manager)).

**User story:** "Hit record before I start the set, let the mix run, and stop when I'm done — then
play the whole thing back from Sessions and scrub to any moment, or grab the file from my own folder
to share. Even if it crashes, the recording's still there."

---

## Replay a session — the move-by-move timeline

Every mix also records the **moves themselves** — each load, play/pause, seek, tempo & pitch change,
volume, **crossfader**, effect, stem action, Lead/Sync and Reset — into a **time-stamped timeline** on
the **Sessions** screen, so a set can be **replayed move by move** (the raw material for later training
an auto-mix model). The timeline is built to actually read:

- **It wraps to fill the screen** instead of scrolling forever to the right — **5 moves per row on
  Mac, 3 on iPad** (iPhone lays the cards out one per row, top to bottom) — with **arrows between the
  nodes** (→ along a row, then ↵ down to the next) so the **left-to-right-then-down** order is
  unmistakable.
- **It plays back against the clock.** A replay transport up top — **▶ / ⏸**, a **scrub slider**, and
  a **0.5× / 1× / 2× / 4×** speed menu — walks the highlight through the moves in recorded time,
  auto-scrolling the timeline to the current action; tapping any non-load node jumps the replay
  playhead to that moment.
- **Glides are one compact node, not a blur of ticks.** An auto-mix bend (or a crossfade) — which is
  thousands of tiny moves under the hood — shows as a single **"glide"** node reading **from → to**
  with its **average rate of change**, so an automated sweep reads as one gesture, while a human's
  subtler hand-moves are still captured change by change. (The **crossfader** is captured the same way.)
- **Tap a "load" node** (long-press isn't needed — a tap) and the track's **song-metadata card** pops
  up, so you can see exactly *what* was dropped at that point in the set.

A session's **played tracks** also export as a **tracklist CSV** — named after the session — from
the session screen's toolbar, the universal hand-off to notes, a promoter, or another DJ tool.

**User story:** "Open a past session and actually read it — the moves wrap across the screen in order,
each auto-glide is one clean from→to node instead of a thousand ticks, and I can tap any track I loaded
to see what it was."

---

## Your decks survive a restart — durable mix sessions

Kill the app mid-mix — swipe it away, let the phone reboot, whatever — and **reopen onto the
Mix tab: the board is back exactly as you left it**. Both decks re-loaded with their tracks,
playheads **cued to the second you left them**, volumes, tempo and pitch bends, effects and
their strengths, stem mutes and levels, the crossfader position, the Lead badge — all of it.
An Auto-DJ that was running comes back with its **whole queue intact** — including every song
your Jukebox Hero guests slipped into it — **suspended**, showing "Auto-mix paused" with the
same up-next it had. Nothing is rebuilt from memory or a session log: the live mix **writes
itself down as you work it** (deck loads and queue changes instantly, slider sweeps as one
note per gesture, playheads every few seconds), so there is nothing to lose at the moment of
the kill.

The same two rules as the Now Playing deck's restore keep it honest:

- **Reopening never blasts audio.** Everything comes back *held* — decks cued, the big
  transport still reading **Play both decks**, the Auto-DJ machine frozen. It never resumes
  itself: *you* hit a deck's ▶, the master Play, or the banner's **Resume** (which picks the
  mix up mid-song, right where it was cued, and re-arms the auto machine against what's
  actually playing). The lock-screen card stays empty until real sound starts — and if a
  restored *set list* session is also waiting, both sit held side by side; whichever you play
  first owns the card.
- **It only restores what's actually there.** Eject both decks (or nuke everything from
  Settings) and the session is cleared — the next launch opens a clean board. A track whose
  burned file vanished in the meantime simply leaves that one deck empty; the rest of the mix
  — the other deck, the queue, the mixer — still comes back. Cue points, beat grids and the
  pulse re-derive from the burned analysis files, and a recording that was running is handled
  by the recorder's own crash recovery (the take survives too — see above).

**User story:** "I was two hours into an Auto-DJ set with a dozen guest requests queued when
the phone died. Rebooted, opened the Mix tab — both decks were sitting there cued mid-song,
queue untouched, still paused. Hit Resume and the room got the same set back."
