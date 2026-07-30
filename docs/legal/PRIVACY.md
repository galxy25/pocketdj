# PocketDJ Privacy Policy

**Effective date: {{EFFECTIVE_DATE}}**
**Draft prepared 2026-07-20. Not yet published.**

---

<!--
================================================================================
DRAFT STATUS — DELETE THIS BLOCK BEFORE PUBLISHING
================================================================================
This document is written in TARGET STATE: it describes PocketDJ as it is intended
to be at first public release, not as the code stands today.

Every forward-looking claim carries a `#TOUPDATE` HTML comment naming what must
become true before that sentence is honest. Before publishing:

    grep -n "#TOUPDATE" docs/legal/PRIVACY.md

Resolve every one. A privacy policy that describes a control you have not built
is not a drafting error — it is a misrepresentation, and it is the specific kind
that draws both an App Review 5.1.1 rejection and an FTC-style deception claim.

Every `{{PLACEHOLDER}}` must also be replaced. They are listed in Appendix C.
NOTE: the domain pocketdj.app resolves to a parking IP with no registration
record. Do not fill any placeholder with an address at a domain you do not own
and have not tested — a bounced privacy request is worse than no address.

THIS IS NOT LEGAL ADVICE. See Appendix D for the questions counsel must answer.
================================================================================
-->

## 1. Who this is and what it covers

PocketDJ is a music library and DJ app for iPhone, iPad, Mac, and Apple Vision Pro. It is built and operated by {{LEGAL_ENTITY}} ("we", "us"), a solo development effort. This policy covers the PocketDJ apps and the backend we call **PocketDJ cloud services** — the servers and storage that process audio you send us and serve the public catalog.

It also covers the **jukebox guest page**: a web page your guests open when you host a request line. If you arrived here from that page, skip to [§9](#9-jukebox-hosting-and-the-guest-request-line) — it is the only section about you.

We are the data controller for what this policy describes. Contact: {{CONTACT_EMAIL}}.

---

## 2. The short version

- **Your music library lives on your device and in your own storage.** We do not upload it wholesale.
  <!-- #TOUPDATE: "your own storage" asserts exactly the per-user namespace that §4.2's marker says does not exist. Today every stored object lives in ONE shared bucket keyed by content id, publicly readable. This is the summary line users actually read, 47 lines above the section that corrects it — it must not ship before the §4.2 work lands. Until then the honest phrasing is "on your device and in storage we operate". -->
- **Audio you choose to process — an upload, a file you import, a recording from your own analog source — is sent to PocketDJ cloud services** to be converted, analyzed, and made available back to you. That is the main thing that leaves your device, and it only happens when you ask for it.
- **We have no advertising, no analytics, no crash-reporting, and no attribution SDKs.** None. The app ships exactly one third-party library (ZIPFoundation, for reading and writing zip files) and it does not touch the network.
- **We do not sell your data, share it with data brokers, or use it for tracking** as the App Store defines tracking.
- **Speech transcription runs on your device.** Audio for the karaoke transcript never reaches Apple's servers or ours. See [§8](#8-two-transcription-engines-and-why-the-difference-matters) — there is a second, cloud-based lyrics feature and the difference matters.
- **Apple Music is playback and library management only.** No audio is copied out of Apple Music by PocketDJ, ever.
  <!-- #TOUPDATE: THE CAPTURE GATE. Stated as a condition on the SHIPPED BUILD, not on any branch — a future reader cannot evaluate a branch name, and a claim that is true on a branch is false in the App Store. All five must hold of the build you submit:
       (1) no code path in the shipped client sends an Apple-Music-sourced song id to the rip server. The Discover add-then-process path (RipsStore.swift:794-817, discoverAdd/discoverAddRip) is STILL OPEN — the source's own doc comment at RipsStore.swift:798-800 carries an in-code #TOUPDATE conceding the server "does not yet restrict itself to user-uploaded media." Remove it, or narrow it to sources the user owns.
       (2) the server REJECTS Apple-Music-sourced ids at acceptRip (scripts/rip-server.mjs), mirroring the STUDIO_ID fence — client-side removal alone is not a control.
       (3) capture FAILS CLOSED for Apple Music sources: the default on an unrecognized or unattributed source is refusal, not capture.
       (4) both paths are gone from the BACKEND and the SHIPPED CLIENT, not one or the other.
       (5) PREVIOUSLY CAPTURED OBJECTS ARE DELETED from the rips bucket, and §11 and §13 say so. A retention section that omits material the service should never have held is incomplete on its own terms.
       Cross-doc: this is the same gate as TERMS §6.7 and it must be resolved identically in both. Tracking: legal-posture-conformance.md §8 Decision A ("Apple Music capture — what happens to it?"), which is RECOMMENDED BUT NEVER DECIDED. -->

---

## 3. What stays on your device

These never leave your device unless you personally export or share them.

| What | Where it lives |
|---|---|
| **Microphone recordings you make in Studio** (samples, takes) | A local samples folder — the app container, or a folder you pick |
| **Recorded mix sessions and rendered instrumentals** | A local recordings folder — the app container, or a folder you pick |
| **Speech transcripts for the karaoke panel** | The local Demux document ([§8](#8-two-transcription-engines-and-why-the-difference-matters)) |
| **The Now Playing widget snapshot** (title, artist, artwork, up-next) | A shared App Group container readable only by PocketDJ and its own widget |
| **The owner identity check** — a salted hash of your iCloud user id, used to decide whether two-way Apple Music favorites sync is permitted | Computed and compared in memory on device. Never transmitted anywhere. |
| **Diagnostic capture** (Settings ▸ Debug) | An in-memory buffer while you have the toggle on. Nothing auto-uploads. If you export it and send it to us, that is your action, and it may contain song titles and audio device names. |
| **Cached catalog, artwork, and lyrics text** | On-device cache <!-- #TOUPDATE: FALSE AS WRITTEN. This row said "cleared from Settings ▸ Storage". It cannot be: the storage manager deletes DOWNLOADED MEDIA ONLY. apple/Tests/Unit/BurnStoreStorageTests.swift:9 states it outright — "Everything here deletes DOWNLOADED media only — there is deliberately no catalog or collections involvement to test, because the API never touches them." Either ship a catalog/artwork/lyrics cache-clear action in Settings ▸ Storage, or leave this row saying only where the cache lives. Do not name a control that does not exist. --> |

**One important exception.** Microphone recordings and recorded mixes stay on your device *unless you ask PocketDJ to separate one into stems.* Stem separation runs in the cloud, so choosing it uploads that recording. PocketDJ will tell you before it does, and will not do it silently.
<!-- #TOUPDATE: must be true — the Producer ▸ Demuxer "create stems" action on a local source (StudioDemuxView.swift:986 → RipsStore.stemifyCustom, RipsStore.swift:1097) currently uploads with NO in-UI notice. Accepted id prefixes include smp_ (Studio mic take) and tk_ (recorded mix take). Add an explicit pre-upload consent prompt naming what is uploaded and where it goes, OR gate the smp_/tk_ prefixes out of /stemify-custom for the public build. Until one of those ships, this paragraph is false. -->

---

## 4. What goes to PocketDJ cloud services

### 4.1 Audio you ask us to process

When you upload a file, import audio you already have, or digitize one of your own analog sources, that audio is sent to PocketDJ cloud services. We use it to:

- convert it to a streamable format and store it so you can play it offline and load it into the Mix decks;
- separate it into stems (vocals, drums, bass, other) when you ask;
- analyze it for tempo, musical key, Camelot key, beat grid, and waveform, so beat-matching and key-matching work;
- transcribe lyrics when you ask ([§8](#8-two-transcription-engines-and-why-the-difference-matters)).

Audio you send us is received by an **intake server we operate**, which stores it and hands the work off to our worker machines and to managed AWS services. Stem separation and analysis run there. All of it is our own infrastructure in the United States. **We do not send your audio to any outside company for AI processing** — the transcription and separation models run on machines we operate.
<!-- #TOUPDATE: two problems, one disclosure and one architectural.
     DISCLOSURE (now partly fixed above): the FIRST hop for every upload is the intake server, and the original text skipped it entirely, implying audio landed directly in managed AWS. Keep this generic. DO NOT name the machine, its hostname, its tailnet, or its operator in a published document.
     ARCHITECTURE (still open, and the real fix): that intake server is internet-exposed by DEFAULT (rip-server.mjs:59, `public: process.env.RIP_PUBLIC !== '0'`), its auth is OFF by default (`:49` `token: process.env.RIP_TOKEN || ''`; `:1905` `if (!CFG.token) return true`), and per-IP rate limiting is OFF by default (`:62`). "Our own infrastructure" is doing a lot of work in that sentence while the front door is unlocked. The correct remedy is to SHIP THE ARCHITECTURE DESCRIBED — armed auth, rate limiting on, intake not anonymously writable — not to add prose describing the current state. legal-posture-conformance.md §7(a) MUST-0 item 0a rates arming both live services "the largest live exposure and the smallest fix in the document", at 30 minutes. -->
<!-- #TOUPDATE: FEATURE-VIABILITY DEPENDENCY, upstream of every privacy question here. NOTICE.md §9.1 rates the Demucs pretrained weights ⛔ BLOCKING — licensed for scientific purposes only — and §9.4 flags the lyrics model as having "no licence from anyone." If those cannot ship, then §4.1's stem/lyrics bullets, §8, Appendix A rows 2-3, and Appendix B's *User Content ▸ Audio Data* mapping all describe processing that will never occur, and describing it anyway overstates collection. Resolve the licence question BEFORE resolving the consent markers below it — consent for processing that cannot legally run is a moot point. -->

**You must hold the rights to any audio you upload, import, or digitize from your own sources.** That is a condition of using the service, not a privacy matter, but it is worth saying here too: we process what you send us on the basis that you are entitled to send it.

### 4.2 Where your audio is stored, and who can reach it

Your audio, your stems, your analysis files, and your transcripts are stored in **your own private storage namespace**. They are served to you over an authenticated connection, and PocketDJ has no feature for distributing them to other people.
<!-- #TOUPDATE: must be true — this is the LARGEST gap between this document and shipped code. Today every S3 key is a pure function of a content id (rips/<songId>.mp3, rips/stems/<songId>/<stem>.mp3, rips/analysis/<songId>.json, rips/lyrics/<songId>.json) in ONE bucket under ONE shared manifest, publicly readable with no signature; the app hardcodes the raw unsigned host and sends no Authorization header; and rip-server.mjs:543 redirects a second user to the first user's object. Required before this paragraph is true: (1) per-user storage keys (user id IN the key, not an entitlement table over a shared master); (2) per-user authentication — a server-derived user id from a verified Sign in with Apple sub claim, never client-supplied; (3) no cross-user dedup for audio OR derivatives (the stem worker's song-id dedup at stem-worker.mjs:87-100,166-178 must become namespace-scoped); (4) removal of the public-read bucket policy plus short-TTL signed URLs; (5) public-access block ON. Tracked as LATER-28/29/30 in legal-posture-conformance.md. -->

### 4.3 The public catalog is metadata only

PocketDJ publishes a browsable catalog so people can see collections, tracklists, and setlists for inspiration. **The catalog documents contain metadata only** — titles, artists, albums, genres, tempo, key, beat grids, waveform images, cover art, and lyric text. They contain no audio, and they are not a way to obtain audio. Playback always resolves through your own subscription or your own copies.
<!-- #TOUPDATE: "not a way to obtain audio" is VERIFIED FALSE TODAY, and this is the second-most quotable sentence in the document. Fetched anonymously, with no credentials: `rips/manifest.json` returns HTTP 200 and enumerates every songId→key; `current-index.json` returns 200 carrying the same ids; the bucket policy `PublicReadRips` grants `s3:GetObject` on `rips/*` to `Principal:"*"`; and the S3 public-access block is entirely off (all four flags false). A public catalog naming every song, plus a publicly fetchable manifest mapping song → key, plus publicly readable objects at those keys, IS a way to obtain audio — the catalog document not containing the bytes is beside the point when it hands over the index.
     The true statement is narrower: the catalog DOCUMENTS carry no audio locations. The INFRASTRUCTURE does. Before this sentence may be published: the `rips/*` prefix must be made private, the manifest must stop being publicly fetchable, and delivery must move to short-TTL signed URLs (the same work as §4.2 and §16).
     Cross-doc: TERMS §6.6 makes the identical claim and DOES carry this marker with this exact fix. PRIVACY dropped it; the two documents cannot ship disagreeing about a fact that is checkable with one curl. -->

### 4.4 Search

- **Discover search** sends the words you type to PocketDJ cloud services, which forwards them to Apple's public iTunes Search API to find a match. No user identifier is attached. We do not keep the search terms.
  <!-- #TOUPDATE: must be true — search terms currently land in the backend's stdout log, which has no rotation and no retention policy. "We do not keep the search terms" requires either excluding them from the log or a bounded, implemented log retention (see §11). -->
- **Online catalog search** is off by default and opt-in. When on, your query goes to our managed search service. We do not associate queries with your profile.
  <!-- #TOUPDATE: must be true — online search today requires you to paste an AWS access key id and secret into Settings, and those are stored in plaintext UserDefaults (SettingsStore.swift:82-83,174) while a working Keychain helper already exists in the same codebase (StreamingTokenStore.swift). Target is server-mediated search with per-user auth and no client-held cloud credentials. Until then, this section understates what the user is being asked to do. -->

### 4.5 Server logs

Our servers keep operational logs — request timing, errors, song ids, and for the jukebox, the text of guest requests. IP addresses reaching the jukebox are used for rate limiting. See [§11](#11-how-long-we-keep-things) for retention.

---

## 5. What goes to Apple

### 5.1 iCloud sync (CloudKit)

If you are signed in to iCloud and sync is on, PocketDJ syncs these documents to **your own private iCloud database**:

your profile · collections (pockets, playlists, setlists) · your edits · favorites · play stats · play history · mix sessions · your current playback session · mix deck state · Discover adds · imported songs

Each synced record also carries **the name of the device that pushed it**, so the app can show you which device synced last. Your device name may identify you — many are of the form "*<your first name>*'s iPhone".

This data sits in your Apple Account's private database, governed by [Apple's privacy policy](https://www.apple.com/legal/privacy/). **We cannot read it.** PocketDJ uses only CloudKit's private database — never a public or shared database, and never CloudKit sharing. Turn sync off in Settings ▸ Profile.

*A note on how we classify this:* because a CloudKit private database is not readable by us, we take the position that it is **not "collected" by the developer** for App Store nutrition-label purposes. We are stating that position openly rather than leaving it implicit, so you can disagree with it if you want to.

### 5.2 Apple Music

If you connect an Apple Music subscription, PocketDJ:

- **plays** full-length tracks through MusicKit;
- **reads** your library's playlist list, so collections you converted from an Apple Music playlist stay in step with their source;
- **writes to your library only when you ask it to** — adding a song or album you chose to add, or adding a song to one of your playlists.

**No audio is copied, captured, recorded, or downloaded out of Apple Music by PocketDJ.**
<!-- #TOUPDATE: same gate as §2 — ALL FIVE conditions in the §2 marker (shipped-client removal, server-side rejection at acceptRip, fail-closed default, backend AND client, and deletion of previously captured objects) must hold before this sentence ships. It is restated here rather than cross-referenced only, because §5.2 is where a reviewer looking for the Apple Music answer will land. -->

**Favorites.** Your ♥ in PocketDJ is local and syncs to your private iCloud database. Two-way sync with your Apple Music account is currently restricted to the developer's own account and is off for everyone else. If that ever opens up, you should know before you turn it on: **adding a song to Apple Music's Favorite Songs cannot be undone by any app** — Apple provides no removal API for it. The "loved" rating is reversible; the Favorite Songs entry is not. We will not enable this for anyone without an explicit, informed opt-in.
<!-- #TOUPDATE: must be true — the owner gate (FavoritesSyncService.swift:98, allowlist at Config.swift:64-68) is a shipped constant, not a structural guarantee. If two-way favorites sync is opened to users, an explicit consent screen naming the irreversibility of POST /v1/me/favorites must ship with it. Also: the doc comment above Config.swift:64-68 still says "Ships EMPTY on purpose" and is now stale. -->

### 5.3 Song recognition (ShazamKit)

When you use song recognition, your device listens through the microphone and computes an **acoustic signature** — a compact mathematical fingerprint. **The signature is what gets sent to Apple's Shazam service. Your raw microphone audio is not transmitted**, and no PocketDJ server is involved in the recognition itself. Governed by Apple's privacy policy. We keep the match result (title, artist, catalog id) locally.

**Acting on a match is a separate step, and it is not local.** If you choose to add a recognized song and have PocketDJ process it, the title, artist, and Apple Music catalog id are sent to PocketDJ cloud services to create that item. Recognition is private; acting on it is an upload request like any other in [§4.1](#41-audio-you-ask-us-to-process).
<!-- #TOUPDATE: the original sentence said "no PocketDJ server is involved at any point ... so you can act on it" — and the act-on-it clause is precisely the path that involves a server. The recognizer add flow ships title/artist/appleMusicId to the rip server as an ad-hoc rip (`amrec_` ids; rip-server.mjs:533-541 `adhocDesc`). Two things must happen: (a) keep this disclosure accurate as the flow changes; (b) NOTE THE OVERLAP WITH THE §2 CAPTURE GATE — this is an Apple-Music-sourced id reaching the capture path, so whatever fence rejects Apple Music ids at acceptRip must cover `amrec_` ad-hoc ids too, or the fence has a hole shaped exactly like this feature. -->

---

## 6. Other services in the path

| Service | Role | What reaches it |
|---|---|---|
| **Apple** — MusicKit, ShazamKit, CloudKit, Speech | Platform frameworks | See [§5](#5-what-goes-to-apple) |
| **Amazon Web Services** (United States) | Our storage, queues, worker machines, CDN, and search. AWS is our processor; the account is ours. | Audio you send us, derived stems/analysis/transcripts, catalog documents, jukebox session state |
| **Apple's iTunes Search API** | Looks up a song when you search in Discover | The words you typed |
| **Apple's App Store / TestFlight** | Distribution. Crash reports you choose to share go to Apple. | Governed by Apple's privacy policy — we receive no crash data because we ship no crash SDK |

That is the complete list of outside parties in the app's request path. **PocketDJ includes no third-party analytics, advertising, attribution, A/B-testing, or crash-reporting SDKs.** The only third-party code in the binary is ZIPFoundation (MIT), which has no network access.

Metadata in the public catalog was assembled with help from public sources including Discogs, MusicBrainz, and Wikipedia. Those are developer-side tools that shaped the published catalog; the app does not call them at runtime, and they receive nothing from you.

---

## 7. Microphone

PocketDJ asks for microphone access for exactly two things:

1. **Recording samples and takes in Studio.** These stay on your device ([§3](#3-what-stays-on-your-device)) unless you choose to separate one into stems, which uploads that recording.
2. **Song recognition.** ShazamKit takes over the microphone, derives a signature, and sends only the signature ([§5.3](#53-song-recognition-shazamkit)).

PocketDJ does not listen in the background, does not record without an explicit action from you, and has no ambient-listening feature.

---

## 8. Two transcription engines, and why the difference matters

PocketDJ has one karaoke feature and two engines behind it. They have very different privacy properties and we are not going to blur them.

**On-device transcription (Apple Speech).** When PocketDJ transcribes audio for the synced word-by-word overlay, it forces on-device recognition and **refuses to run at all if the device cannot do it locally**. There is no server fallback. The audio never leaves your device and Apple never receives it. This is a real, structural guarantee — not a policy promise — and it is the strongest privacy property in the app.

**Cloud lyrics transcription.** Separately, you can ask PocketDJ to generate lyrics from a track in the cloud. This **uploads the audio** (specifically the isolated vocal stem) to PocketDJ cloud services, where a machine-learning transcription model produces timed lyrics. The model runs on our own machines; no outside AI company receives your audio.

**This is a distinct, opt-in action and PocketDJ will tell you what it does before it runs.** If you want lyrics without uploading anything, use the on-device transcription instead.
<!-- #TOUPDATE: must be true — the cloud lyrics feature is currently hidden behind DemuxFeatures.lyricsEnabled while the server endpoint (POST /lyricsify) is live and user-tier. Before the feature is unhidden: (a) an explicit consent prompt naming the upload, per App Review 5.1.2(i), which specifically covers audio leaving the device for an AI process; (b) the nutrition label's User Content ▸ Audio Data entry must already cover it (it does). If the feature ships hidden/disabled in v1.0, say so here instead of describing it as available. -->
<!-- #TOUPDATE: VIABILITY GATE, upstream of the consent gate above. NOTICE.md §9.4 records that the lyrics model carries "no licence from anyone", and §9.1 rates the Demucs weights ⛔ BLOCKING (scientific-purposes-only) — and cloud lyrics runs ON the isolated vocal stem, so it inherits the Demucs blocker as a hard dependency. If either cannot be cleared, this whole subsection describes processing that will never run and must be DELETED, not marked. Do not resolve the consent marker above before this one. -->

---

## 9. Jukebox hosting and the guest request line

Jukebox lets you run a request line at an event you are hosting. Guests scan a code, see what is playing, and send requests. **It is built for private events you host.** If you play music for an audience, any performance licensing your venue or event requires is your responsibility — the app does not provide it.

### 9.1 If you are the host

While a session is live, PocketDJ publishes to the guest page: **your DJ display name**, the current track, your upcoming queue, recently played tracks, and the request list with your accept/deny decisions. Your play activity is otherwise private — this is the one time it goes anywhere but your own iCloud database.

Sessions are **token-gated by default**, capped to a limited number of listeners, and expire automatically. Sessions are not listed, enumerable, or search-indexable.
<!-- #TOUPDATE: must be true — ALL THREE claims in this paragraph are forward-looking. Today: (1) the token gate is CREATE-ONLY and empty by default (jukebox-server.mjs:35 — JUKEBOX_TOKEN || '', tokenOk() returns true when unset); guest endpoints have NO token at all — POST /:id/request is explicitly public and state.json is fetched anonymously from CDN. (2) There is NO listener cap anywhere in the code. (3) Expiry is real but partial — normal sessions auto-end at 24h and delete at 7d, but sessions created with timeless:true never expire, never delete, and retain guest IPs indefinitely. The token gate must ship ARMED AND ENABLED BY DEFAULT, and the cap and a bounded expiry for every session including timeless must ship with it. Until then this paragraph must not be published. Tracking: legal-posture-conformance.md §7(a) MUST-0 item 0a (arm `JUKEBOX_TOKEN` — "an uncomment and a restart", 30 min) and Pillar 3 at §3, which records that the installed `com.pocketdj.jukeboxserver.plist` sets no `JUKEBOX_TOKEN` at all. -->

### 9.2 If you are a guest — what we collect from you

You do not need an account, and we do not ask for your name, email, or phone number.

**What we receive when you send a request:**

- the song title and artist you type;
- a random identifier your browser generates and stores locally, so we can pace requests fairly;
- your IP address, as with any web request — used to operate the service and to stop abuse.

**What the host sees:** the text of your request. Not your IP address.

**What other guests see:** the request text on the queue. Nothing that identifies you.

**How long:** see [§11](#11-how-long-we-keep-things).

**Lawful basis (EU/UK):** legitimate interests — running a request line you chose to use, and keeping it secure and abuse-free. You can object; see [§12](#12-your-rights-and-your-controls).

The guest page carries a short version of this notice at the point you type your request.
<!-- #TOUPDATE: must be true — the guest page (scripts/jukebox-site/template.html) currently has NO privacy notice at all. GDPR Art. 13 requires notice at the point of collection, and guests are arbitrary members of the public — this is the app's clearest collection of personal data from third parties. Add a one-line notice plus a link to this policy on the request form. Verified: `scripts/jukebox-site/template.html` contains no "privacy" or "policy" string, and no age screen.
     CROSS-DOC CONFLICT — RESOLVE IN TERMS, NOT HERE: TERMS §7.4 asserts as PRESENT FACT that "the request form links to it [the Privacy Policy]", with no marker. That is false and PRIVACY is the correct document. Fix TERMS §7.4; do not weaken this marker to match it. -->

### 9.3 Listen-along

A host can optionally let guests hear the current track on their own phones. It is **off by default** and only the host can turn it on. When it is on, guests stream the host's own copy of the track for the duration of the session. **This is for people physically present at the event you are hosting.** The Terms of Service prohibit using PocketDJ to broadcast, webcast, simulcast, or otherwise transmit music to people who are not present at your event; listen-along is not a broadcast service, and the audience limits in [§9.1](#91-if-you-are-the-host) apply to it.
<!-- #TOUPDATE: must be true — with no guest token and no listener cap, listen-along is currently an open unauthenticated audio stream to anyone holding the URL, from anywhere on earth. "The audience limits apply" is only true once the §9.1 controls exist, and the physical-presence limitation is at present a rule with no mechanism behind it.
     CONTRADICTION RESOLVED HERE: TERMS §7.3 forbids transmitting music to people not present at your event, while this section previously advertised listen-along with NO presence requirement — the Terms prohibited the use the Privacy Policy described. The presence limitation is now stated. It still needs an ENFORCEMENT story (guest token + cap at minimum), or the two documents are consistent only on paper.
     If the controls will not land for v1.0: gate the whole Jukebox tab out, or delete this subsection and the feature. Tracking: legal-posture-conformance.md §8 Decision B ("Does the jukebox stream audio to remote guests, or is it request-only?") — undecided — and Pillar 3, "Private performance only". -->

---

## 10. What we do not do

- We do not sell your personal data.
- We do not share it with data brokers or advertisers.
- We do not track you across other companies' apps and websites. The app declares no tracking and no tracking domains, and requests no tracking permission.
  <!-- #TOUPDATE: the behavioral half is true — there is no tracking SDK in the binary. The DECLARATION half is not: NOTHING IS DECLARED AT ALL. There is no `.xcprivacy` in either target (`find apple -name "*.xcprivacy" -not -path "*/build*"` → nothing; the only hits are ZIPFoundation's own manifest inside build output) and no `NSPrivacyTracking` key anywhere in the repo. "Declares no tracking" asserts the existence of a file that does not exist. The manifest is NOT optional here — the app uses UserDefaults (`pdj.settings.v1`) and file timestamps, both API-declaration categories. Ship the manifests (Appendix B) or drop the clause. Appendix B repeats this claim and is at least covered by its own block marker; this one was bare, in the most quotable list in the document. -->
- We do not run ads.
- We do not collect your location, contacts, health, financial, or browsing data.
- We do not auto-upload diagnostics or crash reports to ourselves.
- We do not read your iCloud private database.
- We do not copy audio out of Apple Music.
  <!-- #TOUPDATE: THE SAME GATE AS §2 AND §5.2, AND THE MOST IMPORTANT MARKER IN THIS DOCUMENT. The identical claim carries a marker in both of those sections; here — in "What we do not do", the list a reviewer or journalist will quote — it was BARE. All five §2 conditions apply. Confirmed still open: RipsStore.swift discoverAdd → discoverAddRip, whose own doc comment at RipsStore.swift:798-800 carries an in-code #TOUPDATE conceding the server "does not yet restrict itself to user-uploaded media." A flat unqualified denial in a "what we do not do" list, contradicted by a concession in our own source, is the single highest-exposure sentence in the draft. -->
- We do not sell or share your personal information as those terms are defined by California law. See [§12.3](#123-california-and-other-us-state-privacy-rights).

---

## 11. How long we keep things

| Data | Retention |
|---|---|
| Audio you sent us, and its stems, analysis, and transcripts | Until you delete it. See [§13](#13-deleting-your-data-and-your-account). Deleted from our storage within {{RETENTION_DELETION_SLA}} of your request. <!-- #TOUPDATE: must be true — there is no lifecycle rule, no TTL, and no server-side delete path today. The in-app Storage manager deletes only the DEVICE copy; the stored object survives. Implement the delete path and pick a real SLA. --> |
| Jukebox guest requests, guest identifiers, and IP addresses | Deleted {{RETENTION_JUKEBOX}} after the session ends. <!-- #TOUPDATE: must be true for EVERY session. Today: 7 days for normal sessions (real, implemented) but INDEFINITE for sessions created timeless — the sweeper skips them entirely, so guest IPs persist forever. Either bound timeless or remove it. --> |
| Jukebox published session state (now playing, queue, played, requests) | Deleted with the session, on the same schedule <!-- #TOUPDATE: FALSE FOR TIMELESS SESSIONS, exactly as the row above it. jukebox-server.mjs:357-358 states "Timeless sessions are never auto-ended or deleted", enforced at :362 by `if (!s.timeless)`, and `expiryOf` at :121 returns null for them. "On the same schedule" is true only if the schedule exists for every session — for timeless ones there is no schedule. The row above carries this marker; this row failed identically and had none. Either bound timeless sessions or remove the option. --> |
| **Your profile identifier** (the durable UUID minted at first run) and the CloudKit records keyed to it | <!-- #TOUPDATE: MISSING ENTIRELY from this table until now, and it is the closest thing PocketDJ has to an account identifier — ProfileStore.swift:47 mints a durable UUID, persists it to `pocketdj-profile.json`, syncs it, and publishes the display name to a public guest page. State a real period. Note the CloudKit half sits in the user's own private database (we cannot delete it for them, only the app can, from the device), while the identifier's appearance in OUR jukebox session records and logs is ours to bound. Do not write a number until the Delete Profile flow in §13 exists to honor it. --> |
| Apple Music audio captured before the capture paths were closed | <!-- #TOUPDATE: THIS ROW MUST NOT SHIP EMPTY, AND IT MUST NOT SHIP AT ALL IF THE ANSWER IS "WE STILL HAVE IT". A retention table that omits material the service should never have held is incomplete on its own terms. TERMS §6.7's marker requires that "previously captured objects must be deleted" as a condition of the capture claim; this document's §2/§5.2/§10 markers now carry the same condition. Before publishing, EITHER: (a) the purge has run, the objects are gone from the `rips/*` prefix, and this row is deleted as moot — the honest outcome; or (b) the purge is pending, in which case this row states what is held, for how long, and when it will be destroyed. What may not happen is the current state: §2, §5.2, and §10 flatly denying the capture while §11 is silent about the results of it. Sequence with legal-posture-conformance.md §4, "Preservation: do not delete before you snapshot" — snapshot for the litigation-hold question FIRST, then purge. --> |
| Server logs | {{RETENTION_LOGS}} <!-- #TOUPDATE: must be true — logs have no rotation, no truncation, and no retention configuration of any kind. Pick a number AND ship the log rotation that enforces it. A stated retention period with no implementation is a false statement, not an aspiration. --> |
| Catalog metadata you contributed | For as long as the catalog entry exists |
| Data in your private iCloud database | Controlled by you, in your Apple Account, until you delete the app's iCloud data or turn sync off |
| Everything on your device | Until you delete it, or until the storage manager's least-recently-played cleanup removes it if you set a storage cap |

---

## 12. Your rights and your controls

**Controls built into the app**, wherever you live:

- **Settings ▸ Profile** — turn iCloud sync off, or pull/push on demand.
- **Settings ▸ Storage** — delete downloaded audio and recordings by artist, by collection, or all of it; set a storage cap.
- **Export** — take your collections, playlists, and library out as a file at any time. That is your data portability route and it does not require asking us.
- **Microphone and Apple Music permissions** — revocable at any time in iOS/macOS Settings.
- **Online search** — off unless you turn it on.

**Legal rights.** Depending on where you live — including under the EU GDPR, the UK GDPR, and US state privacy laws — you may have the right to access, correct, delete, export, or restrict our processing of your personal data, to object to processing based on legitimate interests, and to lodge a complaint with your data protection authority. Most of your data is on your device or in your own iCloud account, so you already control it directly. For anything we hold, write to {{CONTACT_EMAIL}} and we will respond within {{RESPONSE_SLA}}.
<!-- #TOUPDATE: "For anything we hold, write to us" promises a rights pipeline that cannot currently be executed. Stored objects are SONG-KEYED AND SHARED (`rips/<songId>.mp3`), and the intake server has no user identity at all — one shared bearer token, empty by default (rip-server.mjs:49 `token: process.env.RIP_TOKEN || ''`; :1905 `if (!CFG.token) return true`). There is therefore no way to determine which objects are "yours", and deleting a song-keyed object deletes it for every other user holding the same song. An access or deletion request cannot be honored, and a portability request cannot be scoped. This is unblocked only by §4.2's per-user keys and per-user auth. Sibling DMCA §6's marker puts the same architecture problem harder: "architecturally impossible to implement as written." -->

### 12.1 The categories of personal data we process

GDPR Art. 13/14 wants these as a list, not spread across a flow table. In the categories form:

- **Identifiers** — your profile identifier (a random UUID), your DJ display name, and for jukebox guests an IP address and a random browser identifier.
- **User content** — audio you upload, import, or digitize; stems, analysis, and transcripts derived from it; your collections, playlists, setlists, and edits; jukebox request text.
- **Usage data** — play history and play stats, and the now-playing/queue state published while a jukebox session is live.
- **Search data** — Discover search terms and, if you turn it on, online catalog queries.
- **Device data** — the device name attached to each synced record, and operational request metadata in server logs.

We process no special-category data (Art. 9), no location, no contacts, no health or financial data, and no browsing history.

**Whether you have to provide it (Art. 13(2)(e)).** None of this is a statutory requirement. Providing audio, a display name, or a jukebox request is a **contractual** necessity only in the narrow sense that the specific feature cannot function without it — if you do not upload audio, the cloud features simply do not run, and the rest of the app works. There is no consequence to declining beyond the loss of that feature.

**Automated decision-making (Art. 13(2)(f)).** There is none. PocketDJ does no profiling and makes no automated decision producing legal or similarly significant effects about you. Tempo, key, and beat-grid analysis are measurements of an audio file, not evaluations of a person.

### 12.2 Our lawful bases (EU/UK)

| Processing | Basis |
|---|---|
| Running the app, syncing your library, processing audio you send us | Performance of a contract — you asked for the feature |
| Cloud transcription, stem separation of your own recordings, two-way favorites sync | Consent — separately asked for, and withdrawable <!-- #TOUPDATE: THIS ROW IS CONTRADICTED BY THIS DOCUMENT'S OWN MARKERS. §3's marker records that Stemify on a local recording "currently uploads with NO in-UI notice"; §8's records that the cloud-lyrics consent prompt has not been built. Asserting an Art. 6(1)(a) basis of consent where NO consent is collected is the most exposed sentence in the document — an unlawful-processing finding, not merely a drafting one, because consent that was never requested cannot be relied on and there is no fallback basis pleaded. Either the consent prompts ship (per App Review 5.1.2(i), which independently requires disclosure and consent for audio leaving the device to an AI process), or this row must name the basis actually relied on. Do not resolve this marker by changing the row to "legitimate interests" — for uploading a user's own microphone recordings to a server, that would not survive a balancing test. --> |
| Jukebox guest requests, rate limiting, abuse prevention, security logging | Legitimate interests <!-- #TOUPDATE: the basis is plausible but the ASSESSMENT is not documented. Art. 6(1)(f) requires a legitimate-interests assessment (purpose / necessity / balancing) to be recorded and retained, and the guest endpoint is reachable by anyone on the internet, including children, before any notice is shown (§9.2's marker). Appendix D Q2 currently ASKS whether an LIA is needed rather than resolving it. Write the LIA, retain it, and reference it here. --> |
| Meeting legal obligations, including responding to valid copyright notices | Legal obligation <!-- #TOUPDATE: listed as a functioning basis while the mechanism does not exist. Responding to copyright notices under 17 U.S.C. §512 requires, as a THRESHOLD condition on every safe harbor, a repeat-infringer termination policy that is reasonably implemented (§512(i)) — and there is nothing to terminate: §13 of this document says there are no accounts, §4.2's marker says there is no per-user attribution, and DMCA §6's own marker concedes the policy is "architecturally impossible" as written. A lawful basis of "legal obligation" is fine in itself, but it must not be read as a claim that the copyright-notice pipeline works. Resolve with DMCA §6 and TERMS §3 together — all three documents describe the same missing identity layer. --> |

### 12.3 California and other US state privacy rights

<!-- #TOUPDATE: THIS ENTIRE SUBSECTION IS A SKELETON AND MUST BE COMPLETED, NOT MERELY MARKED. The previous draft gestured at "US state privacy laws" in one clause and stopped, which is not a CCPA/CPRA disclosure. Required and still missing: (1) NOTICE AT COLLECTION — given at or before the point of collection, which for the jukebox guest page means on the page itself (§9.2's marker); (2) the categories of personal information COLLECTED and, separately, DISCLOSED for a business purpose in the preceding 12 months, in CPRA's categories form — §12.1 above is the raw material but is not yet cast in the statutory categories; (3) a "Do Not Sell or Share My Personal Information" disclosure IN THAT FORM — §10's flat "we do not sell" is not the required disclosure even though it is true; (4) the right to LIMIT USE AND DISCLOSURE OF SENSITIVE PERSONAL INFORMATION, or a statement that none is collected; (5) the NON-DISCRIMINATION statement; (6) how to submit a request and how we verify it — noting that verification is not currently possible for server-stored objects for the same reason deletion is not (§4.2).
     DEPENDENCY, AND IT CUTS THE OTHER WAY FOR ONCE: if Decision F is taken (restrict initial App Store availability to the United States — legal-posture-conformance.md §8.F, recommended but never decided), then CCPA/CPRA becomes the PRIMARY regime rather than an afterthought, this subsection becomes the most load-bearing part of §12, and §15's transfer-mechanism problem largely evaporates. This document notes Decision F twice and resolves it nowhere. Resolve it before drafting this subsection, because the answer determines how much of §12 and §15 survives. -->

If you are a California resident, you have rights to know, delete, correct, and opt out of sale or sharing of your personal information. **We do not sell or share personal information as those terms are defined by the CCPA/CPRA, and we do not process sensitive personal information for purposes requiring a right to limit.** We will not discriminate against you for exercising any of these rights. To make a request, write to {{CONTACT_EMAIL}}.

### 12.4 If there is a data breach

If personal data we hold is breached in a way that is likely to result in a risk to your rights and freedoms, we will notify the relevant supervisory authority without undue delay and, where the risk is high, notify you directly.
<!-- #TOUPDATE: no breach-notification process exists — no detection, no severity assessment, no notification templates, no supervisory-authority contact identified, and no log retention adequate to reconstruct what was accessed (§11 says logs have no rotation and no retention configuration at all, which also means no reliable forensic record). GDPR Art. 33 gives 72 hours to notify the authority and Art. 34 governs notifying individuals; every US state breach statute imposes its own clock. This is operationally mandatory and was entirely absent from the draft. Write the runbook before publishing the promise. Note the acute version of this: with the intake server internet-exposed and auth off by default (§4.1's marker), the probability of needing this is not theoretical. -->

### 12.5 The other documents

This policy is one of three. See also the [Terms of Service]({{TERMS_URL}}) and the [Copyright / DMCA Policy]({{DMCA_URL}}).

---

## 13. Deleting your data and your account

PocketDJ does not require you to create an account with us. It creates a **profile** — a randomly generated identifier and a display name you choose — so your library can sync across your devices and so guests know whose jukebox they are in.
<!-- #TOUPDATE: DIRECT CONTRADICTION WITH TERMS, AND THE TWO DOCUMENTS CURRENTLY DESCRIBE DIFFERENT PRODUCTS. TERMS §3.1 says "Some features require an account" and makes you responsible for "keeping your sign-in credentials secure"; §3.3 says "Do not share your credentials"; §3.4 (itself unmarked) says "You may close your account at any time." This document says there is no account and no login — which matches the code, since there are no credentials anywhere in the app to secure or share.
     PICK ONE ANSWER AND MAKE ALL THREE DOCUMENTS SAY IT. The choice is not cosmetic, because it cascades: if the profile IS an account, Guideline 5.1.1(v) in-app deletion is triggered (the marker below) and DMCA §6 gets something to terminate for repeat infringement; if it is NOT, TERMS §3 must be rewritten and DMCA §6's termination policy has no subject. Note that Appendix D Q1 of this document still ASKS whether the profile is account creation while TERMS §3 already assumes it is — the open question and the confident answer are shipping in the same release. Resolve Q1 first. -->
<!-- #TOUPDATE: note the DIRECTION of the sign-in dependency, which is easy to get backwards. §4.2 requires a server-derived user id from a verified Sign in with Apple claim in order to have per-user storage at all. If that ships, PocketDJ WILL have real accounts with real credentials, and this paragraph's "does not require you to create an account" becomes false — as does the TERMS §3 language becoming true. Whichever way this lands, §13, TERMS §3, DMCA §6, and Appendix D Q1 must be updated in the SAME change. -->

**To delete your profile and everything associated with it:** Settings ▸ Profile ▸ Delete Profile. This deletes, in one action: your profile record and display name, your synced documents in your private iCloud database, any audio and derived files stored for you by PocketDJ cloud services, and any jukebox sessions you created. It cannot be undone.
<!-- #TOUPDATE: must be true — THIS FLOW DOES NOT EXIST. App Review Guideline 5.1.1(v) requires in-app account deletion for any app supporting account creation, and PocketDJ's profile (ProfileStore.swift:47, a durable UUID + display name, synced, and published to a public guest page) is very likely to be read as account creation — treat the trigger as fired rather than betting the submission on the argument that a profile without a password is not an account. Confirmed absent: `grep -rn "deleteProfile|Delete Profile|deleteAccount|Delete Account" apple --include="*.swift"` returns NOTHING. This is the highest-probability rejection in the document. Ship a Delete Profile action that reaches ALL FOUR of: the CloudKit profile/session records, the server-side stored audio and derivatives, jukebox sessions, and local files. Note the server-side half is impossible until per-user storage keys and per-user auth exist (§4.2) — there is currently no way to identify which stored objects belong to which user. This is the dependency that makes §4.2 blocking for 5.1.1(v), not just for the copyright posture. -->

**If you delete the app** without deleting your profile, your device copies go with it. Your private iCloud data stays in your Apple Account until you remove it (iOS Settings ▸ your name ▸ iCloud ▸ Manage Storage), and anything stored for you by PocketDJ cloud services stays until you ask us to delete it.
<!-- #TOUPDATE: "stays until you ask us to delete it" implies a deletion path that can be executed on request. There is none — see the marker below, which applies to this sentence too. -->

**Either way, you can email {{CONTACT_EMAIL}} and ask us to delete everything we hold.** We will.
<!-- #TOUPDATE: THE BOLDEST PROMISE IN THE DOCUMENT AND CURRENTLY THE LEAST KEEPABLE. It cannot be honored today, for a structural reason rather than a missing-feature reason: stored objects are SONG-KEYED AND SHARED (`rips/<songId>.mp3`, `rips/stems/<songId>/…`, `rips/analysis/<songId>.json`), and the intake server has NO USER IDENTITY — one shared bearer token, empty by default (rip-server.mjs:49; :1905 `if (!CFG.token) return true`). Two consequences, and the second is worse than the first: (1) we cannot determine which objects are "yours", so we cannot scope the deletion; (2) deleting a song-keyed object DELETES IT FOR EVERY OTHER USER holding that song, so honoring one person's request destroys other people's data.
     "We will" must not ship as an unconditional promise before per-user keys and per-user auth exist (§4.2). The §13 marker above covers only the in-app Delete Profile flow; these sentences are a separate, broader promise made to anyone with an email client, including people who never installed the app. Until §4.2 lands, either scope this to what CAN be deleted and say plainly what cannot, or do not make the promise. Sibling DMCA §6's marker states the same architecture problem harder: "architecturally impossible to implement as written." -->
<!-- #TOUPDATE: this section is also silent on PURGING ALREADY-CAPTURED APPLE MUSIC AUDIO — see the §11 row. Deletion-on-request and the capture purge are different obligations: the first is owed to a user who asks, the second is owed regardless of whether anyone asks. -->

---

## 14. Children

**PocketDJ is not directed to children under 13**, and we do not knowingly collect personal information from them. The app is not in the App Store Kids Category, does not carry a kids age band, and has never been designated as made for kids.

The App Store age rating is **{{AGE_RATING}}**, computed by Apple from our content questionnaire. The rating reflects that recorded music and album artwork can contain mature themes, references to alcohol, tobacco or drugs, and profanity — not anything in the app itself.

If you believe a child under 13 has provided us personal information, email {{CONTACT_EMAIL}} and we will delete it. In practice the only way a child's data could reach us is by sending a jukebox request as a guest ([§9.2](#92-if-you-are-a-guest--what-we-collect-from-you)), which collects no identifying details beyond an IP address and a random browser identifier.

If you are in the EU or UK, the age of consent for information-society services is 13 to 16 depending on your country. We do not offer PocketDJ to users below the applicable age in their country.
<!-- #TOUPDATE: stated in the present tense as an OPERATIVE CONTROL, and there is no control. No age gate exists anywhere: `grep -rniE "ageGate|birthdate|dateOfBirth"` across the Swift target returns NOTHING. Nobody is asked their age at any point, so "we do not offer PocketDJ to users below the applicable age" describes an outcome we neither verify nor enforce. Two honest options: (a) ship an age screen and keep the sentence; or (b) rewrite it as what it actually is — a statement that the app is not DIRECTED to children under 13 and that we do not knowingly collect from them, which the paragraphs above already say correctly. Option (b) is consistent with the rest of §14 and requires no code.
     Do not paper over the ADJACENT gap while fixing this one: the guest page collects an IP address and a persistent browser identifier from arbitrary members of the public — possibly children — BEFORE any notice is shown and with no age screen (§9.2's marker; `scripts/jukebox-site/template.html` has neither). This paragraph identifies the jukebox as the sole child-data vector and then does not mitigate it. -->

---

## 15. Where your data goes, internationally

**Our servers and storage are in the United States.** If you use PocketDJ from outside the US — including from the EU or UK — the data described in [§4](#4-what-goes-to-pocketdj-cloud-services) and [§9](#9-jukebox-hosting-and-the-guest-request-line) is transferred to and processed in the United States.

Transfer mechanism: {{TRANSFER_MECHANISM}}.
<!-- #TOUPDATE: must be true — no transfer mechanism has been selected or executed. Counsel question Q17 in legal-posture-conformance.md §9. Options include the EU Standard Contractual Clauses / UK IDTA, or the EU-US Data Privacy Framework if we self-certify. Do not publish a mechanism we have not actually put in place. See also legal-posture-conformance.md §8 Decision F ("Restrict the App Store territory to the United States?"), recommended but never decided: taking it materially narrows this obligation, and it is the same decision §12.3 is blocked on. Resolve it ONCE, for both sections. -->

Data you sync through iCloud is handled by Apple under Apple's own arrangements, not ours.

**EU/UK representative and Data Protection Officer:** {{EU_REPRESENTATIVE}}
<!-- #TOUPDATE: must be true, or the sentence must be deleted. We do NOT have a DPO and do NOT have an Art. 27 EU representative, and neither is necessarily required — a DPO is required only on the Art. 37 triggers (large-scale systematic monitoring or large-scale special-category data), which do not obviously apply; an Art. 27 representative is required for controllers outside the EU offering services to EU data subjects, subject to the Art. 27(2) small-scale/occasional-processing exemption. Do not claim either exists. Either appoint one, or replace this line with an honest statement of who to contact. Counsel Q17. -->

---

## 16. Security

We use HTTPS for everything, store credentials in the system Keychain, and serve your stored audio over authenticated, short-lived links.
<!-- #TOUPDATE: must be true — TWO current gaps. (1) Stored audio is served from a public-read prefix with no signature and no expiry; the app sends no Authorization header. Signed short-TTL URLs are part of the §4.2 work. (2) The AWS search credentials, the rip token, and the jukebox token are stored in PLAINTEXT UserDefaults (SettingsStore.swift:82-83,174) even though a working Keychain helper already exists in the codebase (StreamingTokenStore.swift, used for OAuth tokens). Move them to the Keychain — this is a small change and this sentence should not ship before it lands. -->

No system is perfectly secure. If you find a vulnerability, please report it to {{SECURITY_CONTACT}}.

---

## 17. Changes to this policy

We will post any change here and update the effective date at the top.

**If a change materially expands what we collect, how we use it, or who receives it, we will tell you in the app before the change takes effect** and — where the law requires consent — ask for it rather than assume it. We will not apply a materially different use to data we already hold without asking you first.

Past versions are kept in the project's public repository history so you can see exactly what changed and when.
<!-- #TOUPDATE: must be true — this promises a version history at a stable public location. Either publish the policy from a public repo (or keep dated archived copies at the published URL), or delete this sentence. -->

---

## 18. Contact

**Privacy questions, access requests, deletion requests:** {{CONTACT_EMAIL}}
**Everything else:** {{SUPPORT_EMAIL}}
**Postal:** {{POSTAL_ADDRESS}}

We aim to respond within {{RESPONSE_SLA}}.

If you are in the EU or UK and are not satisfied with our response, you may complain to your national data protection authority.

---

## Appendix A — Data flow summary

Read this as the one-page version of §3 through §9.

| Data | Leaves device? | Where to | Linked to you? |
|---|---|---|---|
| Audio you upload, import, or digitize from your own sources | **Yes** | PocketDJ cloud services (AWS, US) | Yes, under the target per-user architecture (§4.2) |
| Stems, tempo/key/beat-grid analysis, waveforms | **Yes** | Same | Same |
| Cloud lyrics transcripts | **Yes**, on request | Same | Same |
| Microphone recordings and recorded mixes | **No** — unless you ask for stem separation | Device only, or PocketDJ cloud services if you stemify | Same |
| On-device speech transcripts | **No** | Device only. Structurally enforced. | — |
| Song recognition | Signature only | Apple's Shazam service. Raw audio never sent. | No |
| Acting on a recognized song (add + process) | **Yes** | PocketDJ cloud services — title, artist, Apple Music catalog id ([§5.3](#53-song-recognition-shazamkit)) | Yes |
| Profile (random id + display name) | **Yes** | Your private iCloud database; display name also to the guest page while you host a jukebox | Yes |
| Collections, playlists, edits, favorites, imported songs | **Yes** | Your private iCloud database (we cannot read it) | Yes |
| Play history and play stats | **Yes** | Your private iCloud database. Also published to the guest page while a jukebox session is live. | Yes |
| Owner identity hash | **No** | Computed and compared on device only | — |
| Apple Music library reads and writes | **Yes** | Apple (your own account) | Yes |
| Jukebox guest request text, guest identifier, guest IP | **Yes** (from the guest's device) | PocketDJ cloud services | No account; IP and identifier are personal data |
| Discover search terms | **Yes** | PocketDJ cloud services → Apple's iTunes Search API | No |
| Online catalog search queries (opt-in) | **Yes** | Our managed search service | No |
| Catalog, artwork, lyrics text, instrument pack downloads | Outbound requests only | Our CDN | No |
| Widget snapshot | **No** | App Group container | — |
| Diagnostic capture | **No** — unless you export and send it | Device only | Would be, if you send it |
| Exports (.pdjcollection, backups) | Wherever you send them | Your choice | Yes — they contain your library |

---

## Appendix B — Consistency with the App Store privacy label

App Review rejects under Guideline 5.1.1 when the privacy label and the privacy policy disagree, and a mismatch is a credibility problem beyond the rejection. Confirm the mapping before submitting.
<!-- #TOUPDATE: this appendix previously opened "This policy was written FROM the label draft in `APPSTORE-SUBMISSION.md` §9" — a document that DOES NOT EXIST IN THIS REPOSITORY (searched repo-wide, excluding build output, node_modules, and worktrees). The premise of the appendix rested on a file no reviewer can open, and the mapping below was therefore unverifiable. Three of this document's citations pointed at missing files — `APPSTORE-SUBMISSION.md`, `DECISIONS.md`, and `COPYRIGHT-AUDIT` — across eight call sites; all eight have been rewritten against `docs/legal/legal-posture-conformance.md`, which does exist, or dropped where it has no counterpart section. If those three documents exist somewhere outside the repo, COMMIT THEM and restore the precise citations; otherwise the mapping below must be derived from Apple's own category definitions and checked by hand. -->

**Tracking: No** — behaviorally true; there is no tracking SDK, no ad network, and no attribution code in the binary.
<!-- #TOUPDATE: the claim "consistent with `NSPrivacyTracking=false` and an empty `NSPrivacyTrackingDomains`" was removed from this line because those keys DO NOT EXIST — there is no `.xcprivacy` in either target and no `NSPrivacyTracking` key anywhere in the repo (the only matches are inside ZIPFoundation's own bundled manifest in build output). You cannot be consistent with a declaration you have not made. Ship the manifests, then restore the sentence. Same gap as §10's third bullet. -->

| Label entry (all *Linked to you*, purpose *App Functionality*, not used for tracking) | Where this policy covers it |
|---|---|
| Contact Info ▸ Name | §5.1 (profile), §9.1 (DJ display name on the guest page) |
| Identifiers ▸ User ID | §13 (profile identifier), §9.2 (guest browser identifier) |
| User Content ▸ Audio Data | §4.1, §4.2, §7, §8 — **including microphone recordings and recorded mixes sent for stem separation** |
| User Content ▸ Other User Content | §5.1 (collections, edits, favorites, imported songs) |
| Usage Data ▸ Product Interaction | §9.1 (now-playing and queue snapshots published during a jukebox session) |
| Search History | §4.4 |
| Usage Data ▸ Other + User Content ▸ Other | §4.5 (server logs — song ids, and jukebox request text) <!-- #TOUPDATE: MAPPING CORRECTED, VERIFY BEFORE FILING. This row previously mapped *Diagnostics ▸ Other* to §4.5 (server logs), which is very likely wrong: in Apple's definitions *Diagnostics* means crash, performance, and other diagnostic data collected FROM THE DEVICE — and §10 of this policy correctly says we collect none of that, so declaring Diagnostics would contradict our own text. Backend request logs containing song ids map to *Usage Data*, and the text of a guest's jukebox request is *User Content*. Confirm both against Apple's current category definitions in App Store Connect before filling the label, and make sure the guest-side entry is not overlooked simply because guests are not app users. --> |

**Declared not collected:** location, contacts, health, financial info, browsing history, advertising data, purchases, crash data, and — with the §3 exception stated in this policy — device-only microphone audio and on-device speech transcripts.

**Three things to get right when transcribing the label:**

1. **Do not declare microphone audio as "not collected" without qualification.** The stem-separation path uploads microphone recordings and recorded mixes. *User Content ▸ Audio Data* is already declared and covers it, but the phrasing "microphone audio is device-only" is wrong as an unqualified statement and must not appear anywhere.
2. **If the Jukebox tab is gated out of v1.0**, revisit *Contact Info ▸ Name*, *Usage Data ▸ Product Interaction*, and much of *User Content ▸ Audio Data* — several may legitimately drop to not-collected, and §9 of this policy should be removed rather than left describing a feature that does not ship.
3. **Private-database CloudKit documents are treated as not collected by the developer**, on the ground that we cannot read them. That position is stated openly in §5.1 of this policy. If the label is filled in on a different theory, change the policy to match — not the other way around.

<!-- #TOUPDATE: the label has not been filled in and the `.xcprivacy` manifests DO NOT EXIST in either target — confirmed: `find apple -name "*.xcprivacy" -not -path "*/build*"` returns nothing, and the only hits anywhere are ZIPFoundation's own manifest inside build output. The manifest is not optional: the app uses UserDefaults (`pdj.settings.v1`) and file timestamps, both required-reason API categories.
     The reason codes previously listed here (UserDefaults CA92.1 + 1C8F.1; FileTimestamp C617.1 + 3B52.1, not DDA9.1; SystemBootTime 35F9.1; widget 1C8F.1 only; DiskSpace and ActiveKeyboards not triggered) were attributed to `APPSTORE-SUBMISSION.md` §3.4 — A DOCUMENT THAT IS NOT IN THIS REPOSITORY. They are retained here as a STARTING HYPOTHESIS ONLY, explicitly unverified, because a wrong reason code is itself a rejection. Before filing: re-derive each one from the actual API usage in the current source against Apple's required-reason API list, and record the derivation somewhere a reviewer can read. Do not copy these codes forward on the strength of this comment.
     All three artifacts — this policy, the label, and the manifests — must agree, and today only the first exists. -->

---

## Appendix C — Placeholders to resolve before publishing

**Every one of these is unresolved. None may ship as written.**

| Placeholder | What it needs | Note |
|---|---|---|
| `{{EFFECTIVE_DATE}}` | The date this policy actually goes live | |
| `{{LEGAL_ENTITY}}` | The exact publisher name — natural person or registered entity | Determines who the controller is, who the App Store listing names, and who a DMCA agent registration names. Not derivable from the code. |
| `{{CONTACT_EMAIL}}` | A monitored privacy mailbox | **Blocked on domain ownership.** `pocketdj.app` resolves to a parking IP with **no registration record** — assume it is not owned. Do not write `privacy@pocketdj.app`. Register a domain you control, create the mailbox, and send a test message to it before publishing. |
| `{{SUPPORT_EMAIL}}` | A monitored support mailbox | Same blocker. Also mandatory as an App Store Connect Support URL. |
| `{{SECURITY_CONTACT}}` | A monitored security mailbox | Same blocker. May be the same address as privacy. |
| `{{POSTAL_ADDRESS}}` | A deliverable address | Required for GDPR Art. 13 controller identification and for a DMCA agent registration. **A solo developer's home address may be publicly exposed by these filings — that is a decision, not an oversight.** |
| `{{AGE_RATING}}` | The band Apple computes from the questionnaire | Likely 13+ or 16+. Answer the questionnaire first, then write the number here. |
| `{{RETENTION_DELETION_SLA}}` | How fast a deletion request is honored | Needs an implemented server-side delete path first |
| `{{RETENTION_JUKEBOX}}` | Retention for guest requests, identifiers, and IPs | Must apply to **every** session, including timeless |
| `{{RETENTION_LOGS}}` | Server log retention | Needs implemented log rotation |
| `{{RESPONSE_SLA}}` | Response time for rights requests | GDPR default is one month |
| `{{TRANSFER_MECHANISM}}` | SCCs / UK IDTA / DPF self-certification | Must actually be executed, not just named |
| `{{EU_REPRESENTATIVE}}` | An Art. 27 representative, or an honest statement that none is appointed | **We have neither a DPO nor an EU representative.** Do not imply otherwise. |
| `{{TERMS_URL}}` | Public URL of the Terms of Service (§12.5) | TERMS links back to this policy twice via `{{PRIVACY_POLICY_URL}}`; the reciprocal links were missing entirely until now. Same hosting blocker as this policy. |
| `{{DMCA_URL}}` | Public URL of the Copyright / DMCA Policy (§12.5) | The DMCA policy was referenced NOWHERE in this document, despite §12.2 invoking compliance with copyright notices as a lawful basis. Also needs a registered designated agent — see DMCA §6's own marker. |

**Unmet prerequisites this policy depends on**, beyond the placeholders:

1. **A domain you own**, with working mailboxes, before any address here is published.
2. **A public URL to host this policy.** App Store Connect requires it and Guideline 5.1.1(i) requires it be reachable in-app too. Nothing is hosted anywhere today.
3. **Every `#TOUPDATE` resolved.** `grep -n "#TOUPDATE" docs/legal/PRIVACY.md`
4. **The three sibling documents agreeing with this one.** TERMS and DMCA currently contradict this policy on three checkable facts: whether there are accounts (TERMS §3 vs §13 here), whether the guest request form links to a privacy notice (TERMS §7.4 says yes; it does not), and whether the catalog is a way to obtain audio (TERMS §6.6 marks it; this document had dropped the marker — now restored at §4.3). They cannot ship disagreeing.
5. **The three cited-but-missing documents located or abandoned.** `DECISIONS.md`, `APPSTORE-SUBMISSION.md`, and `COPYRIGHT-AUDIT` are not in this repository and were cited eight times as authority. Every citation has been rewritten against `docs/legal/legal-posture-conformance.md` or dropped. If the originals exist, commit them; if they do not, the remediation instructions that depended on them — above all the privacy-manifest reason codes in Appendix B — must be re-derived from scratch rather than inherited.
6. **A decision on Decision F** (US-only initial availability). It is the shared dependency of §12.3 and §15, and it is noted in three places in this document and resolved in none.

---

## Appendix D — Questions for counsel

This is a draft by a developer, not legal advice. Specific questions this document cannot answer:

1. **Is the profile "account creation"** for App Review Guideline 5.1.1(v)? The app has no login, but it mints a durable identifier, syncs it, and publishes a display name to a public web page. What deletion scope satisfies the rule — and does it reach data we cannot currently attribute to a user because storage is not per-user?
2. **GDPR/UK GDPR minimums.** Are the lawful bases in §12 correctly assigned, particularly legitimate interests for jukebox guest IPs at an endpoint reachable by anyone? Does a legitimate-interests assessment need to be documented and retained? What retention periods are defensible?
3. **International transfers.** SCCs, UK IDTA, or DPF self-certification — which, and what has to be executed before EU/UK users are onboarded? Does restricting initial App Store availability to the United States (Decision F, recommended but never decided) change the answer enough to be worth doing?
4. **Is an Art. 27 EU representative required**, or does the Art. 27(2) exemption apply at this scale? Is a DPO required on any Art. 37 trigger we have not spotted?
5. **CloudKit controller/processor analysis.** Is the position in §5.1 — that private-database data is not "collected" by us — sound as a matter of law as well as App Store convention? Is a processor agreement with Apple needed, or does Apple's developer agreement already cover it?
6. **Guest data and children.** Guests are arbitrary members of the public, possibly including children, and we collect an IP address and a browser identifier before any notice is displayed. Is the Art. 13 notice in §9.2 sufficient, and does COPPA attach to a request line a host operates at their own event?
7. **The consent design for audio upload.** Cloud transcription and stem separation send the user's audio, including their own microphone recordings, to our servers. Is a one-time consent adequate, or does each upload need its own affirmative action? App Review 5.1.2(i) requires disclosure and consent for audio leaving the device to an AI process — what satisfies it?
8. **The irreversible favorites write.** Adding a song to Apple Music's Favorite Songs cannot be undone by any app. If we ever enable two-way sync, what does informed consent need to say, and does the irreversibility create any obligation beyond disclosure?
9. **Publishing a play history.** Jukebox publishes what the host is playing, has played, and will play next, to a page anyone with the link can read. Is a host-side attestation at session start the right place to handle that, and what should it say?
10. **Does this policy match what we actually built?** Ask counsel to check it against the resolved `#TOUPDATE` list rather than against this draft — the whole document describes a target state, and the gap between the draft and the code is the risk.

---

*PocketDJ is built by one person. This policy is written to be read, not to be impenetrable. If something in it is unclear or looks wrong, write to {{CONTACT_EMAIL}} and it will get fixed.*
