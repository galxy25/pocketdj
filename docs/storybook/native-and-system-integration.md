# Native & System Integration

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). These are the surfaces
> where PocketDJ meets the rest of the phone and the operating system: the **"?♪?"
> recognizer** that names the song in the room and maps it back to your crate,
> **streaming-account** linking, **Siri / Shortcuts / Spotlight** voice and system
> actions, **CarPlay** in the car, the **Now Playing widgets** on the home screen /
> desktop, and the **Settings** utilities — the storage manager and a remote-debug
> capture — plus one easter egg. They all read the same
> catalog, rips and collections as everything else. The systems-side complement is
> [Distribution, Clients & the Edits Round-Trip](../architecture/07-distribution-and-clients.md).
> These sections are prose-only — no screenshots captured yet.

## "?♪?" — identify the song that's playing

At the **top of the Browser**, centered, is a **"?♪?"** button — two question marks
flanking a music note. Tap it and the app **listens through the mic** (ShazamKit),
**identifies** the playing song, and maps it back to your crate:

- while listening it pulses with a sonar ring (note bounces; *Identifying* as it
  queries),
- a hit **in your crate** opens a *"Heard it"* sheet — **"In your crate"** with an
  **Open song** deep-link straight into that song's detail,
- a hit **not in your crate** shows the recognized title/artist/artwork as **"Not in
  your crate"**, and — when Shazam returns an Apple Music id — notes *"A linked Apple
  Music account can play this."*,
- if mic permission is **denied**, the button shakes, shows a `mic.slash`, and tapping
  it jumps to Settings.

### Not in your crate? Add it — and rip it to your crate

When a song is **not in your crate** but you've linked **Apple Music**, the result sheet still gives you two ways to keep it. **Open album** deep-links to the album — straight into the album detail if it's already indexed in your catalog, or, if not, a synthesized album view built live from the recognized track's Apple Music metadata: cover art, full tracklist, and the song you just Shazamed highlighted among its neighbors. **＋ Add to Library** goes further — it adds the album's complete tracklist to your Apple Music library, then automatically **rips and burns** every track into your crate, so the whole album lands as offline-playable audio, not just a library entry.

The result is that a song identified in the wild — at a party, in a store, off someone else's speaker — can become a first-class member of your collection in one tap: found, added, ripped, and burned, no separate trip to go dig it up later.

**User story:** "Shazam a song I don't own, hit ＋, and by the time I check back it's not just in my Apple Music library — it's ripped and burned into my crate, ready to mix."

Matching is title+artist **normalized** (so *"Café (Remastered 2011)"* still matches
*"Cafe"*). On a build without ShazamKit it simply reads *"Recognition isn't available
in this build."* — never a crash.

**User story:** "Something great is playing — what is it, and have I already got it?"
One tap answers both.

---

## Settings ▸ Streaming accounts — link Apple Music

A **"Streaming accounts"** section in native Settings sits beside your URL
**Data sources**. It lists one row per provider — currently **Apple Music** — with a
status line and a **Log in / Log out** button:

- a configured provider shows **Log in**; linking hands off to that service's sign-in
  (Apple Music shows the system consent sheet), after which the row reads
  **Linked / Connected**, and **Log out** severs it,
- an **unconfigured** provider (not provisioned in this build) reads **"Not
  available"** with a developer note,
- the section footer explains: *link a streaming service to play directly from your
  subscription, beside your own catalog sources.*

A linked subscription is an **additional, account-based source** — orthogonal to the
vinyl / Apple Music (Local) URL catalogs and to rip-on-demand. It also gives the "?♪?"
recognizer a way to **play** a recognized track that isn't in your crate.

**User story:** "Beyond my own crate, let me reach into my streaming subscription —
log in once, and play from it inside the same app."

---

## Hey Siri — App Shortcuts (play, auto-mix, create a pocket)

The native app's performance surface is **voice- and system-invocable** — no Shortcuts-app
setup, live the moment the app installs. Every phrase ends **"…in PocketDJ"**:

- **"Play *Friday Warmup* in PocketDJ"** / **"Shuffle *Friday Warmup* in PocketDJ"** — plays a
  **playlist** exactly like tapping ▶/🔀 on its detail screen: the resolved songs snapshot into the
  reusable **Now Playing** set list and the app-scoped player starts — even from the Home Screen,
  the Action button, or a locked phone (playback starts in the background; the lock-screen card
  takes over from there).
- **"Play the pocket *Deep Funk* in PocketDJ"** — same for a **pocket** (its songs, albums, and
  nested pockets in DAG order), with a shuffle variant.
- **"Auto-mix *Deep Funk* in PocketDJ"** — starts the **Auto-Mix** auto-DJ from a pocket **or** a
  set list, with the Settings lead/fade and your glide preferences. Auto-mix plays **burned local
  files only**, and Siri says so if the collection has none yet ("…burn it first").
- **"Pause the auto-mix in PocketDJ" / "Resume the auto-mix in PocketDJ"** — the same suspend/resume
  as the lock-screen ⏸/▶: the mix clock **freezes** through the pause and resumes **exactly** the
  fade it was in — never a cold stop.
- **"Create a pocket in PocketDJ"** — Siri asks *"What kind of pocket should I build?"* — answer in
  plain words: *"optimistic soul, funk, r&b or disco songs from 1960 to 1989."* On-device Apple
  Intelligence (iOS 26+) parses the brief; PocketDJ then searches the whole catalog — **exact** year
  range, **fuzzy** genre matching, and **mood-vector similarity** over each song's sentiment
  keywords — the model curates and orders the best matches, and up to **90 minutes** of songs (the
  minutes are adjustable in Shortcuts) are saved as a new pocket, **asynchronously**: Siri answers
  right away and the pocket appears in Playlists ▸ Pockets moments later, with your brief kept as
  its description.

Beyond voice, the same intents surface everywhere the system composes actions: the **Shortcuts app**
(with playlist/pocket pickers), **Spotlight** — where your playlists and pockets are **indexed by
name**, and tapping one opens it straight in the app — and system **suggestions**, which learn from
the real ▶/🔀/Auto-mix taps the app donates as you use it. Renaming a playlist re-teaches Siri the
new name automatically.

**User story:** "Hands on the decks — or walking out the door — I say *'Shuffle Crate Warmers in
PocketDJ'* and it's playing; and when I only know the vibe I want, I ask Siri to *create a pocket*
and find ninety minutes of it waiting in the app."

---

## PocketDJ in CarPlay — the crate on the dashboard

Plug the phone into a CarPlay head unit and PocketDJ appears as a native CarPlay app — not a mirrored phone screen, but its own tab-bar UI driving the exact same **library, collections, and player** as the phone. There's no separate car catalog to sync: whatever's in your pockets and playlists on the phone is what's in the car. The root is a four-tab bar — **Playlists · Pockets · Albums · Artists** — sized for glance-and-tap use at the wheel. Playlists and Pockets list your collections and drill into their songs; **Albums** and **Artists** are A–Z-indexed lists with a quick alphabetical scroll index down the side, the keyboard-free way to jump straight to a name while driving instead of typing it. Tapping into a collection or album pushes its song list with **▶ Play all** and **🔀 Shuffle all** rows pinned above the tracks; tapping an artist plays their whole discography straight through. Tapping a song itself opens an action sheet — **Play now**, or **Add to pocket / playlist**, which lists destinations and confirms with "Added to \<name\>" — so building a collection is a two-tap job even at a stoplight.

Because CarPlay drives the shared player, the car's system **Now Playing** screen always matches what's on the phone, down to the **Up Next** button, which opens an editable queue with **Remove · Play next · Move to end** actions — CarPlay has no swipe gestures, so every queue edit is a tap-and-choose. There is deliberately **no Search tab**: head units block the keyboard while the car is moving (leaving the screen frozen), and the A–Z scroll indexes on Albums/Artists plus voice — "Play X in PocketDJ" via Siri — cover finding music hands-free far better than typing at the wheel ever could.

**Affordances**
- **Playlists / Pockets tabs** — list collections, drill into songs
- **Albums / Artists tabs** — A–Z lists with a scroll index for keyboard-free browsing
- **▶ Play all / 🔀 Shuffle all** — pinned rows atop any collection or album's song list
- **Song action sheet** — Play now, or Add to pocket / playlist with a confirmation toast
- **Up Next** — editable queue via Remove · Play next · Move to end
- **Voice** — "Play X in PocketDJ" via Siri replaces typed search at the wheel

**User story:** "I get in the car, my phone connects, and the same crate I built at home is right there on the dash — I can flick to an artist, shuffle a pocket, or just tell Siri to play something, without ever looking away from the road for long."

---

## Now Playing widgets — the deck on the home screen and desktop

Add the **PocketDJ Now Playing widget** to the iPhone home screen, the Mac desktop /
Notification Center, or (on visionOS 26) a room in the Vision Pro, and the current
track lives outside the app: **album cover, title, artist**, and real
**⏮ ⏯ ⏭ transport buttons** that drive the actual playback — pause on the widget
and the music pauses, whichever engine (a burned file, a rip stream, or an Apple
Music track) is sounding. Skip works too: it advances the same running set the
in-app deck shows.

Three sizes, one story:
- **Small** — the cover with ⏯ and ⏭ underneath: the glanceable "what's on".
- **Medium** — cover beside title/artist, the next track ("Up next: …"), and the
  full transport row.
- **Large** — everything above plus an **Up Next** preview of the next four tracks
  in the queue, so you can see where the set is headed without opening the app.

When nothing is playing the widget shows a calm "Nothing playing" placeholder
instead of a blank tile. Artwork tracks the current song even for Apple Music
streams (whose art lives in Apple's catalog, not ours), and the play/pause glyph
mirrors the real audio state no matter where you pressed pause — the app, the
lock screen, the menu-bar Now Playing, or the widget itself.

**Affordances**
- **Cover + title + artist** — always-current, all three sizes
- **⏮ ⏯ ⏭** — real transport (medium/large; small keeps ⏯ + ⏭)
- **Up next line** (medium) / **Up Next ×4 preview** (large)
- **Idle placeholder** — "Nothing playing" instead of an empty tile

**User story:** "The set runs while I'm in another app — or another *room* — and the
widget is my remote: glance for what's on, tap to pause, tap to skip, never opening
the app at all."

---

## The nuclear option — a mushroom cloud easter egg

Settings ▸ **Reset all app state** is PocketDJ's nuclear option — so confirming it
detonates one. A stylized **mushroom cloud** blooms up from the bottom of the screen
(white-hot flash, fireball cap rising on its stem, glowing ground ring) and drifts away
about two and a half seconds later. Pure decoration: it never blocks a tap, and the reset
itself runs normally underneath.

**User story:** "If I'm going to erase everything, at least let me enjoy the blast."

---

## Settings ▸ Sync — one panel for staying current

Two kinds of "keep me up to date" used to live in different places; now Settings has a single
**Sync** row (the Storage-panel pattern — a navigable page with a back button) gathering both:

- **Apple Music library** — the **Sync Apple Music library** button asks your Mac (via the rip
  server) to check for newly-added music right now, with the result inline ("Library up to
  date", or "12 new — applies after deploy"). The same check also runs automatically every
  day at 04:00.
- **Converted playlists & pockets** — the global **"Sync converted playlists & pockets"**
  toggle (on by default) plus a **"Sync from sources now"** button that runs one reconcile
  pass over every linked item immediately and reports how many changed. The footer counts how
  many of your collections are linked to a source ([Converted pockets & duplicated playlists
  stay in sync with their source](perform-pockets-playlists-setlists.md#converted-pockets--duplicated-playlists-stay-in-sync-with-their-source)).

**User story:** "When I wonder 'is the app caught up with my library?', I want one place to
look — and one button to press."

---

## Settings ▸ Storage — the storage manager

Burned music, stems, beat grids, and mix recordings all live on your device. Settings has a
single **Storage** row that opens the **storage manager** (with a back button to return),
gathering everything about on-device space in one place.

**What's on it.** At the top, **On this device** shows what your library actually costs:
**Burnt music** (songs + total size — audio, per-song cuts, stems, beat grids, and sidecars,
across the app's storage *and* your chosen folder) and **Session recordings** (takes + size).
Below that live the two **folder pickers** — the burnt-music folder and the mix-sessions
folder — for saving burns and recordings somewhere you can browse yourself.

**Deleting downloaded music.** Three tools, all with confirmations, and all with the same
guarantee: **only the downloaded files are removed — never a song from your library, or from
any pocket, playlist, or set list.** Anything you delete can simply be burned again later.

- **Delete by artist…** — every burned artist with song count and size; tap one to clear
  their downloads.
- **Delete by collection…** — your pockets, playlists, and set lists that have burned music,
  each with a burned-song count and size; tap one to clear those songs' downloads (the
  collection itself is untouched).
- **Delete all burnt music** — the sweep: audio, cuts, stems, beat grids, sidecars, gone.

A matching **Delete session recordings** clears every captured take's audio while keeping
each session's played-tracks log and timeline (a recording in progress is never touched) —
and the Sessions screen deletes **individual takes** ([Record your mix — the session recording](mix-and-stems.md#record-your-mix--the-session-recording)) when you only want one gone.

**The soft cap — storage that manages itself, only if you ask.** By default **no cap is
set, and the app never deletes music on its own** — storage is yours to manage with the
tools above. Tap **Set a soft cap…** and the cap starts at your current footprint (so
nothing becomes instantly evictable), adjustable by the GB. With a cap set, **once a day**
— in the background on iPhone/iPad, or when the app comes forward — the app prunes burnt
music down under the cap, **least-recently-played first**: the records you haven't touched
in months go before anything you played last night, and whatever's actually loaded on a
deck or playing right now is never touched. A **Prune now** button runs the same pass on
demand, and **Remove cap** returns the app to fully-manual storage. (To know what
"least-recently-played" means, the app quietly keeps per-song play counts and
last-played times on-device — every play surface counts: rows, set lists, and the Mix
decks.)

Deletes here are safe by design around **your own folders**: if you've pointed burns or
recordings at a folder of your own, the app only ever removes files **it** wrote there —
your other audio and subfolders are never counted, never touched. And if a burn lives on a
drive that isn't plugged in right now, the app skips it rather than forgetting about it.

**User story:** "Show me what PocketDJ is costing my phone, let me clear an artist I'm done
with or a set I've played out — without touching my library — and if I give it a budget,
keep me under it by tossing what I never play."

---

## Settings ▸ Debug — capture a debug session, ship it back

Remote testing has a built-in feedback loop. **Settings ▸ Debug** (the last row — and the footer
beneath it always shows **exactly which build you're running**, version and build number) opens a
small panel with one switch: **Capture debug log**. Turn it on, **reproduce whatever's misbehaving**,
turn it off — and the frozen session appears right there with an **Export** button. Save the text
file straight into **iCloud Drive** (or AirDrop it) and it's off the device and in front of whoever's
debugging, no cables, no Terminal, no Xcode.

What's in a session: the mix engine's once-a-second **liveness heartbeat** — is the engine running,
are render callbacks actually firing, is there **actual signal** or silence, what each deck *thinks*
it's doing vs. what its player is really doing — plus a time-stamped line for every recovery event
and transport action. It's exactly the trail that pinned down the AirPods silent-switch bug: the log
showed a deck "playing" at full position speed while rendering pure zeros, which is a one-line fix
once you can see it.

The capture survives an app relaunch (it starts a fresh session if the switch was left on), lives
only in memory, and costs nothing when it's off.

**User story:** "The bug only happens on my MacBook, not the machine with the debugger. Flip on
capture, make it happen, flip it off, drop the file in iCloud — and the fix shows up in the next
build instead of twenty questions."
