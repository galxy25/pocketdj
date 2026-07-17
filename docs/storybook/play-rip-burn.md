# Play, Rip & Burn — Making the Catalog Audible

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). A metadata catalog you can
> only *look at* isn't a DJ tool — this chapter is how PocketDJ makes the crate **audible
> anywhere**. Any song streams or downloads on demand: on a cache miss the iMac **rips**
> it (analog from a vinyl recording, Apple Music in real time) to a public S3 cache and
> live-streams it back while it captures. From there a whole set can be **ripped**,
> **burned** onto the device for a venue with no signal, played back as a transport that
> survives the lock screen, and named so you can mix straight from the files. The
> systems-side complement is
> [Playback & Rip-on-Demand](../architecture/05-playback-and-rip-on-demand.md). The first
> section shows the web mini-player; the native inline player and the offline / transport
> surfaces are described in prose.

## Stream & download — rip on demand

The offline-first crate is **playable end to end**. Any song or album can be
**streamed or downloaded** from a ▶/⤓ button: on a cache miss the app asks the iMac
(over Tailscale) to **rip** the track — analog from a local recording, Apple Music in
real time via Audio Hijack — upload an **mp3** to a public S3 cache, then stream it
back. Rip once → instant forever (and playable anywhere, since the cache is just S3).

### ▶ / ⤓ on every song & album + a mini player

![Rip buttons + mini player](32-mini-player-mobile.png)

Each song row and album card gets **▶ Play** and **⤓ Download**. Tap ▶ and — if it
isn't already ripped — the button shows the live phase **Searching… → Ripping mm:ss →
Uploading…** (polled from the rip server), then a **mini player** docks at the bottom
with **⏮/⏭** and **auto-seek** to the track inside a whole-album rip. Already-ripped
songs play instantly.

**Audio analysis + waveform scrub.** Every ripped song is analyzed in the background:
**BPM, musical key & Camelot** are computed (librosa) and **rolled into the default
index** — so they're filterable, sortable, on the star map, and in song detail, just
like the rest of the catalog (existing audio-stage values are kept; only gaps are
filled). A **waveform** image is generated (ffmpeg) and uploaded alongside the rip;
the player lazy-loads it (like cover art / lyrics) and renders it as a **clickable
scrub bar** — click anywhere on the waveform to seek. The same analysis runs on songs
ripped via the **`rip` skill** (a setlist's `_ripped/` folder) through the batch tool.

### Play while it rips — live streaming

Tapping ▶ on an un-ripped Apple Music song **plays within a few seconds and
follows the real-time capture**, rather than waiting the full capture + upload. As
Audio Hijack records, the server segments the growing audio into a **live HLS** stream
(`tail | ffmpeg`, 2 s AAC segments + a rolling playlist) and serves it over Tailscale;
the player shows a red **● LIVE** chip. HLS is used because iOS Safari plays it
natively (a plain progressive stream is silent on iOS); desktop browsers without
native HLS use a lazy-loaded `hls.js`. When the rip finishes it uploads the durable
mp3 to S3, so every later play is the **seekable** cached file (with the
waveform). Analog stays rip-then-play (already faster than real time).

The app and rip server do a small **version handshake** (`/health`): if the server is
reachable but **outdated** (e.g. its process predates a code update), the app shows a
transient banner — *"Rip server is outdated — restart it for live streaming"* — that
auto-dismisses after 5 s, instead of silently failing to stream.

### Settings ▸ Rip server

![Settings: rip server](33-settings-rip-server-mobile.png)

Point the app at the **iMac running the rip server** — its Tailscale HTTPS URL
(`https://…ts.net`) from your phone, or `http://localhost:8787` on the same machine —
and **Test connection**. The rips live in a public S3 cache (deterministic
`rips/<id>.mp3`), so the server is only needed to *create* a rip; once ripped, a song
plays from anywhere even with the server off.

### Setlist ▸ Rip all · Play all · Burn

![Setlist rip actions](34-setlist-actions-mobile.png)

A realized set list gains three actions: **⬇ Rip all** (rip every track so playback is
instant), **▶ Play all** (play the set start→finish, **ripping ahead** so the next
track is ready before the current ends, auto-advancing the mini player), and **🔥 Burn**
(rip any that aren't yet, then download the whole set as one **zip**). Progress shows
as *Ripping / Burning N/M*.

---

## The inline player — play, stream, download, scrub

Every song row in the native app — in the Browser **and** in an album's track table —
has a **▶ play** and **⤓ download** button on the right (the `RowTransport`). They're
the same rip-on-demand transport the PWA mini-player uses, but the player itself docks
**inline, directly below the row you played**.

**Play.** Tap **▶**. **Apple Music (Local) songs now stream straight from Apple
Music** — when the app can find the track in the Apple Music catalog (and you've
linked Apple Music in Settings, [Settings ▸ Streaming accounts — link Apple Music](native-and-system-integration.md#settings--streaming-accounts--link-apple-music)), tapping ▶ plays it instantly from your
subscription via MusicKit, no ripping involved (the player shows a *"via Apple
Music"* backend). Only when there's no catalog match (an obscure pressing, a
region-gated or removed track) does it **degrade to ripping** — so a song *always*
plays, but the common case is an immediate Apple Music stream rather than a
multi-minute capture. If the song is already ripped it plays instantly from the cache;
otherwise the button shows the live rip phase — **Queued… → Searching… → Ripping mm:ss →
● Streaming live → Uploading…** (polled from the rip server) — and, for an un-ripped
track that fell back to ripping, begins playing the **live HLS** stream within seconds
while the capture continues (a red **● live** chip). When the row is the one playing,
**▶ flips to a pause/resume toggle** for that same player instead of re-resolving.

**The slide-out panel.** Below the playing row a panel appears with:
- a **play/pause** button, the **title · artist**, a **chevron** to collapse/expand,
  and an **✕** to close (stop + dismiss),
- a full-width **waveform** image (lazy-loaded, like cover art) sitting **edge-to-edge**
  above a full-width **scrubber** — drag the slider to seek; elapsed / duration labels
  flank its two ends,
- for a live stream, instead of a scrubber: a *"Streaming live as it rips"* state (a
  live HLS stream has no fixed length to scrub).

The position updates ~4×/s smoothly without the buttons ever going "dead" — a subtle
but real win the desktop build needed (the scrubber redraws on its own clock so it
never disturbs the control buttons' taps).

**Download.** Tap **⤓** to resolve the durable mp3 — ripping it on demand first if it
isn't ripped yet (the button shows the same live rip phase: *Searching… / Ripping
mm:ss / Uploading…*) — then a native **save-location picker** opens so you choose
*where* the file lands (the **NSSavePanel** on macOS, the document picker in export
mode on iOS/iPadOS), pre-filled with an `Artist - Title.mp3` name. The OS writes the
mp3 to the spot you pick; cancel or an error just resets the button.

**Lock screen & Control Center.** Native playback registers with the OS, so the
current track shows on the **lock screen / Control Center** — **with its album cover**
when the track's album is in the catalog — and working play / pause / scrub (AirPods
and CarPlay drive it too); audio keeps playing in the background. **This now works for
Apple Music tracks too:** an Apple Music song streams through Apple's own player, which
used to leave the lock-screen / CarPlay card blank and made the set **stop after one
song** — the ⏭ next button did nothing. A set of Apple Music songs now **auto-advances**
on its own, the **card shows the title, artist and cover**, and **⏭/⏮/play-pause** on
the lock screen and CarPlay drive the set the same as a ripped or burned set. Skipping
from the lock screen or the car works too: iOS actually hands that ⏭ to Apple's own
player (which just stops its one-song queue), and PocketDJ notices within half a second
and moves the set to the next track — instead of freezing paused on the old song. **⏮
goes back a track** the same way once you're past the first ~10 seconds of a song
(before that it restarts the current song — the classic near-the-top ⏮ behavior).

**User story:** "I found the record — now let me actually hear it, right here, without
leaving the list — and scrub to the drop."

---

## Rip & Burn a whole set — take it offline

Playing one song at a time is great in the room with signal. But a gig is a *set*, and
the venue might have no signal at all. So every collection you can perform from — a
**playlist**, a **pocket**, a **setlist**, or a whole **source** ("From your sources")
— gets two collection-level buttons in its detail screen: **Rip** and **Burn**.

**Rip = "send the whole set to be recorded."** Tap **Rip** and the app hands the entire
set to your iMac to capture — analog tracks from your vinyl recordings, Apple Music
tracks in real time — and upload each as an mp3 to the shared cache. Nothing downloads to
your phone; this is just *"make sure every track in this set exists as a rip."* Because
ripping Apple Music happens in real time and one track at a time, it **completes over
time** in the background — so the result reads like *"Ripped 8 of 10 — 2 unrippable,
enqueued, completes over time,"* with a **Refresh** to reconcile the final counts later.
Re-tapping Rip on a set that's mostly done is cheap: already-ripped and in-progress tracks
are skipped. (Rip is only offered when you've pointed the app at a rip server.)

> **You usually don't even have to ask.** Whenever you simply *play* an Apple Music track
> in the app, it quietly gets ripped in the background too (no waiting, no prompt) — so a
> set you've been playing through is often already half-ripped before you ever tap **Rip**.

**Burn = "download this set for offline."** Tap **Burn** and the app downloads every
*already-ripped* track in the set onto the device, so the whole set plays with **no
signal and no rip server**. Burn never waits on a live recording — it only pulls tracks
that are already ripped, and reports the rest as *"not yet ripped — Rip first"* (so the
natural flow is **Rip**, let it finish, then **Burn**). Alongside each downloaded track it
writes a plain-text companion with the track's **BPM, key (musical + Camelot), sentiment,
album, and full metadata** — the same kind of mixer-ready sidecar the desktop burn
produces. Burning the same set again is smart: it re-downloads only what's **missing or
stale** (e.g. a track you re-ripped, or whose BPM/key was re-analyzed since), and skips
everything still current. Progress shows as *"Burning 6 of 10,"* ending in a summary like
*"Burned 6 of 10 — 4 not yet ripped."*

**Where you'll see them.** The pair appears on the playlist detail, the pocket detail, the
setlist detail, and the read-only "From your sources" list — anywhere you've gathered a set
worth carrying. Both buttons disable when the collection has nothing rippable in it.

**⏹ Stop — cancel a rip or burn in flight.** While a Rip or Burn is running, a red **Stop**
control stays reachable. Tap it and the in-flight job halts: a **Stop rip** tells the iMac
to drop this set's still-queued and currently-recording tracks; a **Stop burn** ends the
download loop after the current file (so whatever already finished stays on the device). Either
way you get the partial summary so far — handy when you change your mind about a long set
mid-capture, or only meant to grab the first few tracks.

**Live "X of N ripped" — and a Stop that stays put.** A collection **Rip** captures every
track in real time, one at a time, so it finishes *over minutes or hours* on the iMac long
after the app has handed off the set. The app follows that progress: a small **"ripping —
3 of 12 done"** chip ticks up as each track lands in the cache, sitting beside a persistent red
**Stop** the whole time the rip is running — not just for the split-second it takes to send the
set off. When the last track completes, the chip resolves to **"Ripped 12 of 12"**; tap **Stop**
at any point to drop whatever's still queued or recording and keep what already finished.
Rips also **self-heal** server-side — a stuck capture or a briefly-unplugged vinyl drive no
longer freezes the queue, so a long Rip reliably grinds to completion (it just keeps going,
retrying transient hiccups) instead of stalling forever.

**User story:** "I've built the set — now make it bulletproof: rip everything so it's
captured, then burn it onto my phone so it plays in a basement with no bars, every track
carrying the BPM and key I mix on — and let me call it off if I started the wrong one."

---

## Settings ▸ Rip from cloud · burnt-music folder

Two new native Settings controls refine *how* and *where* the app rips and burns.

**Rip from cloud source.** In **Settings ▸ Rip server**, below the URL, a **Rip from cloud
source** toggle changes where a rip comes from. With it **on**, any song that *exactly* matches
a track in your iMac's Apple Music library is captured from **Apple Music itself** (real-time,
one track at a time) instead of from a vinyl recording — so even a set built from the vinyl
crate can be ripped at full digital quality when the same recording lives in your library. When
there's no exact match it **falls back to the vinyl rip** automatically, so nothing is skipped.
The match is deliberately strict: a *remix*, *radio edit*, *live*, or *instrumental* version
won't masquerade as the standard recording (and vice-versa) — only the genuinely-same recording
matches, so a cloud rip never quietly swaps in the wrong version. The setting's footer warns that
because cloud rips capture in real time, one at a time, a large **Rip/Burn can take a while**.

**Burnt-music folder.** A **Burnt music folder** section lets you pick **where burned audio +
their `.txt` sidecars are saved**. By default they live in the app's private storage; tap
**Choose burnt-music folder…** and pick any folder (the system folder picker on each platform)
to have burns land somewhere **you can browse yourself** — in **Finder** on the Mac or **the
Files app** on iPhone/iPad. The chosen folder's name is shown with a **Use app storage** button
to revert. Now the mixer-ready files (audio + BPM/key/sentiment sidecar) are right where you can
drag them into a DJ app or back them up. *(This picker now lives on the **Settings ▸ Storage**
screen — the storage manager, [Settings ▸ Storage — the storage manager](native-and-system-integration.md#settings--storage--the-storage-manager) — together with the session folder and the delete tools.)*

**User story:** "Rip from my actual Apple Music library when it's the same record — and drop
the burned files in a folder I can open, not buried inside the app."

---

## Setlist ▸ ▶ Play — play the whole set in order

A realized set list gains a **▶ Play** button in its toolbar (beside Rip/Burn). Tap it and the
app plays the set **start to finish, in order**, in the inline player — auto-advancing to the
next track as each one ends. For each track it prefers the **burned local file** if you've
burned the set (so it plays with no signal), otherwise it **streams** the rip; a track that
can't be played at all (no rip, no server) is **skipped** rather than stalling the set. The
button flips to **⏹ Stop** while it runs (and reorder/delete are locked so the queue can't
shift under playback). When the current track is a **live** stream — which has no natural end —
a **⏭ Next** button appears so you can advance by hand.

**User story:** "Hit one button and let the set play itself through, in order — the way I'll
actually run it on the night — pulling from what I've burned and skipping anything not ready."

---

## Play mode — the set runs like a music transport (iPhone)

Once a set list is **playing** ([Setlist ▸ ▶ Play — play the whole set in order](#setlist---play--play-the-whole-set-in-order)), the iPhone toolbar reshapes itself into a clean **music
transport**. The three controls — **⏮ previous · ⏯ play/pause · ⏭ next** — move to the **center
of the nav bar**, evenly spaced and accent-tinted, so the bar reads exactly like a player rather
than a row of mixed buttons. Prev/next step the **whole set** (not just the current track); the
middle button toggles **play/pause on whichever backend is live** — Apple Music streaming, or the
rip/local engine — and shows ⏸ while it's playing, ▶ while paused.

**Stop takes the play button's slot.** The **⏹ Stop** that ends the run sits in the **same
trailing spot** that showed **▶ Play** when the set was idle — so the one obvious "start / end the
set" affordance never moves and is never buried. (It is *not* hidden in a menu.)

**Everything else folds into ••• .** While the set plays, the secondary actions collapse into a
single **••• overflow** menu — **Add note**, **Rip**, **Burn**, **Rename**, **Edit order**
(present but **disabled** mid-play, since reordering would desync the running queue), and a
**Delete set list** below a divider. **Rip and Burn are two separate, flat menu items**, not a
nested "Rip / Burn" submenu — one tap each.

When the set is **idle**, the iPhone bar stays the familiar flat layout (▶ Play · the
device/cloud toggle · Edit · •••). And the **Mac keeps its flat toolbar** in every state (it has
no centered nav-bar slot) — play/stop with ⏮/⏭ flanking it while running, and the secondary
actions laid out in a row.

**User story:** "When the set is actually playing, give me a real transport — prev, play/pause,
next, centered — and tuck everything else out of the way so I'm not fat-fingering Delete reaching
for Next."

---

## The set advances at each track's *own* length

A whole side of vinyl is ripped as **one mp3**, with every song pointing at its **start offset**
inside that shared file. Left to itself the auto-advance would only fire at the **end of the entire
album file** — a set built from analog tracks would play one song, then keep rolling straight into
the *next* album track. Instead, each playing track **advances at its own end**: the player arms a boundary at *this song's
start + its known length*, and when playback passes it the set moves on to the next entry — even
though the audio file keeps going. Per-song files (digital rips, individual burns) are untouched:
they have a real end of their own, so they advance naturally and are never cut short by a missing
or short catalog length. The same length-aware advance works whether the track is **streaming a
cloud rip**, **playing a burned file**, or sitting **inside a shared album rip** — so a set plays
through cleanly regardless of where its audio comes from.

**Tap a row mid-set and the set follows you.** If a set is running and you tap **▶** on a *row
that's in that set*, the set **repositions onto it** and keeps auto-advancing from there — instead
of the set silently stopping when that hand-started track ends. (If the same song appears more
than once, it jumps to the **nearest occurrence**, preferring the one ahead of where you are.) The
persistent **⏮ / ⏭** transport ([Play mode — the set runs like a music transport](#play-mode--the-set-runs-like-a-music-transport-iphone)) is always there to step by hand.

**User story:** "Each track should hand off to the next one at *its* end, not the end of the whole
record side — and if I tap a song in the set to jump there, the set should pick up from that song,
not quit on me."

---

## Keep going in the background — rips, burns, downloads & playback don't stop when you leave

Capturing a whole set or burning it for offline takes real time — minutes for a long Rip,
a steady download-by-download grind for a Burn. Leaving the app — switching to Messages, locking
the phone, letting the screen sleep — doesn't interrupt it: the native app keeps the long jobs
**alive in the background** so you can start something big, pocket the phone, and come back to it
done.

**Rips, burns & downloads continue while the app is backgrounded or locked.** Kick off a
collection **Rip** or **Burn**, or a single-track **⤓ Download**, then switch away or lock the
device — the work keeps running. Downloads and burns hand off to the system so each file
finishes (and the next one starts) even while the app is suspended; a **Burn** that was halfway
through when you locked the phone keeps landing tracks, and you'll find the set fully burned when
you return — its **"Burning 6 of 10"** progress having carried on the whole time. Even a **cold**
relaunch (the system having fully unloaded the app mid-transfer) picks the finished files back up
rather than losing them.

**Setlist playback plays on past the lock screen.** Hit **▶ Play** on a setlist ([Setlist ▸ ▶ Play — play the whole set in order](#setlist---play--play-the-whole-set-in-order)), lock the
phone or switch apps, and the set keeps playing — **auto-advancing from track to track** on its
own. The currently-playing song shows on the **lock screen / Control Center** (and on AirPods,
CarPlay, or a watch) with its **album cover** and working **play / pause / next / previous** —
⏮ goes to the previous track, ⏭ to the next, play/pause touches only the current track — so you
can run the set, or skip ahead, without ever unlocking. This is the whole set sequencing in the
background, not just a single track: each track ends, the next begins, hands-free.

**User story:** "Start a big rip or burn, lock my phone, and trust it'll be finished when I pull
it back out — and once a set is playing, run the whole thing from the lock screen, skipping tracks
from my headphones, without the music ever cutting out because I left the app."

---

## Device / Cloud playback — play burned files or stream

A small **browser-style toggle** now sits on the **setlist, playlist and pocket** toolbars, with
two modes that change **where the audio comes from**:

- **☁ Cloud** (the streaming default) — play from your **streaming provider**, falling back to a
  **rip** from the server. This is the behavior you've had.
- **📱 Device** — play the **burned files** from your designated **burnt-music folder** ([Settings ▸ Rip from cloud · burnt-music folder](#settings--rip-from-cloud--burnt-music-folder)), so
  the set plays with **no signal and no rip server**.

In **Device** mode, a **Play-all skips any track that isn't burned yet** (it plays only what's
actually on the device) — and if *nothing* in the set is on the device, you get a **"nothing on
device"** banner instead of silence. Tapping a **single** un-burned song still **falls back to
Cloud** for that one track, so you're never stuck. The toggle is global and the now-playing state
stays consistent across it; flipping mode mid-set lets the **current track finish** before the
next one honors the new mode.

On **iPhone/iPad** the inline per-song player **slides and collapses as the set advances** —
collapsing the track that just finished and expanding the next — so the open player always tracks
the song you're hearing. (The Mac player stays a plain, fixed panel.)

**User story:** "In a basement with no bars I flip to Device and run the set off what I burned; on
the couch I flip to Cloud and stream — same toggle, same set, no fuss."

---

## Burned files are named so you can mix from them

When you **Burn** a set, the downloaded files now carry **descriptive, mixer-ready names** instead
of a bare title. Each filename is built from the track's
**Artist · Song · Album · Year · Genre · Camelot · Key · BPM** (sanitized for the filesystem and
length-capped, with the song id kept on the end so names never collide). Digital and cloud rips
are named **per song**; a shared **analog whole-album** file is named at the **album** level. Each
audio file still gets its same-named **`.txt` sidecar** with the full BPM/key/sentiment/metadata
read-out.

**User story:** "When I drag the burned files into my DJ app, the filename alone already tells me
the key, Camelot code and BPM — I can order a set straight from the folder."

---

## Opens with no network — the offline-first catalog & playback

PocketDJ is offline-*first*, and the native app lives up to it from the very first second: it
**opens with your full catalog even with no signal at all**.

**The catalog opens offline.** Every time the app successfully loads a source's index online, it
**caches the raw catalog to disk** (one file per source, under the app's Application Support). On a
later launch with **no network — or a server that's down — it falls back to that cached catalog**,
so all 1,300+ albums / 12k+ songs are right there, browsable and searchable, on a plane or in a
basement. With multiple sources, it degrades **gracefully**: each source falls back to its own
cache independently, an un-cached source (one you never loaded online) is simply **skipped**, and
the app only fails to open if **every** source fails. (The catalog index is too big for the
system's default response cache to keep, so the app keeps its own copy that survives restarts.)

**Burned songs always play first — and actually make sound offline.** On **every** way you start a
song — tapping **▶** on a row, **⌘P** on the keyboard, or **Play-All** — the app **prefers a
burned local file** whenever one exists, in **both** Device and Cloud mode. So a song you've
burned plays **instantly and with no network**, never reaching for the rip server first. Crucially,
a burned file living in a **folder you picked yourself** ([Settings ▸ Rip from cloud · burnt-music folder](#settings--rip-from-cloud--burnt-music-folder)) **plays its audio** offline — the app
**holds that folder's read access open for the whole song** rather than dropping it the instant it
found the file (dropping it early is what would leave a picked-folder burn stuck at **0:00 with no
sound**). (Playback only needs the folder *readable*, so a folder that's momentarily not writable —
say an offline iCloud Drive folder — still plays.)

**Snappier when the server's just unreachable.** When a rip server is configured but can't be
reached (asleep at home while you're on venue wifi), a play request gives up in **~12 seconds**
instead of stalling a full minute — so **Play-All skips an un-burned track promptly** and keeps the
set moving. And the inline scrubber falls back to the **catalog's length** for its end timestamp,
so the **/ m:ss** is sensible even before the audio file reports its real duration.

**User story:** "Open the app in a dead zone and still have my whole crate — and have everything
I burned play instantly, with sound, no signal, no waiting on a server that isn't there."

---

## Analog cut export — the full single-track list for your DJ software

A side of vinyl rips as **one album mp3**, and that whole-album file (the "backcase") is what a
burn has always written. But other DJ software wants the **individual tracks** as their own files.
So a Burn now also exports a **per-song cut** of every analog track **alongside** the whole-album
file.

**How it's made.** When the rip server rips an analog album, it **slices each song out** of the
freshly-made album mp3 (from the song's start offset, for its own length — *derived from the
segment boundaries* when the catalog doesn't carry a length) and uploads it as its own file, **ID3
tagged** with the track's **title, artist and album**. A **Burn** then downloads each cut into your
burn folder under the **same descriptive, mixer-ready name** as a digital track ([Burned files are named so you can mix from them](#burned-files-are-named-so-you-can-mix-from-them) —
Artist · Song · Album · Year · Genre · Camelot · Key · BPM), **paired with its own `.txt`
sidecar**. So your folder ends up with both: the **whole-album backcase** *and* the **full list of
individual, tagged single tracks** ready to drop into any DJ app.

**It stays current on its own.** If a cut is **re-uploaded** on the server (re-sliced or re-tagged),
the next burn notices it's **newer** and **re-pulls just that file**, cleanly replacing the old one
— no manifest change needed. A cut that fails to export **never fails the burn** (the album file
alone still plays and is the backcase). And playback is **completely unchanged**: songs still play
from the album file at their start offset — the per-song cut is **burn-only**, purely for handing
off to other software.

**Retro-fitting older rips.** Two server actions backfill the cuts for albums ripped before this
existed: one **slices a cut for every analog track that's missing one** (straight from the raw
album source, no full re-transcode), and one **re-tags every existing cut** (title/artist/album,
a fast tag-only pass with no re-encode) — bumping each file's timestamp so the next burn auto-pulls
the freshly-tagged version.

**User story:** "Burn me the whole record *and* every song as its own properly-tagged file, named
with the key and BPM, so I can load the single tracks straight into my DJ software — and quietly
keep them up to date."

---

## The home Now Playing deck — a spinning gold record on the menu screen

Start any collection playing — a playlist, a pocket, an album, a Siri request — and the
app's **home menu screen** (iPhone) or the space **under the sidebar menu** (iPad, Mac)
becomes a little record deck. It appears whenever music is playing in any mode **except
Mix** (the Mix tab has its own two-deck board; while a mix or Auto-DJ owns the audio, the
home deck yields).

Top to bottom:

- **The track name and artist**, right above the player.
- **A gold vinyl record spinning inside a blue record-player chassis** (the same blue as
  the app's icons), the current album's cover as its center label, a fixed tonearm on the
  right. The record **spins at a rate that reflects the track's tempo** — one revolution
  per 4-beat bar of the measured **beat-grid BPM** (catalog BPM as fallback), so a ~133 BPM
  banger turns like real 33 RPM vinyl and faster tracks visibly spin faster. Pause and the
  platter **freezes in place** (no rewind-to-twelve-o'clock); resume and it picks up from
  the same groove. Unknown tempo ⇒ classic 33⅓.
- **⏮ ⏯ ⏭ transport** — the same prev/play-pause/next that works from the lock screen.
- **Up next** — the not-yet-played queue of the playing collection. **Drag to reorder**
  (Reorder button on iPhone) or **✕ / swipe to remove**; edits touch only what hasn't
  played yet, so the current track never skips or restarts.
- **Add-search — the same native search control as the Browser tab** (user-tested: a
  bottom text field hid under the keyboard). On iPhone the field rides the bar at the
  top; on **iPad and Mac it sits on the LEFT, at the top of the sidebar** (this also
  fixed a Mac crash — two search fields were fighting over the window toolbar). **⌘L
  jumps the cursor straight into it**, so a set is fully drivable from the keyboard;
  type
  anything ("optimistic", "cobalt", a title) and matching **albums appear above songs**,
  each in a **collapsible** section (fold the albums away to scroll just songs). **＋
  appends** a song — or an album's whole tracklist — to the end of the queue, live, without
  interrupting playback. Exact-title matches rank first even in a ~100k-song catalog, and
  the search runs debounced off the main thread so typing stays smooth.

The whole deck **scrolls** (user-tested): pull the list up and the record player and its
controls slide out of view so **Up next can take over the panel** — the menu/tab links
above stay pinned. The **tonearm plays the record**: it rests on the outer edge at
0:00 and sweeps toward the center label in proportion to the play position, like a real
stylus crossing the grooves. **Right-click or long-press** is everywhere: a **queue row**
offers *Move to top · Move to bottom · Remove*, a **search result song OR album** offers
*Add next · Add to end* (＋ still appends; an album lands its whole tracklist, in album
order, wherever you chose), and **the record itself** opens the current track's full
**song detail metadata** — closed with a Back button top-left on iPhone, or an
always-visible **✕** on iPad and Mac (Esc still works for the keyboard-inclined).

And the **Mix tab now wears Apple Music's AutoMix mark** — the two overlapping records
(one solid, one open) from Apple's own symbol sheet, redrawn to color exactly like the
neighboring tab icons.

**Getting there.** On iOS the app opens on the **home menu** ("PocketDJ" — the ✦ sparkle is
dropped on **every** platform) unless you'd navigated
somewhere before — then it **reopens wherever you last left off**. On the Mac it always opens
on the **Mix** tab, ready to DJ. And where the sparkle would sit, **iPad, Mac and Vision Pro**
show a **＋ New Window** button — tap it to open a second window (run Performance in one,
Mix in another); it's the on-screen twin of **⌘N** / File ▸ New Window. iPhone, which can't
display two windows, hides it.

**User story:** "I start a pocket from the couch, glance at my phone's home screen and see
the gold record turning at the track's tempo with what's coming next — I drag tomorrow's
opener up the queue, type 'slow burn', add it straight into the set, and the music never
hiccups."
