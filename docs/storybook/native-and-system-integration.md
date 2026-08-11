# Native & System Integration

> Part of the [PocketDJ Product Storybook](../STORYBOOK.md). These are the surfaces
> where PocketDJ meets the rest of the phone and the operating system: the **"?♪?"
> recognizer** that names the song in the room and maps it back to your crate,
> **streaming-account** linking, the **two-way Apple Music favorites sync**,
> **Siri / Shortcuts / Spotlight** voice and system
> actions, **CarPlay** in the car, the **Now Playing widgets** on the home screen /
> desktop and the **♥ on the lock screen**, **⌘N multi-window** on Mac and iPad, the
> **.pdjcollection** file that carries a collection between devices,
> **Jukebox Hero** — a QR-code request line the whole room can scan — and the
> **Settings** utilities — the storage manager, the owner-identity bootstrap, and a
> remote-debug capture — plus one
> easter egg. They all read the same
> catalog, rips and collections as everything else. The systems-side complement is
> [Distribution, Clients & the Edits Round-Trip](../architecture/07-distribution-and-clients.md).
> These sections are prose-only — no screenshots captured yet.

## Zero to hero — the first-run flow

A fresh install (or a reinstall — deleting the app resets it) opens on a three-stage
setup instead of a silent default catalog:

1. **Your profile** — *"Link with iCloud"* or *"Just this device."* Linking probes the
   cloud first: a returning DJ gets **"Welcome back"** and a one-tap **Restore my
   stuff** that pulls their profile, collections, and sessions before anything on the
   device can overwrite them; a new iCloud user just types a DJ name. If iCloud can't
   be reached the flow says so and continues safely — it never mistakes a slow network
   for a brand-new account.
2. **Stream with Apple Music** — the same sign-in as Settings ▸ Apple Music ▸ Credentials,
   offered up front so full songs stream instantly while rips are made. Skippable.
3. **Import your music** — pick the global sources by their plain names: **Vinyl**,
   **Digital**, and **Streaming** (the Apple Music catalog index, with its ~33 MB
   size called out). All three start selected; at least one is required.

Until the flow finishes, the app holds its whole launch pipeline: nothing syncs up to
iCloud, and a Siri / CarPlay tap answers *"Finish setting up PocketDJ in the app
first"* — so a half-set-up device can never overwrite a real profile in the cloud.
Existing users updating the app never see the flow; the Settings mushroom-cloud reset
runs it again.

**User story:** "I put PocketDJ on my new phone, tapped *Link with iCloud → Restore my
stuff*, signed into Apple Music, kept all three sources — and my whole crate was back
before the kettle boiled."

## "?♪?" — identify the song that's playing

At the **top of the Browser**, centered, is a **"?♪?"** button — two question marks
flanking a music note. Tap it and the app **listens through the mic** (ShazamKit),
**identifies** the playing song, and maps it back to your crate:

- while listening it pulses with a sonar ring (note bounces; *Identifying* as it
  queries),
- a hit **in your crate** opens a *"Heard it"* sheet — **"In your crate"** with an
  **Open song** deep-link straight into that song's detail,
- a hit **not in your crate** shows the recognized title/artist/artwork as **"Not in
  your crate"**, and — when Shazam returns an Apple Music id — an **Apple Music**
  section appears below it: a one-tap **Connect Apple Music** if no account is linked
  yet, or the open-album / add actions (next section) once one is,
- if mic permission is **denied**, the button shakes, shows a `mic.slash`, and tapping
  it jumps to Settings.

### Not in your crate? Add it — and rip it to your crate

When a song is **not in your crate** but you've linked **Apple Music**, the result sheet still gives you two ways to keep it. **Open album** deep-links to the album — straight into the album detail if it's already indexed in your catalog, or, if not, a synthesized album view built live from the recognized track's Apple Music metadata: cover art, full tracklist, and the song you just Shazamed highlighted among its neighbors. **＋ Add to Apple Music** goes further — it adds the recognized song to your Apple Music library, then the app prepares your copy and saves it to this device ("Preparing your copy…" → "Saved to device"), so it lands as offline-playable audio, not just a library entry. The synthesized album view carries its own **Add album to Library** button that does the same for the whole album: every track added, then prepared and saved in one batched pass. (On the Mac, where no app can write the Music library, the sheet hands off instead — **Add in Apple Music** opens the album in the Music app.)

The result is that a song identified in the wild — at a party, in a store, off someone else's speaker — can become a first-class member of your collection in one tap: found, added, and saved to the device, no separate trip to go dig it up later.

**User story:** "Shazam a song I don't own, hit ＋, and by the time I check back it's not just in my Apple Music library — it's saved on my device, ready to mix."

Matching is title+artist **normalized** (so *"Café (Remastered 2011)"* still matches
*"Cafe"*). On a build without ShazamKit it simply reads *"Recognition isn't available
in this build."* — never a crash.

**User story:** "Something great is playing — what is it, and have I already got it?"
One tap answers both.

---

## Settings ▸ Apple Music ▸ Credentials — link Apple Music

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

## Favorites and Apple Music — the two-way sync

The **♥** on every song row ([♥ Favorites](explore-and-discover.md#-favorites--mark-the-ones-you-love))
is, for most installs, purely a PocketDJ thing: your hearts live in your own profile, sync to
your own devices through iCloud, and go nowhere else. On the **owner's** install — the DJ whose
Apple Music library the shared catalog was built from — the ♥ is also wired **straight into
Apple Music**, in both directions:

- **Heart in PocketDJ → it shows up in Apple Music.** The track gets the ★ in Apple's
  **Favorite Songs**, and it gets **loved**, so Apple's own recommendations start taking it
  into account.
- **♥ in the Music app → it shows up in PocketDJ.** Whenever the app launches or comes
  forward, it reads back which tracks the account loves and folds them in. A song you loved on
  the way to work is hearted in PocketDJ by the time you open it.

If you heart something while offline, the change is kept and sent on the next pass — nothing is
dropped. And if you heart something in one place and un-heart it in the other, **your most
recent action wins** locally.

### Un-favoriting is lossy — read this once

**Apple gives no app a way to take the ★ back.** Adding to Apple Music's **Favorite Songs** is
a one-way door in every app that isn't the Music app itself. So when you un-heart a track in
PocketDJ, the app does the one thing it *can* do: it removes the **love**, which is what
recommendations — and PocketDJ itself — read. The ★ stays in your Apple Music **Favorite
Songs** until you remove it there yourself.

Everything else behaves the way you'd expect: the ♥ is off in PocketDJ, off on your other
devices, and the track stops being treated as loved. It's only Apple's own Favorite Songs list
that keeps the entry. The app says so where it matters rather than letting you find out later.

### Only one install syncs — everyone else stays local-only

Two things make this safe for everyone who *isn't* the owner:

- **Nothing about your favorites can reach anyone else, structurally.** They sync through your
  own private iCloud, not through the shared catalog — there is no path from your device to
  another DJ's, whatever the settings say.
- **No install pushes anything to Apple Music unless its iCloud account matches the owner
  allowlist compiled into the app.** The allowlist was bootstrapped by hand (below) and names
  exactly one person — the owner — so every other install is favorites-local-only out of the
  box. If the check can't be made at all — no iCloud account, no network, an error of any
  kind — the answer is *"not the owner"* and the app stays local-only. It errs toward doing
  nothing, always.

Which means: **a beta tester's ♥ never touch their own Apple Music account, and never touch
anyone else's.** What a tester *does* get is a **starting set** — a one-time copy of the
owner's Apple-Music-sourced favorites, applied on first run so a fresh install doesn't open
onto an empty crate of hearts. It only ever fills in songs you've never touched: anything you
have hearted, or deliberately un-hearted, is left exactly as you left it, and it's applied
once, not every launch. The owner's personal **vinyl** and **My Digital** hearts are never part
of it — only Apple Music tracks travel.

### Settings ▸ Apple Music ▸ Syncing ▸ Favorites — the bootstrap

The panel that runs the whole thing lives in **Settings ▸ Apple Music ▸ Syncing**, under **Favorites** (it's a
sync question, so it sits in the sync panel, not in Debug):

- **Status** — a plain-language line: *"Two-way Apple Music sync on"* or *"Local to this
  profile"*, plus the **last synced** time and the **last error** if a pass failed, and a
  **Sync favorites now** button that runs a pass on demand.
- **iCloud hash** — this device's identifier for the owner check, shown as selectable text with
  a **Copy hash** button. This is the value that gets written into the app's build and shipped;
  an install syncs only when its hash matches. (Different CloudKit environments produce
  **different** hashes, so the dev and TestFlight builds each have to be captured.)
- **Export favorites seed…** — owner-only. Writes the starting-set file (the Apple-Music-sourced
  hearts, nothing personal) out through the normal save/share sheet, ready to publish for
  testers. It doesn't appear at all on a non-owner install, so a tester can't accidentally
  publish their own favorites.

The panel's footer states the un-favorite caveat in the same words as above, so whoever is
holding the phone sees it at the moment they'd care.

**Affordances**
- **♥ anywhere** — favorites the song; on the owner's install it also stars and loves it in
  Apple Music.
- **Settings ▸ Apple Music ▸ Syncing ▸ Favorites** — read the sync status, run a pass now, copy this device's
  hash, see the last error.
- **Export favorites seed…** — owner-only; produces the testers' starting set.

**User story:** "My hearts should be one thing, not two — what I love in the Music app and what
I've flagged in PocketDJ should be the same list. And when I hand a build to a friend, their
taste stays theirs and never lands in my library, or theirs."

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
  right away and the pocket appears in Collections ▸ Pockets moments later, with your brief kept as
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

Plug the phone into a CarPlay head unit and PocketDJ appears as a native CarPlay app — not a mirrored phone screen, but its own tab-bar UI driving the exact same **library, collections, and player** as the phone. There's no separate car catalog to sync: whatever's in your pockets and playlists on the phone is what's in the car. The root is a three-tab bar — **Playlists · Pockets · For You** — sized for glance-and-tap use at the wheel. Playlists and Pockets list your collections and drill into their songs. **For You** is the same grid you get in History, flattened into rows and in the same order: **New** pinned first, **In Da Zone** second, then one row per collection PocketDJ has something to suggest for. Tapping into a collection pushes its song list with **▶ Play all** and **🔀 Shuffle all** rows pinned above the tracks; tapping into a For You row does the same for that tile's picks, and tapping one of those picks plays from there onward. Tapping a song itself opens an action sheet — **Play now**, or **Add to pocket / playlist**, which lists destinations and confirms with "Added to \<name\>" — so building a collection is a two-tap job even at a stoplight.

The **New** row is the one that behaves differently, because its records aren't yours yet: it lists only what's actually **out now** (a pre-order has no audio behind it, and every row in a car has to be playable), and playing one streams it from Apple Music the same way the New tile does on the phone. Those rows offer **Play now** but no "Add to pocket / playlist" — there's no song in your library to add. Everything else about For You in the car is read-only: the ranking is the one your phone last computed, rendered as-is. The car never recomputes it — that's two sweeps of a 96,000-row catalog, which is not something to start because you plugged in — so if you've never opened For You on the phone, the tab says so instead of showing you an empty list.

Because CarPlay drives the shared player, the car's system **Now Playing** screen always matches what's on the phone — and it carries a **♥** button that favorites the current track, filled or outline to match, the same heart as everywhere else in the app. The **Up Next** button opens an editable queue with the current track pinned in its own **Now Playing** section on top (tap it to land back on the Now Playing card) and **Play now · Remove · Play next · Move to end** actions on every upcoming row (Play now jumps the set straight to that row) — CarPlay has no swipe gestures, so every queue edit is a tap-and-choose. And starting a For You row from the car is what finally makes the **👍/👎** on that Now Playing card appear: those controls only show for a queue that began as a recommendation, and until For You reached the car, only the phone could start one. Now you can put on a suggestion and judge it without touching the phone — and the verdict is already there, on the same list, when you next open it.

There is deliberately **no Search tab**: head units block the keyboard while the car is moving (leaving the screen frozen), and For You plus voice — "Play X in PocketDJ" via Siri — cover finding something to play hands-free far better than typing at the wheel ever could.

**Affordances**
- **Playlists / Pockets tabs** — list collections, drill into songs
- **Albums / Artists tabs** — A–Z lists with a scroll index for keyboard-free browsing
- **▶ Play all / 🔀 Shuffle all** — pinned rows atop any collection or album's song list
- **Song action sheet** — Play now, or Add to pocket / playlist with a confirmation toast
- **♥ on Now Playing** — favorite the current track from the car's Now Playing screen
- **Up Next** — current track pinned on top; editable queue via Play now · Remove · Play next · Move to end
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
  full transport row — ⏮ ⏯ ⏭ plus a **♥** that flips the current track's favorite
  (accent-tinted when on), straight from the home screen.
- **Large** — everything above plus an **Up Next** preview of the next four tracks
  in the queue, so you can see where the set is headed without opening the app.

When nothing is playing the widget shows a calm "Nothing playing" placeholder
instead of a blank tile. Artwork tracks the current song even for Apple Music
streams (whose art lives in Apple's catalog, not ours), and the play/pause glyph
mirrors the real audio state no matter where you pressed pause — the app, the
lock screen, the menu-bar Now Playing, or the widget itself.

The **lock screen** gets the same heart: the Now Playing card's **♥** (the system
Favorite command) flips the current track's favorite without unlocking the phone,
filled or outline to match — the very same state as the widget's, CarPlay's, and
every row's ♥ in the app. (The Mix decks' lock-screen card keeps its own transport
but leaves the heart out.)

**Affordances**
- **Cover + title + artist** — always-current, all three sizes
- **⏮ ⏯ ⏭ ♥** — real transport + favorite (medium/large; small keeps ⏯ + ⏭)
- **♥ on the lock screen** — favorite the current track from the Now Playing card
- **Up next line** (medium) / **Up Next ×4 preview** (large)
- **Idle placeholder** — "Nothing playing" instead of an empty tile

**User story:** "The set runs while I'm in another app — or another *room* — and the
widget is my remote: glance for what's on, tap to pause, tap to skip, never opening
the app at all."

---

## ⌘N — another window (Mac and iPad)

On the Mac and iPad, **File ▸ New Window (⌘N)** opens a genuinely new PocketDJ
window every time — run the Performance surface in one and the Mix decks in
another, or park the Browser on a second Stage Manager tile. Every window shares
the same stores and engines: one library, one player, one set of decks — a second
window is another *view* of the same session, never a duplicate app fighting over
the audio. (iPhone has no multi-window, so the command simply doesn't appear
there.)

**User story:** "Decks on the left of the screen, the crate on the right — ⌘N and
I'm browsing for the next record without leaving the mix."

---

## A collection is a file — .pdjcollection

Exporting a pocket, playlist, or set list writes a **.pdjcollection** file — a
file type the operating system knows belongs to PocketDJ. That makes moving a
collection between devices a plain file hand-off: **tap the file anywhere** — in
the Files app, an iMessage thread, an AirDrop drop — and PocketDJ opens, imports
it on the spot, and lands you on the imported collection. No picker, no digging
through Settings. (Legacy `.zip` exports still open the same way.) Songs the
receiving device's catalog doesn't know arrive as provisional "Imported" entries
rather than being dropped.

**User story:** "I text my warm-up set to a friend; they tap the bubble and it's a
playlist in their PocketDJ before they've left the conversation."

---

## Jukebox Hero — a QR-code request line for the room

Open the **Jukebox Hero** tab (**⌘J** on iPad / Mac) and tap **Start** — name it *"Levi's
Garage Party"* — and the screen fills with a **QR code**. That's the whole setup: anyone in
the room points a phone camera at it and lands on a tiny web page showing what's playing now,
what's up next, and a text box to ask for a song. There's nothing to install, no account, and
no being on your Wi-Fi — the guest page is just a public web page, so any number of people can
open it at once.

### What a guest sees

The guest's page is a live radio dashboard for your set:

- **Now playing** — the current track's title and artist, with a progress bar that ticks along
  on its own between refreshes.
- **Up next** — the next few tracks in your queue.
- **Previously played** — a **🕘 button** that unfolds the set's history: every track the
  session has already spun, newest first, each with the local time it ended. Guests who
  arrive late catch up on what they missed ("what was that song half an hour ago?"), and
  the list keeps growing live while it's open.
- **Request a song** — type a title and artist, hit send, and it goes straight to the host's
  inbox. The page refreshes every few seconds, so a guest watches their request move from
  *pending* to *queued* (or *played*, or *denied*) through small **status chips**. It gently
  rate-limits — one request every fifteen seconds, only a handful pending at a time — so one
  over-eager guest can't flood the line for the room.

By default guests **see** the music but don't **hear** it — it's a request line, not a
broadcast. Flip **View + Hear** on the live session and each guest page becomes a real
**internet radio station — no PocketDJ app needed**: a **📻 Tune in — live radio** button
appears (phones require that tap before they'll start audio), and from then on the guest's
browser plays your set position-synced with your deck, **rolling from track to track on its
own**. The station puts itself on the guest's **lock screen** — track, artist, and the
jukebox's name, with working play/pause — survives stream hiccups by quietly retrying, and
respects the guest's world: unplug headphones or pause from the lock screen and it stays
paused rather than fighting back. Only songs that already have a public rip stream
out — a track without one plays a moment of radio silence (with a hint) and the station
resumes on the next streamable track — and a copy-protected Apple Music stream never leaves
your device. When you end the session, every tuned-in radio goes silent with it.

### The host's inbox — you're still the DJ

Requests appear in the tab as they arrive, each already **matched against your whole crate**:
PocketDJ reads the free-text ask, finds the closest song in your catalog on-device (falling
back to an Apple Music search when it isn't in your crate), and shows you the match. Four
buttons decide its fate:

- **Deny** — not tonight; the guest sees it declined.
- **Play Next** — jump it to the top of the queue.
- **Play Last** — append it to the end.
- **Surprise Slot** — drop it somewhere random in the upcoming tail, so the crowd's picks
  sprinkle in without you hand-placing each one.

Accept it and the song joins the same **Now Playing** queue you already play, rip, and burn
from — nothing new to learn.

### Broadcast — the request line, live on the decks

The jukebox pairs with the **Mix** tab. Its toolbar gains a **Broadcast** button (an antenna,
next to Record): one tap starts a session and drops the Jukebox view right onto the Mix stack,
so you can run the crowd's line without leaving the decks — the antenna glows while you're on
air. Now the guests see **your mix** — the track on the live deck, and the Auto-DJ's queue as
"up next." Accepted requests feed the **Auto-DJ**: they slot into its automatic queue and play
themselves in — *except* that **your own moves always win.** A manual deck load, a skip, a
pause behaves exactly as it would with no crowd watching, and the jukebox never reaches past a
track you've already cued up. (Because a Mix deck only plays burned files, accepting a
not-yet-burned request quietly kicks off its rip-and-burn and lands it the moment it's ready.)

### It cleans up after itself

A session **lasts 24 hours** and then quietly ends — the guest page shows it's over and the app
folds it away — with a week's grace before the page is deleted entirely. If you're running a
residency or a room you want live indefinitely, flip it **timeless** and it never expires.
Ending it yourself is always one tap. Settings ▸ **Jukebox Hero** holds the server address and a
health check, mirroring the import-server rows, plus the default for **Require access token** —
each new session seeds from that default on its create screen and can flip it per-session, live
included. (The toggle is recorded on the session today; the enforcement — the guest page turning
away anyone whose link doesn't carry the session's token — is still being wired up server-side.)

**Affordances**
- **Start / End Jukebox** — name a session, get a QR code; End closes it
- **⌘J / Broadcast antenna** — open the tab, or start-and-broadcast from the Mix toolbar
- **QR code + share link** — how guests join, no install, no sign-in
- **Request inbox** — Deny · Play Next · Play Last · Surprise Slot, each on a matched song
- **View + Hear toggle** — turn every guest's browser into a synced internet radio
  (public rips only), with a lock-screen card and auto-advancing tracks
- **🕘 Previously played** — the guest page's reveal-button history of the whole set
- **Timeless toggle** — opt out of the 24-hour expiry
- **Require access token** — per-session toggle, seeded from the Settings ▸ Jukebox Hero
  default (guest-side enforcement still in the works)

**User story:** "It's my party and I'm on the decks. I throw a QR code up on the TV, and the
room starts feeding me requests from their phones — I skim them, tap Play Next on the good
ones, deny the chaos, and the Auto-DJ works them in between my own picks. If I want, I let
everyone listen in on their own headphones too."

---

## The nuclear option — a mushroom cloud easter egg

Settings ▸ **Reset all app state** is PocketDJ's nuclear option — so confirming it
detonates one. A stylized **mushroom cloud** blooms up from the bottom of the screen
(white-hot flash, fireball cap rising on its stem, glowing ground ring) and drifts away
about two and a half seconds later. Pure decoration: it never blocks a tap, and the reset
itself runs normally underneath.

**User story:** "If I'm going to erase everything, at least let me enjoy the blast."

---

## Settings ▸ Apple Music ▸ Syncing — one panel for staying current

Every kind of "keep me up to date" used to live in a different place; now Settings has a single
**Sync** row (the Storage-panel pattern — a navigable page with a back button) gathering them
all:

- **Apple Music library** — the **Sync Apple Music library** button asks your Mac (via the
  import server) to check for newly-added music right now, with the result inline ("Library up
  to date", or "12 new — applies after deploy"). The same check also runs automatically every
  day at 04:00.
- **Converted playlists & pockets** — the global **"Sync converted playlists & pockets"**
  toggle (on by default) plus a **"Sync from sources now"** button that runs one reconcile
  pass over every linked item immediately and reports how many changed. The footer counts how
  many of your collections are linked to a source ([Converted pockets & duplicated playlists
  stay in sync with their source](perform-pockets-playlists-setlists.md#converted-pockets--duplicated-playlists-stay-in-sync-with-their-source)).
- **Apple Music playlist updates** — when you've added songs to an Apple Music playlist from
  inside PocketDJ, this section (it appears only while there's something in flight) shows how
  many are **waiting to send**, which **failed** and why, and a **Retry failed** button. The
  footer explains the one surprise: the song reaches your real Apple Music library in seconds,
  but PocketDJ's own view of that playlist only catches up at the next nightly library sync.
- **Favorites** — the ♥ ⇄ Apple Music panel: sync status, **Sync favorites now**, and the
  owner bootstrap ([Settings ▸ Apple Music ▸ Syncing ▸ Favorites — the bootstrap](#settings--sync--favorites--the-bootstrap)).

**User story:** "When I wonder 'is the app caught up with my library?', I want one place to
look — and one button to press."

---

## Settings ▸ Storage — the storage manager

Burned music, stems, beat grids, and mix recordings all live on your device. Settings has a
single **Storage** row that opens the **storage manager** (with a back button to return),
gathering everything about on-device space in one place.

**What's on it.** At the top, **On this device** shows what your library actually costs:
**Burnt music** (songs + size — audio, per-song cuts, beat grids, and sidecars), a separate
**Stems** line (the separated vocals / drums / bass / other tracks, broken out so you can clear
just them — it shows only when you have some), and **Session recordings** (takes + size) — all
across the app's storage *and* your chosen folder.
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

And two **stems-only** cleanups, for when the separated tracks are what's eating space but you
want to keep the burned audio itself:

- **Delete stems by artist…** — every artist whose burned songs have stems, with the stem size;
  tap one to clear just their stems (the burned audio and beat grids stay; stems re-separate on
  demand).
- **Delete all stems** — removes every separated-stem file at once, leaving the burned audio and
  beat grids intact.

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

Remote testing has a built-in feedback loop. **Settings ▸ Debug** (the last row) opens a small
panel with two things on it: which **build** you're running, and one switch — **Capture debug
log**. (The owner-identity rows that bootstrap the Apple Music favorites sync used to live
here too; they've moved to **Settings ▸ Apple Music ▸ Syncing ▸ Favorites** —
[Favorites and Apple Music](#favorites-and-apple-music--the-two-way-sync).)

The **build** row is now a proper row rather than a footer line: the version and build number as
selectable text with a **Copy version** button beside it, because the only reason to look at it
is to paste it into a bug report, and long-pressing to select inside a settings list on a phone
is a fight.

**Capture debug log** is the loop itself. Turn it on, **reproduce whatever's misbehaving**,
turn it off — and the frozen session is **saved to a list** right below. Captures now **persist
across relaunches and accumulate**, so you can grab several before you sit down to send them: each
saved session shows its capture time and line count, and you can **Export** any one (the text file
straight into **iCloud Drive**, or AirDrop it), **delete** one (swipe or right-click), or **Delete
all** at once — no cables, no Terminal, no Xcode.

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
