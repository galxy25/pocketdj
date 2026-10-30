# PocketDJ Privacy Policy

**Effective date: October 29, 2026**

<!--
================================================================================
MAINTAINER NOTES — not published
================================================================================
This file is the source of https://legal.pocket-dj.com/privacy/. Build and deploy:

    node scripts/legal-site-build.mjs      # renders §1 … Appendix A into legal-site/privacy/index.html
    scripts/legal-site-deploy.sh           # GREEN only: s3 sync + CloudFront invalidation

The build strips every HTML comment and stops at "## Appendix B", so Appendices B–D stay
internal. Keep the effective-date line above in the form "**Effective date: <date>**".

2026-10-29 revision (branch docs/legal-android-2026-10): adds the Android app (Google Play +
direct APK), motion/fitness, Android location, Apple Music playlist sync, the optional profile
sync, diagnostics in test builds, device identifiers, retention numbers taken from the code,
and the web account-deletion page. Placeholders resolved (Appendix C).

The 2026-07-20 target-state draft carried ~50 `#TOUPDATE` markers recording where the text
ran ahead of the code. Where this revision could make the text true by describing the code
as it is, it did, and the marker was dropped. Markers that still describe an open gap are kept
below in short form; the full original wording is in git history (`git show 1304f598:docs/legal/PRIVACY.md`).
THIS IS NOT LEGAL ADVICE. See Appendix D.
================================================================================
-->

## 1. Who this is and what it covers

PocketDJ is a music library and DJ app for iPhone, iPad, Mac, Apple TV, Apple Vision Pro, and Android. The Android app is distributed through Google Play and as a direct download (an APK file) from [pocket-dj.com](https://pocket-dj.com). Both Android builds collect the same data.

PocketDJ is built and operated by **African Intellect Enterprises LLC**, doing business as PocketDJ ("we", "us"), 4406 NE 23rd Ave, Portland, OR 97211, United States. It is a solo development effort. This policy covers the PocketDJ apps and the backend we call **PocketDJ cloud services**: the servers and storage we run on Amazon Web Services that serve the public catalog and power the optional cloud features described below.

It also covers the **jukebox guest page**: a web page your guests open when you host a request line. If you arrived here from that page, skip to [§9](#9-jukebox-hosting-and-the-guest-request-line). It is the only section about you.

We are the data controller for what this policy describes. Contact: [support@pocket-dj.com](mailto:support@pocket-dj.com).

---

## 2. The short version

- **Your music library lives on your device.** On Apple devices it can also sync through your own private iCloud database. We do not upload your library wholesale.
- **Every cloud feature that sends us information about you is off until you turn it on**, except two that run because you asked for the feature they belong to: keeping your Apple Music playlists in step once you connect Apple Music ([§5.2](#52-apple-music)), and the jukebox when you host or join one ([§9](#9-jukebox-hosting-and-the-guest-request-line)).
- **We have no advertising, no analytics, no crash-reporting, and no attribution SDKs**, on any platform. There is no advertising identifier anywhere in the app.
- **We do not sell your data, share it with data brokers, or use it for tracking.**
- **Your raw location never leaves your device.** If you turn on places & trips, only anonymous labels such as "Location A" are uploaded with your listening pockets ([§4.6](#46-listening-history-recommendations-and-listening-pockets)).
- **Speech transcription runs on your device.** Audio you dictate or transcribe never reaches Apple's, Google's, or our servers.
- **Apple Music is for playback and library management.** No audio is copied out of Apple Music by the PocketDJ app.
- **You can delete your account and the data we hold from inside the app**, or from the web at [legal.pocket-dj.com/delete-account](https://legal.pocket-dj.com/delete-account/) ([§13](#13-deleting-your-data-and-your-account)).

---

## 3. What stays on your device

These never leave your device unless you personally export or share them.

| What | Where it lives |
|---|---|
| **Microphone recordings you make in Studio** (samples, takes) | A local samples folder: the app container, or a folder you pick |
| **Recorded mix sessions and rendered instrumentals** | A local recordings folder: the app container, or a folder you pick |
| **Speech transcripts** (the karaoke panel, and feedback you dictate) | On the device ([§8](#8-two-transcription-engines-and-why-the-difference-matters)) |
| **The Now Playing widget snapshot** (title, artist, artwork, up next) | A shared container readable only by PocketDJ and its own widget |
| **Places and trips** (only if you turn on "Use places & trips in pockets", on iPhone and Android): the places you spend time and the trips between them | On the device only, in a file that is excluded from backups and never synced. Raw location samples are deleted after 30 days; each place keeps only a rounded centre point. Turning the setting off erases all of it. Only anonymous labels ever leave the device ([§4.6](#46-listening-history-recommendations-and-listening-pockets)). |
| **Walking and running detection** (only if you turn on "Notice walking & running", iPhone only) | The raw motion readings stay on the device. Only the resulting "walking" or "running" label can be uploaded, with listening pockets ([§4.6](#46-listening-history-recommendations-and-listening-pockets)). |
| **The owner identity check**: a salted hash of your iCloud user id, used to decide whether two-way Apple Music favorites sync is permitted | Computed and compared in memory on the device. Never transmitted anywhere. |
| **Diagnostic capture** (Settings ▸ Debug) in App Store and Google Play builds | An in-memory buffer while you have the toggle on. Nothing auto-uploads from these builds. If you export it and send it to us, that is your action, and it may contain song titles and audio device names. (Test builds differ; see [§4.8](#48-diagnostics-in-test-builds).) |
| **Cached catalog, artwork, and lyrics text** | On-device cache |

**One exception.** Microphone recordings and recorded mixes stay on your device *unless you send one to an import server for stem separation* ([§4.1](#41-audio-you-ask-us-to-process)).
<!-- #TOUPDATE (open): a pre-upload notice for local smp_/tk_ sources sent to /stemify-custom is still not built. Only reachable with a configured import server, which public builds don't have by default. -->

---

## 4. What goes to PocketDJ cloud services

### 4.1 Audio you ask us to process

Some features (importing audio, digitizing your own analog sources, separating a track into stems, cloud lyrics) need an **import server**, set in Settings ▸ Import server. **The app does not connect to one unless one is configured**, and the app is fully usable without it. If you run your own import server, audio you send goes to your server, not to us, and this policy does not govern what your server does with it.

If your app is connected to an import server that we operate, audio you send it is used to:

- convert it to a streamable format and store it so you can play it offline and load it into the Mix decks;
- separate it into stems (vocals, drums, bass, other) when you ask;
- analyze it for tempo, musical key, Camelot key, beat grid, and waveform, so beat-matching and key-matching work;
- transcribe lyrics when you ask ([§8](#8-two-transcription-engines-and-why-the-difference-matters)).

That processing runs on machines we operate and on our AWS account in the United States. **We do not send your audio to any outside company for AI processing.**

**You must hold the rights to any audio you upload, import, or digitize from your own sources.** That is a condition of using the service, not a privacy matter, but it is worth saying here too: we process what you send us on the basis that you are entitled to send it.

### 4.2 Where your audio is stored, and who can reach it

Audio processed by an import server we operate, and the stems, analysis, and lyrics made from it, are stored in our AWS storage in the United States. Files are filed by song rather than by person, and the app fetches them over HTTPS. PocketDJ has no feature for sending your files to other people.
<!-- #TOUPDATE (open): per-user storage keys + per-user auth + signed URLs (LATER-28/29/30 in legal-posture-conformance.md). The rips/* prefix is public-read today; the text above no longer claims a private per-user namespace. -->

### 4.3 The public catalog

PocketDJ publishes a browsable catalog so people can see collections, tracklists, and setlists for inspiration. The catalog documents contain metadata: titles, artists, albums, genres, tempo, key, beat grids, waveform images, cover art, and lyric text. The app downloads the catalog from our content delivery network; no information about you is sent with those downloads beyond what any web request carries ([§4.9](#49-server-logs)).
<!-- #TOUPDATE (open): the "not a way to obtain audio" sentence was removed because rips/manifest.json and rips/* are publicly readable (Decision A, legal-posture-conformance.md §8). Restore it only once that is closed. -->

### 4.4 Search

- **Discover search** sends the words you type to Apple: to the Apple Music catalog if you have connected Apple Music, or, if your app is connected to an import server, through that server to Apple's public iTunes Search API. Search through an import server carries no user identifier.
- **Online catalog search** is off by default and needs credentials you enter in Settings. When on, your query goes to our managed search service. We do not associate queries with your profile.

### 4.5 Identifiers sent with cloud requests

When a cloud feature is on, PocketDJ attaches two identifiers to its requests so the servers can keep your data apart from everyone else's:

- your **profile identifier**, a random value created on first run (the recommendation and pockets services receive a value derived from it rather than the identifier itself); and
- a **device identifier** for this installation. On Apple devices it is seeded from Apple's identifier for this app vendor on this device; on Android it is a random value created by the app. PocketDJ never reads an advertising identifier or Android's device ID.

Deleting your account resets both ([§13](#13-deleting-your-data-and-your-account)).

### 4.6 Listening history, recommendations and listening pockets

**Off by default.** Nothing in this section leaves your device unless you turn on **Settings ▸ Recommendations ▸ Use PocketDJ Recommendation Engine**. This works the same way on Apple devices and on Android.

**The Recommendation Engine.** When it is on, PocketDJ sends your listening history (which songs you played and when), your favorites, your 👍/👎 feedback, your collections and their names, your Gem Collector results, and (unless you turn off "Include lifetime play counts") your lifetime play counts to PocketDJ cloud services, which use them to compute your For You and suggested-collection lists. Your data is stored under a random key that only your devices hold.

**Listening pockets.** A listening pocket is a stretch where you played three or more songs in a row without skipping. Finding them is a separate switch, **Find my listening pockets**, which is off until you turn it on. When you turn it on, it sends, for each play in the previous 90 days and from then on:

- the song id, and when it started, rounded down to the minute;
- your time-zone offset at the time, so the analysis can use your local time of day;
- whether you finished it or skipped it, and how much of it played;
- where in the app you played it (for example Mix or a playlist, by id) and whether CarPlay was connected;
- the artist name shown for it;
- which of your collections the song belongs to (ids only).

Each upload also carries a random identifier for this installation and the device identifier described in [§4.5](#45-identifiers-sent-with-cloud-requests). Our servers use this to find your pockets and describe what they have in common, such as the genre, the tempo range, the time of day, the place or trip, and whether you were walking or running.

**Places and trips, if you turn them on (iPhone and Android).** A separate setting, **Use places & trips in pockets**, is off by default and needs pockets to be on. It learns, on your device, which of your places you were at during a play, or that you were travelling between two of them.

- **On iPhone** it uses iOS visit reports.
- **On Android** it uses Google Play services' location provider in a low-power mode: a location reading when you have moved a few hundred metres, plus a check about every 15 minutes so the app can tell that you have stayed somewhere. Android asks you first for location access while the app is in use, and then, separately, for access **all the time** ("Allow all the time"). Background access lets PocketDJ notice trips between your places while music plays with the screen off. You can keep foreground-only access, or turn the feature off, at any time.

On both platforms, your places are numbered by how much time you spend at each (Location A, Location B, …) and are never identified as home, work, or an address. What is uploaded is the anonymous label for each play (a random place id, or a random trip id with its starting and ending place ids) and a summary of your places and trips: each place's "Location A"-style name and the share of your time spent there, and each trip's name (such as "A → B") and how many times you have made it. **Your raw location never leaves your device**, and PocketDJ does not send it to us or to anyone else.

**Walking and running, if you turn it on (iPhone only).** **Settings ▸ Pocket Wheel ▸ Notice walking & running** is off by default. With your permission, it reads Apple's Motion & Fitness activity on the device to tell whether you were walking or running while a song played. Only that label ("walking", "running", or "on a trip") travels with the play in your listening-pockets upload, and only while both this setting and listening pockets are on. The Android app does not read physical activity.

**The "In the Pocket" game.** The game needs listening pockets on (it offers the same switch, and never turns it on for you). Each round, PocketDJ picks three or four songs it predicts you will play straight through, using the time of day, weekday or weekend, and, only if places & trips is on, the anonymous label of the place or trip you are probably at. When a round ends, PocketDJ uploads it with your pockets data, as an example the analysis learns from: when it started (rounded down to the minute) and your time-zone offset, that context, the songs, what the prediction was based on, whether each song was played through or skipped, and, only if you give them, your 1–5 rating and the feedback you write (up to 2,000 characters). **If you dictate feedback with the microphone button, the speech is turned into text on your device; the audio is never uploaded or kept, and only the text in the field is sent.** We use rounds to improve how well pockets are predicted.

**Turning things off.** Turning the engine or pockets off stops all uploads, and also turns places & trips off and erases your places from the device. Data already uploaded stays on our servers until you choose **Delete cloud data** (in Settings ▸ Recommendations) or delete your account ([§13](#13-deleting-your-data-and-your-account)), so that turning a switch off and on again doesn't erase your history.

### 4.7 Profile sync on Android (optional)

Apple devices sync through your own iCloud ([§5.1](#51-icloud-sync-cloudkit)). Android has no iCloud, so PocketDJ for Android has its own optional sync, **Settings ▸ Profile ▸ Sync across devices**, which stores your profile, collections, play history, favorites, and settings in PocketDJ cloud services so another device you link can use them. **Profile sync is not switched on yet for any Android user; when it becomes available, it will be off until you turn it on.** Synced data is stored under your profile in our AWS storage until you turn sync off and delete it, or delete your account.
<!-- #TOUPDATE (open, BLOCKING before profileSyncBase is published in endpoints.json): android SyncSettings.kt:8 defaults cloudSyncEnabled to TRUE. Flip it to false first, or the sentence above becomes false the moment the endpoint key ships. -->

### 4.8 Diagnostics in test builds

The App Store, Google Play, and direct-download builds **do not upload diagnostics**. Beta builds distributed through TestFlight, and internal development builds, upload diagnostic logs (playback events, errors, song ids, and a short device identifier) to our storage so we can fix problems testers hit. Those logs are deleted after 14 days.

### 4.9 Server logs

Like any website, our content delivery network records each request it serves: the time, the address requested, your IP address, and your browser or app's user agent. Our servers and cloud functions also keep operational logs: request timing, errors, song ids, and, for the jukebox, the text of guest requests. IP addresses reaching the jukebox are used for rate limiting. See [§11](#11-how-long-we-keep-things) for retention.

---

## 5. What goes to Apple

### 5.1 iCloud sync (CloudKit)

On Apple devices, if you are signed in to iCloud and sync is on, PocketDJ syncs these documents to **your own private iCloud database**:

your profile · collections (pockets, playlists, setlists) · your edits · favorites · play stats · play history · mix sessions · your current playback session · mix deck state · Discover adds · imported songs · game scores · settings

Each synced record also carries **the name of the device that pushed it**, so the app can show you which device synced last. Your device name may identify you; many are of the form "*&lt;your first name&gt;*'s iPhone".

This data sits in your Apple Account's private database, governed by [Apple's privacy policy](https://www.apple.com/legal/privacy/). **We cannot read it.** PocketDJ uses only CloudKit's private database. Turn sync off in Settings ▸ Profile.

*How we classify this:* because a CloudKit private database is not readable by us, we take the position that it is **not "collected" by us** for App Store privacy-label purposes. We are stating that position openly so you can disagree with it if you want to.

### 5.2 Apple Music

If you connect an Apple Music subscription (on Apple devices through MusicKit; on Android through Apple's MusicKit for Android, which signs you in through the Apple Music app), PocketDJ:

- **plays** full-length tracks through Apple's player;
- **reads** your library's playlists, so collections you converted from an Apple Music playlist stay in step with their source;
- **writes to your library only when you ask it to**: adding a song or album you chose to add, or adding a song to one of your playlists.

**Keeping playlists in step.** Once Apple Music is connected, PocketDJ keeps your linked playlists in step automatically, about once a day; you can turn automatic syncing off in Settings ▸ Apple Music, or sync by hand. To do this, PocketDJ sends our playlist-sync service your Apple Music user token (the credential Apple issues so an app can act on your library), the names of the playlists involved, and the Apple Music catalog ids of their songs. Our service passes the request on to Apple Music. **The token is used for that request only and is never stored**; the job record is deleted after one day.

**No audio is copied, captured, recorded, or downloaded out of Apple Music by the PocketDJ app.** What Apple receives when you use Apple Music is governed by Apple's privacy policy.
<!-- #TOUPDATE (open): the capture gate (Decision A) concerns the import server, not the shipped app; keep this sentence scoped to "the PocketDJ app" until the server side is closed. -->

**Favorites.** Your ♥ in PocketDJ is local, and on Apple devices syncs to your private iCloud database. Two-way sync with your Apple Music account is currently restricted to the developer's own account and is off for everyone else. If that ever opens up, you should know before you turn it on: **adding a song to Apple Music's Favorite Songs cannot be undone by any app**, because Apple provides no removal API for it. We will not enable this for anyone without an explicit, informed opt-in.

### 5.3 Song recognition (ShazamKit)

On Apple devices, when you use song recognition, your device listens through the microphone and computes an **acoustic signature**, a compact mathematical fingerprint. **The signature is what gets sent to Apple's Shazam service. Your raw microphone audio is not transmitted**, and no PocketDJ server is involved in the recognition itself. Governed by Apple's privacy policy. We keep the match result (title, artist, catalog id) locally. Song recognition is not available in the Android app.

**Acting on a match is a separate step.** If you choose to add a recognized song and have an import server process it, the title, artist, and Apple Music catalog id are sent to that server ([§4.1](#41-audio-you-ask-us-to-process)).

---

## 6. Google and Android

These apply only to the Android app.

- **Google Play.** If you install PocketDJ from Google Play, Google handles the download, updates, and any reviews you leave, under [Google's privacy policy](https://policies.google.com/privacy). We receive the aggregate statistics Google Play provides to developers. The direct-download APK from pocket-dj.com does not involve Google Play.
- **Location.** Places & trips ([§4.6](#46-listening-history-recommendations-and-listening-pockets)) gets location readings from Google Play services' location provider on your device. How Google handles location on your device is governed by your Android location settings and Google's privacy policy. PocketDJ does not send your location to Google or to us.
- **Backup.** If Android backup is on, Android may back up some PocketDJ files (your collections and history) to **your own** Google account, under Google's terms. PocketDJ excludes your credentials, secrets, settings, places and trips, and game rounds from that backup. We cannot read your backups.
- **On-device speech.** Dictating feedback uses Android's on-device speech recognizer with offline recognition only. The audio is not sent anywhere.
- **Permissions.** PocketDJ asks for: location (only for places & trips), microphone (only for Studio recording and dictation), notifications (playback controls and download progress), and nearby Bluetooth devices (only to connect MIDI controllers; PocketDJ does not use Bluetooth to find your location). It also uses Android's standard permissions for network access and for playing and downloading in the background. You can revoke any of them in Android Settings.

---

## 7. Microphone

PocketDJ asks for microphone access for these things, and only when you start them:

1. **Recording samples and takes in Studio.** These stay on your device ([§3](#3-what-stays-on-your-device)) unless you send one to an import server for stem separation.
2. **Song recognition** (Apple devices only). ShazamKit takes over the microphone, derives a signature, and sends only the signature ([§5.3](#53-song-recognition-shazamkit)).
3. **Dictating feedback in "In the Pocket".** Only from the moment you tap the feedback field's microphone button until you tap it again. The speech is turned into text **on your device** (Apple Speech or Android's on-device recognizer; PocketDJ requires on-device recognition), and the audio is neither stored nor sent anywhere. The resulting text is uploaded only as the round's feedback ([§4.6](#46-listening-history-recommendations-and-listening-pockets)).

PocketDJ does not listen in the background, does not record without an explicit action from you, and has no ambient-listening feature.

---

## 8. Two transcription engines, and why the difference matters

**On-device transcription.** When PocketDJ transcribes audio for the synced word-by-word karaoke overlay, it forces on-device recognition and **refuses to run if the device cannot do it locally**. There is no server fallback. The audio never leaves your device.

**Cloud lyrics transcription.** Separately, an import server can generate timed lyrics from a track's isolated vocal stem. That **uploads the audio** to the import server ([§4.1](#41-audio-you-ask-us-to-process)), where a transcription model we run produces the lyrics. No outside AI company receives your audio. If you want lyrics without uploading anything, use the on-device transcription instead.

---

## 9. Jukebox hosting and the guest request line

Jukebox lets you run a request line at an event you are hosting. Guests scan a code, see what is playing, and send requests. **It is built for private events you host.** If you play music for an audience, any performance licensing your venue or event requires is your responsibility. The app does not provide it.

### 9.1 If you are the host

While a session is live, PocketDJ publishes to the guest page: **your DJ display name**, the current track, your upcoming queue, recently played tracks, and the request list with your accept/deny decisions. Anyone with the session's link can open that page.

Session links are random and are not listed or search-indexable. A normal session ends automatically after 24 hours, and its data is deleted 7 days after it is created. If you make a session **timeless**, it does not end on its own: it stays until you end it.
<!-- #TOUPDATE (open): no guest token, no listener cap, and timeless sessions are never swept (jukebox-server.mjs). The text above no longer claims a token gate or a cap. -->

The **Music with Friends** game uses the same service: joining a game sends your DJ display name and your moves, and on Apple devices a push-notification token so the game can tell you when it is your turn. That token is withdrawn when you leave or delete your account.

### 9.2 If you are a guest: what we collect from you

You do not need an account, and we do not ask for your name, email, or phone number.

**What we receive when you send a request:**

- the song title and artist you type;
- a random identifier your browser generates and stores locally, so we can pace requests fairly;
- your IP address, as with any web request, used to operate the service and to stop abuse.

**What the host sees:** the text of your request. Not your IP address.

**What other guests see:** the request text on the queue. Nothing that identifies you.

**How long:** see [§11](#11-how-long-we-keep-things).

**Lawful basis (EU/UK):** legitimate interests: running a request line you chose to use, and keeping it secure and abuse-free. You can object; see [§12](#12-your-rights-and-your-controls).

### 9.3 Listen-along

A host can optionally let guests hear the current track on their own phones. It is **off by default** and only the host can turn it on. When it is on, guests stream the host's own copy of the track for the duration of the session. **This is for people physically present at the event you are hosting.** The Terms of Service prohibit using PocketDJ to broadcast or otherwise transmit music to people who are not present at your event.

---

## 10. What we do not do

- We do not sell your personal data.
- We do not share it with data brokers or advertisers.
- We do not track you across other companies' apps and websites. The app declares no tracking, requests no tracking permission, and reads no advertising identifier.
- We do not run ads.
- We do not collect your precise location, contacts, photos, health records, financial, or browsing data. Your raw location never leaves your device. If you turn on places & trips, we receive only anonymous place and trip labels such as "Location A" or "A → B" ([§4.6](#46-listening-history-recommendations-and-listening-pockets)).
- We do not upload diagnostics or crash reports from App Store, Google Play, or direct-download builds.
- We do not read your iCloud private database or your Google backups.
- We do not sell or share your personal information as those terms are defined by California law. See [§12.3](#123-california-and-other-us-state-privacy-rights).

---

## 11. How long we keep things

| Data | Retention |
|---|---|
| Recommendation Engine data (listening history, favorites, feedback, collections, play counts) | Until you choose **Delete cloud data** or delete your account. The stored state has a size cap, and the oldest history is dropped first when it fills. |
| Listening-pocket play events (including place/trip and walking/running labels) | 180 days from the play, then removed automatically (at most 20,000 events). Deleted at once by **Delete cloud data**. |
| Collection-membership history for pockets | 365 days, then removed automatically. Deleted at once by **Delete cloud data**. |
| "In the Pocket" rounds and feedback | 180 days (at most 500 rounds). Deleted at once by **Delete cloud data**. |
| Listening-pocket results (your pockets and recurring patterns) | Replaced each time they are recomputed. Deleted at once by **Delete cloud data**. |
| Places and trips (on the device only) | Raw location samples for 30 days; places you haven't visited for 180 days are forgotten; everything is erased when you turn the setting off |
| Apple Music playlist-sync jobs | 1 day. Your Apple Music user token is never stored. |
| Android profile sync (once available, if you turn it on) | Until you delete it or delete your account |
| Audio and derived files on an import server we operate | Until you ask us to delete them ([§13](#13-deleting-your-data-and-your-account)) |
| Jukebox and Music with Friends sessions, guest requests, guest identifiers, and IP addresses | A normal session ends after 24 hours and is deleted 7 days after creation. A timeless session is kept until the host ends it. |
| Diagnostic logs from TestFlight and development builds | 14 days |
| Content delivery network request logs | 365 days |
| Operational logs of our cloud functions | Kept without a fixed expiry today; they contain request metadata, not your library |
| Email you send us | Raw messages are deleted from our mail intake after 30 days; replies stay in our mailbox |
| Data in your private iCloud database | Controlled by you, in your Apple Account |
| Everything on your device | Until you delete it, or until the storage manager's least-recently-played cleanup removes it if you set a storage cap |
<!-- #TOUPDATE (open): set CloudWatch log retention (no put-retention-policy anywhere in scripts/) and bound timeless jukebox sessions; then tighten the two rows above. -->

---

## 12. Your rights and your controls

**Controls built into the app**, wherever you live:

- **Settings ▸ Profile**: on Apple devices, turn iCloud sync off; on Android, profile sync (once available).
- **Settings ▸ Recommendations**: the Recommendation Engine, listening pockets, and places & trips each have their own switch. **Delete cloud data** erases what they uploaded, and **Erase places & trips** erases your places on the device.
- **Settings ▸ Pocket Wheel ▸ Notice walking & running** (iPhone): on or off at any time.
- **Settings ▸ Apple Music**: turn automatic playlist syncing off, or disconnect Apple Music.
- **Settings ▸ Storage**: delete downloaded audio and recordings by artist, by collection, or all of it; set a storage cap.
- **Export**: take your collections, playlists, and library out as a file at any time. That is your data-portability route, and it does not require asking us.
- **Permissions** (microphone, location, motion, notifications, Bluetooth, Apple Music): revocable at any time in your device's Settings.
- **Delete account**: see [§13](#13-deleting-your-data-and-your-account).

**Legal rights.** Depending on where you live, including under the EU GDPR, the UK GDPR, and US state privacy laws, you may have the right to access, correct, delete, export, or restrict our processing of your personal data, to object to processing based on legitimate interests, to withdraw consent, and to lodge a complaint with your data protection authority. Most of your data is on your device or in your own iCloud account, so you already control it directly. For anything we hold, write to [support@pocket-dj.com](mailto:support@pocket-dj.com) and we will respond within one month.

### 12.1 The categories of personal data we process

- **Identifiers**: your profile identifier and installation identifier (random values; on Apple devices the installation identifier is seeded from Apple's identifier for this app vendor), your DJ display name, on Apple devices a push-notification token if you join Music with Friends, and for jukebox guests an IP address and a random browser identifier.
- **User content**: your collections and their names, favorites, and feedback, if you turn on the Recommendation Engine or profile sync; "In the Pocket" feedback; jukebox request text; audio you send to an import server we operate, and what is derived from it.
- **Usage data**: if you turn on the Recommendation Engine, play history, play counts, and, for listening pockets, whether each play was finished or skipped and its local time of day; the now-playing and queue state published while a jukebox session is live.
- **Approximate location labels**: only if you turn on places & trips: random place and trip ids, "Location A"-style names, each place's share of your time, and how often each trip was made. Never coordinates.
- **Fitness label**: only if you turn on walking & running (iPhone): whether you were walking or running during a play.
- **Credentials in transit**: your Apple Music user token, used for playlist sync and never stored.
- **Search data**: Discover search terms, and online catalog queries if you turn that on.
- **Device and network data**: the device name attached to each iCloud-synced record, and request metadata in server logs.

We process no special-category data (GDPR Art. 9), no raw location, no contacts, no health or financial data, and no browsing history.

**Whether you have to provide it.** None of this is a statutory requirement. Each feature needs its data to work; if you leave a feature off, it simply does not run, and the rest of the app works.

**Automated decision-making.** If you turn on the Recommendation Engine or listening pockets, PocketDJ uses your listening to suggest music. It makes no automated decision that has legal or similarly significant effects on you.

### 12.2 Our lawful bases (EU/UK)

| Processing | Basis |
|---|---|
| Running the app, playlist sync after you connect Apple Music, jukebox sessions you host or join, processing audio you send to an import server | Performance of a contract: you asked for the feature |
| Recommendation Engine, listening pockets, places & trips, walking & running, "In the Pocket" feedback, Android profile sync, two-way favorites sync | Consent: each is off until you turn it on, and you can turn it off at any time |
| Jukebox guest requests, rate limiting, abuse prevention, security logging | Legitimate interests |
| Meeting legal obligations, including responding to valid copyright notices | Legal obligation |

### 12.3 California and other US state privacy rights

If you are a California resident, you have rights to know, delete, correct, and opt out of the sale or sharing of your personal information, and to limit the use of sensitive personal information. **We do not sell or share personal information as those terms are defined by the CCPA/CPRA, and we do not use sensitive personal information for purposes that require a right to limit.** We will not discriminate against you for exercising any of these rights. The categories we collect are listed in [§12.1](#121-the-categories-of-personal-data-we-process), and we disclose them only to our service providers (Amazon Web Services) to run the service. To make a request, write to [support@pocket-dj.com](mailto:support@pocket-dj.com).

### 12.4 If there is a data breach

If personal data we hold is breached in a way that is likely to result in a risk to your rights and freedoms, we will notify the relevant authorities as the law requires and, where the risk is high, notify you directly.

### 12.5 The other documents

This policy is one of three. See also the [Terms of Service](https://legal.pocket-dj.com/terms/) and the [Copyright / DMCA Policy](https://legal.pocket-dj.com/dmca/).

---

## 13. Deleting your data and your account

PocketDJ has no username or password. It creates a **profile**, a random identifier plus a display name you choose, so your library can sync, your cloud features can find your data, and guests know whose jukebox they are in. For deletion, your profile is your account.

**Delete your account in the app:**

- **iPhone, iPad, Mac, Apple TV, Apple Vision Pro:** Settings ▸ Profile ▸ **Delete Account**.
- **Android:** Settings ▸ Reset ▸ **Delete account**.

In one action this ends any jukebox session you are hosting; deletes your Recommendation Engine and listening-pockets data (including "In the Pocket" rounds) from our servers; deletes your Android profile-sync data; deletes your iCloud-synced PocketDJ records (Apple devices); withdraws your Music with Friends registration; erases PocketDJ's data, downloads, and credentials on the device; and resets your profile and installation identifiers. If a server can't be reached, the app retries the deletion the next time it can. It cannot be undone.

**Only want to remove what the cloud features uploaded?** Settings ▸ Recommendations ▸ **Delete cloud data** deletes your Recommendation Engine and listening-pockets data and leaves the app and your device history as they are.

**No longer have the app, or can't open it?** Go to [legal.pocket-dj.com/delete-account](https://legal.pocket-dj.com/delete-account/) or email [support@pocket-dj.com](mailto:support@pocket-dj.com) with the subject "Delete my PocketDJ data". We will delete what we hold that we can find for you and confirm by reply within one month.

**What deletion does not reach immediately:** content delivery network logs (deleted after 365 days), test-build diagnostic logs (14 days), jukebox session copies (7 days after creation, or when you end a timeless session), and our cloud functions' operational logs. These hold request metadata, not your library. Your private iCloud data, if you delete the app without deleting your account, stays in your Apple Account until you remove it (Apple Settings ▸ your name ▸ iCloud ▸ Manage Storage), and any Android backup stays in your Google account until you remove it.

---

## 14. Children

**PocketDJ is not directed to children under 13**, and we do not knowingly collect personal information from them. The app is not in the App Store Kids category or Google Play's Families program. The store age ratings reflect that recorded music and album artwork can contain mature themes and profanity, not anything in the app itself.

If you believe a child under 13 has provided us personal information, email [support@pocket-dj.com](mailto:support@pocket-dj.com) and we will delete it.

---

## 15. Where your data goes, internationally

**Our servers and storage are in the United States.** If you use PocketDJ from outside the US, including from the EU or UK, the data described in [§4](#4-what-goes-to-pocketdj-cloud-services) and [§9](#9-jukebox-hosting-and-the-guest-request-line) is transferred to and processed in the United States, because that is where the service you asked for runs. Data you sync through iCloud is handled by Apple under Apple's own arrangements, and Android backups by Google under Google's.

We have not appointed a representative in the EU or UK or a Data Protection Officer. Write to us directly at [support@pocket-dj.com](mailto:support@pocket-dj.com).

---

## 16. Security

All traffic between the app and our services uses HTTPS. Credentials the app holds for you are stored in the system keychain or Android's encrypted storage, and our storage is encrypted at rest.

No system is perfectly secure. If you find a vulnerability, please report it to [security@pocket-dj.com](mailto:security@pocket-dj.com).
<!-- #TOUPDATE (verify): confirm every credential path is Keychain/EncryptedSharedPreferences (the 2026-07 draft flagged plaintext UserDefaults for search/rip/jukebox tokens). -->

---

## 17. Changes to this policy

We will post any change here and update the effective date at the top.

**If a change materially expands what we collect, how we use it, or who receives it, we will tell you in the app before the change takes effect** and, where the law requires consent, ask for it rather than assume it.

Past versions are kept in the project's public repository history, so you can see exactly what changed and when.

---

## 18. Contact

**Privacy questions, access requests, deletion requests:** [support@pocket-dj.com](mailto:support@pocket-dj.com)

**Security reports:** [security@pocket-dj.com](mailto:security@pocket-dj.com)

**Postal:** African Intellect Enterprises LLC (PocketDJ), 4406 NE 23rd Ave, Portland, OR 97211, United States

We aim to respond within one month.

If you are in the EU or UK and are not satisfied with our response, you may complain to your national data protection authority.

---

## Appendix A — Data flow summary

Read this as the one-page version of §3 through §9.

| Data | Leaves device? | Where to | Linked to you? |
|---|---|---|---|
| Microphone recordings and recorded mixes | **No**, unless you send one to an import server | Device only | — |
| On-device speech transcripts and dictation | **No** | Device only | — |
| Song recognition (Apple devices) | Signature only | Apple's Shazam service. Raw audio never sent. | No |
| Raw location and motion readings | **No** | Device only | — |
| Profile, collections, favorites, play history (Apple devices) | **Yes**, if iCloud sync is on | Your private iCloud database (we cannot read it) | Yes |
| Profile, collections, favorites, play history (Android) | Only if you turn on profile sync, once available | PocketDJ cloud services (AWS, US) | Yes |
| Listening history, favorites, feedback, collection names, play counts | **Yes**, only while the Recommendation Engine is on | PocketDJ cloud services (AWS, US) | Yes, under a random key |
| Listening-pocket play events and "In the Pocket" rounds | **Yes**, only while the engine and pockets are both on | Same | Same |
| Anonymous place and trip labels | **Yes**, only while places & trips is also on (iPhone, Android) | Same | Same |
| Walking / running label | **Yes**, only while walking & running is also on (iPhone) | Same | Same |
| Profile and installation identifiers | **Yes**, with cloud requests | PocketDJ cloud services | Yes |
| Apple Music user token, playlist names, catalog ids | **Yes**, once Apple Music is connected and playlist sync runs | PocketDJ playlist-sync service → Apple Music. Token not stored. | Yes |
| Apple Music playback and library reads and writes | **Yes** | Apple (your own account) | Yes |
| Jukebox: host display name, now playing, queue, requests | **Yes**, while a session is live | PocketDJ cloud services; public to anyone with the link | Display name |
| Jukebox guest request text, guest identifier, guest IP | **Yes** (from the guest's browser) | PocketDJ cloud services | No account; IP and identifier are personal data |
| Audio sent to an import server | Only if one is configured | That server (ours, or yours) | Yes, if ours |
| Discover search terms | **Yes** | Apple (Apple Music catalog, or iTunes Search through an import server) | No |
| Online catalog search queries (opt-in) | **Yes** | Our managed search service | No |
| Catalog, artwork, lyrics text downloads | Requests only | Our CDN (request logs) | No |
| Diagnostics | Test builds only | PocketDJ cloud services, 14 days | Yes |
| Android backup | If Android backup is on | Your own Google account | — |
| Exports (.pdjcollection, backups) | Wherever you send them | Your choice | Yes, they contain your library |

*PocketDJ is built by one person. This policy is written to be read. If something in it is unclear or looks wrong, write to [support@pocket-dj.com](mailto:support@pocket-dj.com) and it will get fixed.*

---

## Appendix B — Store label consistency (internal, not published)

App Review (Guideline 5.1.1) and Google Play (User Data policy) both reject when the label and the policy disagree. The data inventory of 2026-10-29 (`main` @ 1304f598) is the source for both tables.

**Apple App Privacy** (all linked, none used for tracking; `NSPrivacyTracking=false`):

| Label entry | Purposes | Where this policy covers it |
|---|---|---|
| Location ▸ Coarse Location | App Functionality, Product Personalization | §4.6 places & trips |
| Health & Fitness ▸ Fitness | App Functionality, Product Personalization | §4.6 walking & running |
| User Content ▸ Audio Data | App Functionality | §4.1 (configured import server) |
| User Content ▸ Other User Content | App Functionality, Analytics, Product Personalization | §4.6 collections, round feedback; §9 |
| Usage Data ▸ Product Interaction | App Functionality, **Product Personalization, Analytics** (add the two — inventory gap 2) | §4.6, §9.1 |
| Search History | App Functionality | §4.4 |
| Identifiers ▸ User ID | App Functionality | §4.5 |
| Identifiers ▸ Device ID | App Functionality — **add (inventory gap 1)**, IDFV-seeded install id + APNs token | §4.5, §9.1 |
| Contact Info ▸ Name | App Functionality | §9.1 DJ display name |
| Diagnostics ▸ Other Diagnostic Data | App Functionality | §4.8, §4.9 |

**Google Play Data safety** (encrypted in transit: yes; shared: no; deletion: in-app + web URL; not used for ads/tracking):

| Category ▸ type | Optional | Purposes | Section |
|---|---|---|---|
| Location ▸ Approximate location (background declared) | Yes | App functionality, Personalization | §4.6 |
| App activity ▸ App interactions | Yes | App functionality, Personalization, Analytics | §4.6 |
| App activity ▸ Other user-generated content | Yes (playlist sync runs once AM linked) | App functionality, Personalization | §4.6, §5.2, §9 |
| App activity ▸ In-app search history | Yes | App functionality | §4.4 |
| Personal info ▸ Name | Yes | App functionality | §9 |
| Personal info ▸ User IDs | Required while a cloud feature is on | App functionality, Account management | §4.5 |
| Device or other IDs | Required while a cloud feature is on | App functionality | §4.5 |
| Personal info ▸ Other (Apple Music user token, processed ephemerally) | Yes | App functionality | §5.2 |

Not collected on Android release builds: precise location (raw fixes stay on device), health & fitness (no ACTIVITY_RECOGNITION), audio files (import server is self-configured), crash logs/diagnostics (DIAG_CHANNEL=false).

---

## Appendix C — Placeholders (internal, not published)

Resolved 2026-10-29: effective date (October 29, 2026); legal entity (African Intellect Enterprises LLC, d/b/a PocketDJ); postal address (4406 NE 23rd Ave, Portland, OR 97211); contact (support@pocket-dj.com; the domain is owned and SES `forward-all` accepts every address at pocket-dj.com); security contact (security@pocket-dj.com); response time (one month, the GDPR default); age rating (described generically, no number); retention periods (taken from code, §11); transfer mechanism and EU representative (stated honestly as none adopted / none appointed, §15); Terms/DMCA URLs (legal.pocket-dj.com).

---

## Appendix D — Questions for counsel (internal, not published)

1. Is the profile "account creation" for Apple 5.1.1(v) and Play's account-deletion rule? This revision treats it as an account for deletion and publishes a web deletion page.
2. §15: is relying on necessity for the US transfer adequate, or should we self-certify to the EU–US Data Privacy Framework (or restrict availability to the US, Decision F)? Is an Art. 27 representative required at this scale?
3. §12.2: are the consent and contract bases assigned correctly, in particular contract for Apple Music playlist sync, which runs by default once Apple Music is connected?
4. Guest data and children (§9.2, §14): the guest page collects an IP and a browser id from members of the public with no notice on the page itself.
5. Background location on Android: does the policy text plus the in-app flow satisfy Play's prominent-disclosure requirement?
6. Terms §15 governing law (Oregon), §13.2 liability cap, and §16 dispute resolution were filled with conservative defaults on 2026-10-29 and need sign-off.
