# PocketDJ — Third-Party Notices and Attributions

**App:** PocketDJ (iOS, iPadOS, macOS, visionOS)
**Bundle identifier:** `com.levi.pocketdj`
**App Store Connect app id:** 6784031333
**Publisher:** {{LEGAL_ENTITY}}
**Document version:** draft 1 — {{NOTICE_EFFECTIVE_DATE}}
**Contact for notices about this document:** {{CONTACT_EMAIL}}

<!-- #TOUPDATE: this document calls the app "PocketDJ" throughout, but the App Store Connect
     listing for app id 6784031333 names it "Pocket DJ - Rip, Burn, Mix". The name handed to
     Apple in a Content Rights declaration should match the listing. Blocked on open decision
     8.D in docs/legal/legal-posture-conformance.md ("do 'rip' and 'burn' get renamed?"). Settle
     the name, then make this document use it. -->

> **Draft status — read before relying on any sentence here.** An earlier draft of this file
> asserted several things about shipped infrastructure that are not true today, most seriously
> that the public catalog "never provides access to audio" (it does — see §7). Those claims have
> been corrected in place and marked. **Every remaining forward-looking claim carries a
> `#TOUPDATE` marker naming what must become true.** Grep for them before submission (§12).

---

## 0. How to read this

This file is the complete inventory of third-party software, assets, models, and data that
PocketDJ uses, ships, or redistributes — with the licence for each and the specific obligation
that licence puts on us. It is written to be the source for the in-app **Settings ▸ Legal ▸
Third-Party Licences** screen and for the answer to Apple's Content Rights declaration.

Three conventions:

1. **It describes the intended shipping state, not today's code.** Every claim that is not
   already true of the code and infrastructure as they exist right now carries a `#TOUPDATE`
   comment naming what has to become true. Grep for `#TOUPDATE` before submission and confirm
   each one.
2. **It is honest about gaps.** Section 9 lists every component whose licence could not be
   resolved, or whose licence does not cover the way PocketDJ uses it. Those are not
   paperwork items. One of them (§9.1, Demucs model weights) is a real infringement risk and
   is a ship blocker as currently architected.
3. **It is not legal advice.** Section 11 lists the specific questions counsel has to answer.

**Scope note.** "Ships" means the bytes go into the App Store binary. "Redistributes" means we
serve the bytes from PocketDJ cloud services to a user's device — legally a distribution, not a
use, and the two are governed differently. "Server-side" means the component runs in PocketDJ
cloud services and only its *output* reaches a device. Each entry below says which it is,
because the obligation changes.

**What "PocketDJ cloud services" actually is — stated plainly, because the phrase otherwise
conceals the fact that governs half this document.** It is not a managed multi-tenant service
with per-user authentication. Today it is two things:

1. **A public-read S3 bucket.** `pocketdj-rips-011183829623`, whose bucket policy makes the
   entire `rips/*` prefix world-readable (`scripts/rip-server.mjs`, "the bucket policy only
   makes `rips/*` public"). Audio, isolated stems, beat grids, waveforms, lyrics JSON and the
   redistributed SoundFont all live under that one public prefix. Verified with **no
   credentials**: `GET /rips/manifest.json` → HTTP 200; a range request on any
   `rips/<songId>.mp3` → HTTP 206 `audio/mpeg`.
2. **A request handler on a personal machine.** `scripts/rip-server.mjs`, reached over a
   Tailscale Funnel, whose defaults are tokenless — `public: process.env.RIP_PUBLIC !== '0'`,
   with an in-file warning that "every endpoint is open if the Funnel is mounted". A live probe
   recorded in `docs/legal/legal-posture-conformance.md` §2 returns `"auth":false,"public":true`.

Sanitising the *hostname* out of this document is right. Sanitising the *access posture* out of
it is not: "redistribution" below means redistribution **to anyone on the internet**, not to an
authenticated user, and every obligation that turns on distribution is therefore engaged at its
widest reading.
<!-- #TOUPDATE: the intended shipping posture is per-user keys, per-user authentication, no cross-user dedup, no public-read bucket policy, and S3 Public Access Block ON. That is the same five-item remediation PRIVACY.md §4.2 carries. Until it lands, every "redistributed" entry below is an unauthenticated public distribution. Re-read §4.1, §4.7, §7 and §9.1 after it lands — several of them get materially easier. -->
<!-- #TOUPDATE: this document is not routed to from any sibling. `grep -n "NOTICE.md" docs/legal/*.md` returns only this file citing itself. TERMS.md, PRIVACY.md and DMCA.md mention neither Demucs, nor the SoundFont, nor this file; PRIVACY.md §5's processor table lists AWS without the model/weight licensing posture §5.1 calls blocking. Before submission: link this file from TERMS.md and PRIVACY.md, and reconcile PRIVACY.md §5 with §5 here. -->

**Sibling documents.** `docs/legal/` also contains `TERMS.md`, `PRIVACY.md`, `DMCA.md`, and
`legal-posture-conformance.md`. Where this file and a sibling disagree, the disagreement is
flagged inline rather than silently resolved — see §7 (vs `PRIVACY.md` §4.2), §7.5 (vs
`PRIVACY.md` §4.3), and §9.13 (vs `legal-posture-conformance.md` §8.A).

---

## 1. Summary table

| # | Component | Version | Licence | How it reaches users | Obligation on PocketDJ |
|---|---|---|---|---|---|
| 2.1 | ZIPFoundation | 0.9.20 | MIT | Ships in the binary | Reproduce licence + copyright |
| 3.1 | MusicKit / Apple Music | platform | Apple DPLA + Apple Music Identity Guidelines | Framework | Badge + link to Apple Music; no artwork alteration; playback only |
| 3.2 | ShazamKit | platform | Apple DPLA + ShazamKit terms | Framework | Link recognised tracks to Apple Music |
| 3.3 | SF Symbols | 149 symbols | Apple SF Symbols licence | Ships in the binary | No modification; Apple-platform use only |
| 3.4 | Apple sample code (CosmoTunes) | WWDC26 | Apple Sample Code Licence | Derived shapes in the binary | Retain Apple notice |
| 4.1 | GeneralUser GS SoundFont | 2.0.3 (Licence v2.0) | GeneralUser GS Licence v2.0 | **Redistributed** from a public-read bucket | Attribution shown in-app; serve our own copy (we do) |
| 4.7 | **Mirrored cover art** (1,160 objects) | — | Third-party — iTunes / Discogs / Wikimedia | **Redistributed**, publicly, immutable 1-year cache | **See §4.7 and §7 — the caching itself is the breach** |
| 5.1 | **Demucs — model weights (htdemucs)** | v4 | **Not MIT. "Scientific purposes" only** | Server-side — **and its output is already published** | **See §9.1 — resolved against us, blocking; 1,217 songs already stemmed and world-readable** |
| 5.2 | Demucs — source code | v4 | MIT | Server-side | Reproduce licence |
| 5.3 | faster-whisper | current | MIT | Server-side | Reproduce licence |
| 5.4 | CTranslate2 | current | MIT | Server-side | Reproduce licence |
| 5.5 | OpenAI Whisper model weights | small | MIT | Server-side | Reproduce licence |
| 5.6 | librosa | current | ISC | Server-side | Reproduce licence |
| 5.7 | PyTorch | current | BSD-3-Clause | Server-side | Reproduce licence |
| 5.8 | FFmpeg | system binary | LGPL-2.1+ or GPL-2.0+ (build-dependent) | Server-side, invoked as a subprocess | See §5.8 — verify the build |
| 6.x | Web app npm dependencies | see §6 | MIT / Apache-2.0 / ISC | **Publicly served today** at the CloudFront origin | **Reproduce licences — obligation is LIVE and UNMET (§6)** |
| 7.1 | iTunes Search API | — | Apple Media Services / affiliate terms | Catalog metadata + artwork | Badge, adjacency, no caching of artwork |
| 7.2 | Discogs API | — | CC0 (open data) + restricted-data terms | Catalog metadata + artwork | Descriptive User-Agent; images are **not** CC0 |
| 7.3 | MusicBrainz | — | CC0 (core) / CC BY-NC-SA 3.0 (rest) | Artist country field | Credit; non-core data is non-commercial |
| 7.4 | Wikipedia (English) | — | **CC BY-SA 4.0** | 269 albums in `current-index.json` | **Attribution + share-alike — live obligation, §7.4** |
| 7.5 | Lyrics providers | — | **No licence** | 6,256 lyric files publicly served from our CDN | See §9.4 — and §7.5, this is a redistribution |
| 7.6 | Web search backfill | — | Unaudited | 555 albums in `current-index.json` | See §9.8 |
| 7.7 | **Apple Music (Local) library index** | — | **Apple Media Services terms** | **93,123 songs / 11,432 albums publicly served, no auth** | **See §7.7 — largest data source in the product, previously unanalysed** |
| 7.8 | `single-synth` synthesised metadata | — | First-party | 191 albums in `current-index.json` | None — recorded so the provenance table has no blank rows |
| 8.1 | XcodeGen | — | MIT | Build tooling only | None (not distributed) |

---

## 2. Swift package dependencies (ship in the app binary)

PocketDJ has exactly **one** third-party Swift package. This was verified against
`apple/project.yml` and
`apple/PocketDJ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
— the resolved pin list contains one entry.

Everything else in the app is first-party. A grep across `apple/PocketDJ` and `apple/Shared`
for vendored or adapted third-party source (`copyright (c)`, `SPDX`, `adapted from`,
`ported from https://github`) returned no third-party code. The Mix tab's DJ engine is a
first-party AVAudioEngine graph — the commercial audio SDK that once sat there was removed and
is not in the project.

### 2.1 ZIPFoundation

| | |
|---|---|
| **Version** | 0.9.20 (revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`) |
| **Source** | https://github.com/weichsel/ZIPFoundation |
| **Licence** | MIT |
| **Author** | Thomas Zoechling |
| **How it reaches users** | Statically linked into the App Store binary, all four platforms |
| **What we use it for** | Reading and writing `.pdjcollection` archives (playlist/pocket export and import) |

**Obligation:** MIT requires that the copyright notice and permission notice appear in all
copies or substantial portions of the software. Because we distribute a binary containing it,
we must reproduce the notice. That is satisfied by including the text below in the in-app
Third-Party Licences screen.
<!-- #TOUPDATE: the in-app Settings ▸ Legal ▸ Third-Party Licences screen must exist and must render this text. It does not exist today — there is no attributions/acknowledgements UI anywhere in apple/PocketDJ. -->

There is no attribution-in-marketing obligation, no share-alike, and no patent clause.

**Privacy-manifest note (not a licence obligation, recorded here so it is not re-derived):**
ZIPFoundation ships its own privacy manifest and is not on Apple's list of commonly-used SDKs,
so it needs no signature file and no vendored manifest work from us. Confirmed: a
`PrivacyInfo.xcprivacy` is present in the built ZIPFoundation bundle.

**But that only clears the dependency, not the app.** `find apple -name "*.xcprivacy"` outside
build output returns **nothing** — PocketDJ has no privacy manifest of its own. Apple requires
one for any app that uses a "required reason" API, and PocketDJ uses several categories that
qualify (file timestamps, disk space, user defaults). This paragraph previously stopped after
the ZIPFoundation sentence, which invited the reader to conclude the subject had been checked.
It had not.
<!-- #TOUPDATE: author apple/PocketDJ/PrivacyInfo.xcprivacy declaring the app's required-reason API usage, tracking domains, and collected data types, and register it in apple/project.yml so it lands in the bundle. Nothing exists today. This is an App Store submission blocker independent of everything else in this file. -->
<!-- #TOUPDATE: the privacy manifest's collected-data declarations must agree with PRIVACY.md. Reconcile the two before submission — they are currently authored independently, and PRIVACY.md §4.2 already carries a #TOUPDATE saying its own storage description does not match shipped code. -->
<!-- #TOUPDATE: this "no vendored manifest work" conclusion holds only while ZIPFoundation remains the sole third-party package. Re-check on any package addition (§12 step 2). -->

**Bundle-count check.** The 149 SF Symbols in §3.3 and the 1,160 mirrored art objects in §4.7
are the two inventories that drift fastest. Re-measure both at submission, not from memory.

**Full licence text:**

```
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. Apple frameworks with specific attribution or badge requirements

Apple's frameworks are licensed to us through the Apple Developer Program Licence Agreement
(DPLA), not through an open-source licence, so there is no licence text to reproduce. What they
do carry is **branding and attribution conditions**, and two of them are conditions PocketDJ
does not currently meet.

### 3.1 MusicKit / Apple Music

| | |
|---|---|
| **Component** | MusicKit (`MusicKit`, `MediaPlayer`), Apple Music catalog and playback |
| **Terms** | Apple Developer Program Licence Agreement; **Apple Music Identity Guidelines** |
| **Reference** | https://developer.apple.com/musickit/ · Apple Music Identity Guidelines |
| **Our use** | Apple Music library read, catalog search, and **playback only** |

**Posture, stated plainly:** Apple Music integration in PocketDJ is playback only. PocketDJ
plays Apple Music content through MusicKit, rendered by the MusicKit APIs, using the user's own
subscription. PocketDJ does not download, capture, record, store, or modify Apple Music content,
and does not synchronise it with other content.
<!-- #TOUPDATE: "does not download, capture, record, store, or modify" must be true of the shipped build and of PocketDJ cloud services. This is the MUST-tier remediation in docs/legal/legal-posture-conformance.md §7; it is not yet complete. Do not ship this sentence before the code matches it. -->

**Obligations this imposes:**

1. **Badge and link.** Where PocketDJ surfaces Apple Music content — an album, song, artist, or
   playlist — it must use an Apple-supplied "Listen on Apple Music" badge or lockup, linked to
   that item on Apple Music. We may not draw our own badge. Only one badge per context.
2. **Artwork must not be altered.** Artwork returned by MusicKit may not be cropped, recoloured,
   overlaid, or composited.
3. **Naming.** "Apple Music" is used per the Identity Guidelines in the App Store description
   and in-app copy; PocketDJ is not presented as an Apple product or as affiliated with Apple.
4. **No pre-add badge** in conjunction with MusicKit — that is an affiliate-terms violation.

**Current state:** a grep for `Listen on Apple Music`, an Apple Music badge asset, or any Apple
Music lockup across the Swift sources and the web app returns **nothing**. No badge ships today.
`Assets.xcassets` contains only `AccentColor`, `AppIcon`, `AppIcon.solidimagestack`, and
`PocketDJIcon`. This is a compliance gap that reviewers do check on MusicKit apps.
<!-- #TOUPDATE: an Apple-supplied "Listen on Apple Music" badge asset must be added to Assets.xcassets and rendered on every surface that displays Apple Music catalog content (BrowseView, AppleMusicInlinePanel, SongDetailView, NowPlayingPanel, RecognizedAlbumView). Also audit those views for artwork cropping/overlay. -->

### 3.2 ShazamKit

| | |
|---|---|
| **Component** | ShazamKit (`SHSession`, Shazam catalog matching) |
| **Terms** | Apple Developer Program Licence Agreement; ShazamKit service terms |
| **Reference** | https://developer.apple.com/shazamkit/ |
| **Our use** | The in-app recogniser — identify a playing track, then offer to add the album |

**The recogniser is not a clean read-only path, and §3.1's posture paragraph does not cover it.**
"Offer to add the album" understates what the flow does. `scripts/rip-server.mjs` documents the
downstream behaviour directly: an "AD-HOC rip: a freshly-recognized Apple Music track (PocketDJ
recognizer 'add to Apple Music + burn') that isn't in any indexed source yet. The digital worker
captures by artist+title (it searches Music.app)." The public manifest contains **4 live
`amrec_*` entries** — recogniser-originated captures, world-readable today. A reader who takes
§3.1's no-capture sentence together with this section's original wording would conclude the
recogniser path is clean. It is not.
<!-- #TOUPDATE: the ShazamKit recogniser must not trigger an Apple Music capture. Either remove the amrec_ ad-hoc rip path from scripts/rip-server.mjs entirely, or gate it to non-Apple-Music sources. Until then this section describes a capture path, not a metadata path, and §3.1's posture sentence is false for this flow specifically. The 4 existing amrec_ objects must also be deleted — see §9.13. -->

**Obligation:** Apple's guidance is specific and it is the one people get wrong. Matching
against the **Shazam catalog** and displaying the returned song metadata requires that we
**provide a link to that content in Apple Music**, in accordance with the Apple Music Identity
Guidelines. That link is mandatory.

The **"Powered by Shazam" lockup or Shazam icon is optional** — it may be used to promote the
recognition service but is not required. If it is ever used in marketing material it goes
through Apple's approval requirements. We do not currently use it and have no plan to.

**Current state:** the recogniser is shipped (`apple/PocketDJ/Views/Shazam/ShazamButton.swift`,
`RecognizedAlbumView.swift`) and displays returned metadata. The mandatory Apple Music link is
part of the same badge work as §3.1.
<!-- #TOUPDATE: RecognizedAlbumView must show an Apple Music link/badge for every Shazam-catalog match whose metadata it displays. Not present today. -->

### 3.3 SF Symbols

| | |
|---|---|
| **Component** | SF Symbols — 149 distinct symbols used across the app |
| **Terms** | Apple's SF Symbols licence (in the Xcode/SF Symbols licence agreement) |
| **How it reaches users** | Glyphs render from the system; symbol names ship in the binary |

**Obligations:** SF Symbols may be used in apps running on Apple platforms. They may **not** be
modified, may not be used to create a derivative or lookalike icon set, may not be used in app
icons or marketing, and may not be reproduced outside Apple platforms. PocketDJ uses them
unmodified as UI glyphs only, which is inside the grant. The PocketDJ app icon is
first-party artwork and contains no SF Symbol.

**On the count.** An earlier draft said 73, which counted only the `Image(systemName:)` call
site. Adding the `Label`/`Button(systemImage:)` form brings the unique total to **149** across
`apple/PocketDJ` and `apple/Shared`. Nothing legal turns on the number — the grant is
use-based, not per-symbol — but the figure was presented as measured, so it is corrected here
rather than dropped.
<!-- #TOUPDATE: confirm no SF Symbol was traced or adapted into AppIcon.appiconset / PocketDJIcon.imageset. The icon is believed first-party (the PDX-turquoise mark) but its provenance has not been formally recorded — see §9.6. -->

### 3.4 Apple sample code

`apple/PocketDJ/Intents/AudioSchema27.swift` states in its header that its shapes are ported
from Apple's WWDC26 sample **"Integrating your music app with Apple Intelligence" (CosmoTunes)**.
Apple sample code is distributed under the **Apple Sample Code Licence**, which permits use and
redistribution in compiled form and requires that Apple's copyright notice be retained.

Some caution is warranted about how much is actually "ported": the adopted items are the
assistant-schema entity and intent *shapes* (`audio.song` / `album` / `artist` / `playlist`
entities, `audio.playAudio` / `audio.addToPlaylist` intents, and two enums), and the schema
macros enforce those exact property sets at compile time. Property sets fixed by a compile-time
macro are closer to an API contract than to expressive code. Even so, the conservative and
cheap move is to retain the notice.
<!-- #TOUPDATE: add an Apple copyright/sample-code acknowledgement line to the header of apple/PocketDJ/Intents/AudioSchema27.swift and a line in the in-app licences screen. Neither exists today. -->

---

## 4. Bundled and redistributed assets

### 4.1 GeneralUser GS SoundFont — the virtual-instrument packs

| | |
|---|---|
| **Asset** | `GeneralUser-GS.sf2` (~32 MB), served as `banks/generaluser-gs-2.0.3.sf2` |
| **Version** | **2.0.3** (released 2026-02-22), under **GeneralUser GS Licence v2.0** |
| **Author** | S. Christian Collins (https://www.schristiancollins.com) |
| **Source** | https://github.com/mrbumpy409/GeneralUser-GS |
| **How it reaches users** | **Not bundled in the binary.** Redistributed from PocketDJ cloud services and downloaded on demand by the Instruments tab (`apple/PocketDJ/Studio/InstrumentPacks.swift`), then cached on device. One shared 32 MB bank backs all seven melodic instrument packs. |
| **Publisher script** | `scripts/upload-instrument-packs.sh` |

**This is a redistribution, not a use.** We serve the file to other people's devices. That is
the posture the licence has to be read against, and it is why this entry is longer than its
32 MB deserves.

**Obligations, and how we meet them:**

1. **Commercial use of the bank is expressly permitted.** "You may use GeneralUser GS without
   restriction for your own music creation, private or commercial… Please feel free to use it in
   your software projects."
2. **The licence imposes no formal attribution requirement.** Read strictly, v2.0 contains no
   "you must credit" clause. We credit anyway — the manifest carries an `attribution` string
   that the Instruments screen renders (`InstrumentPacks.swift`, `StudioInstrumentsView.swift`).
   That is the right call and costs nothing.
3. **Do not hot-link the author's downloads.** The licence asks: "If you plan to feature
   GeneralUser GS on your own website, please do not link directly to my download files. Either
   link to my website, or provide your own local copy instead." **We host our own copy**, which
   is the sanctioned path. Do not "fix" this by pointing at his server.
4. **The bundled licence text must travel with the redistribution.** Not strictly required by
   the text, but it is the norm for redistributing a permissively licensed asset and it costs
   one file.
   <!-- #TOUPDATE: publish the GeneralUser GS Licence v2.0 text alongside the bank in PocketDJ cloud services, and reproduce it in the in-app licences screen. Today only the one-line attribution string exists; the licence text is not bundled or served. -->

**Residual risk the author himself discloses — read this before signing the Content Rights
declaration.** The licence is candid that sample provenance inside the bank is not fully known:

> "Many of the samples are original, but some were taken from other banks freely (and legally)
> available on the Internet from various SoundFont websites. Because GeneralUser GS originated
> as a personal project with no intention for publication, I cannot be 100% sure where all of
> the samples originated, although I do know that none of them came from commercially published
> SoundFont packages or sample CDs… This uncertainty may concern you if you intend to use
> GeneralUser GS in a commercial software product. That being said, I have never received any
> complaint regarding sample ownership since I published the original GeneralUser GS back in
> 2000, and as far as I am aware, neither have any of the companies creating commercial software
> products using GeneralUser GS."

That is a 26-year clean record and a disclosed, bounded risk — not a blocker, but it is the
kind of thing counsel should see rather than discover. Logged in §9.5.

**Full licence text — GeneralUser GS Licence v2.0:**

```
*** GeneralUser GS v2.0.3 ***
***      License v2.0     ***

** License of the complete work **
You may use GeneralUser GS without restriction for your own music creation,
private or commercial. This SoundFont bank is provided to the community free of
charge. Please feel free to use it in your software projects, and to modify the
SoundFont bank or its packaging to suit your needs.

** License of contained samples **
GeneralUser GS inherits the usage rights of the samples contained within, all of
which allow full use in music production, including the ability to make profit
from musical recordings created with GeneralUser GS.

Many of the samples are original, but some were taken from other banks freely
(and legally) available on the Internet from various SoundFont websites. Because
GeneralUser GS originated as a personal project with no intention for
publication, I cannot be 100% sure where all of the samples originated, although
I do know that none of them came from commercially published SoundFont packages
or sample CDs. Regardless, many "free" SoundFonts available on the web may
indeed contain samples of questionable origin. My understanding of the
copyrights of all samples is only as good as the information provided by the
original sources. If you become aware of any restricted samples being used in
GeneralUser GS, please let me know so I can replace them.

This uncertainty may concern you if you intend to use GeneralUser GS in a
commercial software product. That being said, I have never received any
complaint regarding sample ownership since I published the original GeneralUser
GS back in 2000, and as far as I am aware, neither have any of the companies
creating commercial software products using GeneralUser GS.

** More info **
If you plan to feature GeneralUser GS on your own website, please do not link
directly to my download files. Either link to my website, or provide your own
local copy instead.

I hope you enjoy GeneralUser GS! This SoundFont bank is the product of many
years of hard work.

You can find updates to GeneralUser GS and more of my virtual instruments at:
http://www.schristiancollins.com

I can be reached via the contact page on my website here:
https://www.schristiancollins.com/contact

Thank you!
-~Chris
```

### 4.2 Sample packs, loop packs, drum kits

**None.** PocketDJ ships no sample library, no loop pack, and no drum kit. The Performance tab's
samples, loops, slices, and cue points are all created by the user from their own audio — there
are no factory samples in the binary and none served from PocketDJ cloud services. The only
instrument content we distribute is the GeneralUser GS bank in §4.1.

### 4.3 Fonts

**None.** A repository-wide search for `.ttf`, `.otf`, `.woff`, and `.woff2` (excluding build
outputs, `node_modules`, worktrees, and `dist`) returns no font files. The app uses system
fonts only, which carry no attribution obligation on Apple platforms.

### 4.4 Icons and app artwork

`Assets.xcassets` contains `AccentColor`, `AppIcon.appiconset`, `AppIcon.solidimagestack`, and
`PocketDJIcon.imageset` — all first-party. UI glyphs are SF Symbols (§3.3). No third-party icon
set (no Font Awesome, Feather, Material, Noun Project, or similar) is present.
<!-- #TOUPDATE: record the provenance of the app icon in writing — who drew it, when, and that no licensed stock or AI-generated asset with restrictive terms was used. See §9.6. -->

### 4.5 Bundled audio

One file: `apple/PocketDJ/Resources/studio-fixture.m4a` (9.7 KB). It is a **test fixture** used
by the Studio unit tests, not user-facing content.
<!-- #TOUPDATE: confirm studio-fixture.m4a is synthetic (a generated tone or silence) and not an excerpt of a commercial recording, and either exclude it from the Release build or record its provenance here. 9.7 KB is consistent with a synthetic fixture but this has not been verified by listening to it. See §9.7. -->

### 4.6 Demo or bundled catalog content

`apple/PocketDJ/Resources/fixture-index.json` is a small metadata fixture for tests — metadata
only, no audio. If a first-run demo experience with playable audio is added, every demo track
needs a licence row here with a source URL before it ships.
<!-- #TOUPDATE: if demo tracks are added, add a licence table to this section. Bundling CC-licensed demo audio also changes Apple's Content Rights declaration to USES_THIRD_PARTY_CONTENT, with this table as the authorisation. -->
<!-- #TOUPDATE: an earlier draft cited "open decision D10 in the critical-path doc" here. No file matching *critical*path* exists in the repo, so that citation pointed counsel at nothing on a Content-Rights question. Either create the decisions document and cite it by real path, or track the demo-content decision in §9 of this file. PRIVACY.md has the same defect class — it cites DECISIONS.md and APPSTORE-SUBMISSION.md, neither of which exists. Fix both. -->

### 4.7 Mirrored cover art — the second-largest redistribution in the product

An earlier draft discussed the art mirror in §7.1 and §7.4 but never inventoried it here, so a
reader of §4 concluded the SoundFont was the only redistributed asset. It is not.

| | |
|---|---|
| **Asset** | Mirrored album cover images — **1,160 objects** under `art/` in the web bucket |
| **Upstream sources** | `is1-ssl.mzstatic.com` (iTunes), `i.discogs.com`, `upload.wikimedia.org` |
| **How it reaches users** | **Redistributed** — served publicly over the same CloudFront distribution as the web app, with `cache-control: public,max-age=31536000,immutable` |
| **Licence** | **None held.** Each image belongs to its upstream rights holder. |

**Why this belongs in §4 and not only in §7.** Under this document's own scope note, serving
these bytes from our own storage to other people's devices is a *distribution*, not a use. It is
the same posture as the SoundFont in §4.1 — except that for the SoundFont we hold a licence
permitting redistribution, and for these 1,160 images we hold nothing.

The one-year immutable cache is not incidental: it is precisely the "downloaded, saved, cached,
or synchronized" that Apple's iTunes Search terms exclude (§7.1), and precisely the transfer of
"restricted data" that the Discogs terms exclude (§7.2). The Wikimedia subset is worse, because
most of those files are non-free fair-use uploads with no licence to attribute at all (§7.4).

<!-- #TOUPDATE: retire the art mirror. Hot-link from the licensed origin at display time and cache per-device only, with embedded cover art extracted on-device for user-supplied files. Until that lands, all 1,160 objects are an unlicensed public redistribution and this row cannot be signed off. Deleting the bucket prefix is part of the fix, not just changing the pipeline — the existing objects stay world-readable until they are removed. -->

---

## 5. Server-side software and ML models

These mostly run in PocketDJ cloud services (as defined in §0 — a public-read bucket plus a
request handler on a personal machine). Two corrections to what an earlier draft claimed here:

**1. Not all of it is server-side.** `scripts/rip-server.mjs:1401` offloads to SQS/EC2 only when
`CFG.stemOffload` is on **and** the song is a manifest song. The Producer ▸ Demuxer "create
stems" path for user-uploaded audio (`customStemSrc`) routes instead to the local separator
`scripts/lib/audio-stem.mjs`, which spawns Demucs natively via MPS or in local Docker. **Audio a
user uploads for stem separation is processed on the operator's own machine**, not in a cloud
worker. That is a materially different privacy and custody story and it is stated nowhere else.
<!-- #TOUPDATE: either route customStemSrc through the same cloud workers as manifest songs, or say plainly in PRIVACY.md that user-uploaded audio is processed on operator-controlled hardware. Today the document implies the former and the code does the latter. -->

**2. The audio that reaches them is not only the user's own.** An earlier draft said the workers
see "audio the user uploaded for their own collection, plus the user's own analog sources — that
is the only audio that reaches them", and marked only the forward-looking half. The present
tense was wrong in both directions:

- `scripts/rip-server.mjs:234-240` documents a live path: "When `ripFromCloud` is on, an ANALOG
  song that EXACT-matches a library entry is captured from Apple Music instead of the vinyl
  file… a cloud rip is indistinguishable from a real rip."
- `docs/legal/legal-posture-conformance.md` §8.A records **369 Apple Music captures that already
  exist**. They sit inside the 1,215 `digital` manifest entries, **988 of which have been through
  Demucs and faster-whisper**, and all of which are world-readable (§0).
- The rip server's own header calls Apple Music real-time capture "Phase 2", and the repo ships a
  `backfill-rip` skill whose stated purpose is to "local-rip each one from Apple Music
  (real-time capture → S3)".

For a document feeding Apple's Content Rights declaration, "is not sent" is the wrong tense.
The accurate statement is: **it was sent, the output exists, and the output is public.**
<!-- #TOUPDATE: "Apple Music content is never sent to these workers" must become true of the shipped server AND the historical objects must be dealt with. Removing the code path does not remove the 369 existing captures or the 988 stem sets and transcripts derived from them. Both halves are the MUST-tier remediation in docs/legal/legal-posture-conformance.md §7-§8.A; neither is complete. Do not ship a no-capture sentence in the present indicative before both land. See §9.13. -->

Only their *output* (stems, BPM/key/beat-grid analysis, transcripts) reaches a device. That
matters legally: running a model as a service is a weaker exposure than shipping its weights in
an app — but as §9.1 explains, weaker is not the same as permitted.

### 5.1 Demucs — pretrained model weights (htdemucs) ⚠️

| | |
|---|---|
| **Component** | `htdemucs` Hybrid Transformer Demucs v4 **pretrained weights** |
| **Origin** | Meta AI / Meta Platforms, Inc. |
| **Licence** | **NOT MIT.** See below. |
| **How we use it** | Server-side stem separation (vocals / drums / bass / other) for the Stemify, Mix stem-deck, Performance, and Demuxer features |
| **Invoked by** | Cloud: `.claude/skills/analog-indexer/stems/separate-one.py` (`STEM_MODEL=htdemucs`), `scripts/stem-worker.mjs`. **Local:** `scripts/lib/audio-stem.mjs` (`STEMS_MODEL = 'htdemucs'`, line 21) and `scripts/rip-server.mjs:98` (`demucsModel` default `'htdemucs'`) — the two that run it on the operator's own machine (§5) |

**This is the most important entry in this document, and the earlier internal audit got it
wrong.** `docs/legal/`-adjacent notes and the copyright audit both record "Demucs (MIT)". The
code is MIT. **The weights are not.**

Demucs' author, Alexandre Défossez, states directly in the project's issue tracker
(facebookresearch/demucs#327):

> **"The model weights are not covered by the MIT license, and are provided only for scientific
> purposes."**

A Demucs contributor explains the reason in the same thread:

> "The models are trained using MusDB dataset, which requires the result model can only be used
> for research purpose."

That traces to **MUSDB18**, the training corpus: it is provided for educational and academic
purposes only, and a substantial portion of it (the 46 MedleyDB tracks) is licensed
**CC BY-NC-SA 4.0** — non-commercial, share-alike. The non-commercial restriction on the
training data is what confines the resulting weights.

The Demucs README says only "Demucs is released under the MIT license as found in the LICENSE
file" and does not distinguish weights from code, which is exactly how this gets misread. The
LICENSE file is the MIT text for the **software**; it is not a grant for the weights.

**What this means for PocketDJ.** PocketDJ is a commercial App Store application. Using
research-only weights to generate stems for paying or public users is outside the grant, and no
amount of attribution cures it — this is a *scope* problem, not an *attribution* problem. See
§9.1 for the options.

**And this is not prospective.** The output already exists and is already published. The public
manifest shows **1,217 songs carrying `htdemucs` stems** (988 `digital` + 229 `analog`), each
one four world-readable mp3s under `rips/stems/<songId>/` — vocals, drums, bass, other. Verified
with no credentials: a range request on `rips/stems/<songId>/vocals.mp3` returns HTTP 206
`audio/mpeg`. Every section of this document that discusses Demucs must be read in that light:
the question is not only whether to ship the feature, but what to do about output already
generated and already served.

**Full licence text (Demucs code — MIT — reproduced because we use the code too):** see §5.2.

### 5.2 Demucs — source code

| | |
|---|---|
| **Version** | v4 (Hybrid Transformer Demucs) |
| **Source** | https://github.com/facebookresearch/demucs |
| **Licence** | MIT |
| **Copyright** | Meta Platforms, Inc. and affiliates |

**Obligation:** reproduce the copyright and permission notice. There is no obligation on the
*output* of the software and no share-alike on separated audio — the constraint on our use comes
entirely from the weights (§5.1), not from the code.

```
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### 5.3 faster-whisper

| | |
|---|---|
| **Source** | https://github.com/SYSTRAN/faster-whisper |
| **Maintainer** | SYSTRAN |
| **Licence** | MIT |
| **How we use it** | Server-side timed-lyrics transcription over the vocals stem (`scripts/transcribe-one.py`, `scripts/stem-worker.mjs`), model size `small` |

**Obligation:** reproduce the notice. **No restriction on output** — MIT imposes nothing on
transcripts the model produces, and no attribution is required on generated text.

Note that the transcript being unencumbered *by the model licence* says nothing about the
underlying song lyrics, which are a separate copyright owned by publishers. See §9.4.

### 5.4 CTranslate2

| | |
|---|---|
| **Source** | https://github.com/OpenNMT/CTranslate2 |
| **Licence** | MIT |
| **How we use it** | The inference engine faster-whisper runs on; pulled in as a dependency |

**Obligation:** reproduce the notice.

### 5.5 OpenAI Whisper — model weights

| | |
|---|---|
| **Model** | Whisper `small`, in CTranslate2 form (`Systran/faster-whisper-small` on Hugging Face) |
| **Origin** | OpenAI |
| **Licence** | **MIT — including the weights** |
| **How it reaches us** | Downloaded from Hugging Face by the worker on its first lyrics job |

**Obligation:** reproduce the notice. **This is the clean counter-example to §5.1** — OpenAI
released Whisper's model weights under MIT, commercial use included, with no output
restriction. It is worth stating explicitly, because "the code is MIT so the weights are MIT"
is true here and false for Demucs, and that asymmetry is exactly what the audit tripped over.

<!-- #TOUPDATE: the worker currently downloads the model from Hugging Face on first use (scripts/stem-worker-userdata.sh notes this is "accepted for now; bake the model into the AMI later"). If the model is baked into a worker image, that is a redistribution of the weights — still permitted under MIT, but the notice must travel with the image. -->

### 5.6 librosa

| | |
|---|---|
| **Source** | https://github.com/librosa/librosa |
| **Licence** | ISC |
| **Copyright** | 2013–2023, librosa development team |
| **How we use it** | Server-side audio analysis — BPM, key, beat-grid, waveform |

**Obligation:** reproduce the copyright and permission notice.

```
ISC License

Copyright (c) 2013--2023, librosa development team.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

### 5.7 PyTorch and the scientific-Python stack

Demucs pulls in **PyTorch** (BSD-3-Clause, Copyright The PyTorch Contributors / Meta), and
librosa pulls in **NumPy** (BSD-3-Clause), **SciPy** (BSD-3-Clause), **soundfile** (BSD-3-Clause),
**audioread** (MIT), and **numba** (BSD-2-Clause). All are permissive, all require notice
reproduction, none imposes anything on output.

<!-- #TOUPDATE: generate the complete transitive dependency licence list for the worker environment (`pip-licenses` against the venv at deploy time) and attach it. The list above is the top layer, verified by inspection of scripts/stem-worker-userdata.sh, not an exhaustive transitive audit. -->

### 5.8 FFmpeg

| | |
|---|---|
| **How we use it** | Invoked as a **separate system binary** by server-side scripts (`scripts/index-digital-files.mjs`, `.claude/skills/analog-indexer/lib/mirror-art.mjs`, and the stem/analysis workers, where it gives librosa its mp3 loader) |
| **Licence** | **LGPL-2.1-or-later** for a default build; **GPL-2.0-or-later** if built with `--enable-gpl` (which pulls in x264, libxvid, and similar) |

**Why the distinction matters:** the copyleft obligations of both LGPL and GPL attach on
**distribution**. We do not distribute FFmpeg — it is installed independently on the worker
machines and invoked as a subprocess, and the output files it produces are not derivative works
of FFmpeg. On that posture there is no source-provision obligation and no obligation on the
app.

Two things would change that: bundling an FFmpeg binary or library into the app, or shipping a
worker image that contains it to a third party. Neither is planned.

<!-- #TOUPDATE: confirm which FFmpeg build the worker AMI installs (run `ffmpeg -version` and check for `--enable-gpl`) and record it here. If a GPL build is ever bundled or shipped inside an image handed to anyone outside {{LEGAL_ENTITY}}, the copyleft analysis changes and counsel must re-read it. -->

---

## 6. Web application dependencies

PocketDJ began as a progressive web app, and the web client is **publicly served today**. An
earlier draft treated this as an open product decision — "whether it forms part of the public
release" — and marked it as a future question. That was wrong, and the error mattered: it
converted a live, unmet obligation into a hypothetical one.

Verified: `GET https://<the CloudFront origin>/` returns **HTTP 200**, serving the web client
and both catalog files. `scripts/deploy.sh:47` lists `current-index.json` and
`apple-music-index.json` by name in its no-cache set.

**Consequence: the obligations in this section are live and unmet.** The `hls.js` Apache-2.0
requirement (licence copy plus NOTICE preservation) and the seven MIT/ISC notices below are owed
**now**, and there is no licences page anywhere in the web app.

<!-- #TOUPDATE: this is a present breach, not a future decision. Publish a web-accessible licences page reproducing this section — the Apache-2.0 copy for hls.js plus the seven MIT/ISC notices — or take the web client private. One of those two must happen; today neither has. -->
<!-- #TOUPDATE: if the web client is instead retired or moved behind authentication, mark this section "not distributed", and re-check §7 — the public catalog files are served by the same distribution and would come down with it. -->

Runtime dependencies, versions and licences resolved from the installed tree:

| Package | Version | Licence |
|---|---|---|
| `react` | 18.3.1 | MIT |
| `react-dom` | 18.3.1 | MIT |
| `react-router-dom` | 6.30.4 | MIT |
| `zustand` | 5.0.14 | MIT |
| `@tanstack/react-virtual` | 3.14.2 | MIT |
| `fflate` | 0.8.3 | MIT |
| `idb` | 8.0.3 | ISC |
| `hls.js` | 1.6.16 | **Apache-2.0** |

**`hls.js` is the one that is different.** Apache-2.0 requires more than MIT does: retain
copyright, patent, trademark, and attribution notices; include a copy of the licence; state any
changes made to the files; and preserve any `NOTICE` file content in distributions. We make no
changes to it, so the practical obligation is licence text plus notice preservation.

Build-time-only dependencies (Vite, TypeScript, Vitest, Playwright, and their trees) are not
distributed and carry no notice obligation.

**Server-side note:** there are **two** request handlers, not one — `scripts/rip-server.mjs` and
`scripts/jukebox-server.mjs`. Both use **only Node.js built-in modules** — verified by inspecting
the imports of each (`node:http`, `node:child_process`, `node:fs`, `node:crypto`, `node:os`,
`node:path`, `node:url`) plus first-party local modules. There are no third-party npm packages to
attribute on either server. The conclusion an earlier draft reached was right; it audited one
server and generalised to "the request handler", which would have been wrong had the second
server differed.
<!-- #TOUPDATE: re-run this check against both servers on any dependency change, and add any third server to this list. §12 step 5. -->

---

## 7. Data sources requiring attribution

This is where the obligations are live rather than theoretical.

### 7.0 What the shipped catalog actually is

An earlier draft opened this section with two claims that are both false as written. Both are
corrected here, because every subsection below inherits them.

**Correction 1 — the catalog is ~8.5x larger than stated.** The shipped catalog is not one file.
Three index files are published, all three publicly served:

| File | Albums | Songs | Publicly served |
|---|---|---|---|
| `public/current-index.json` | 1,361 | 12,525 | yes |
| `public/apple-music-index.json` | 11,432 | 93,123 | yes — HTTP 200, 32,716,139 bytes |
| `public/digital-index.json` | 59 | 846 | yes |
| **Total** | **12,852** | **106,494** | |

That total matches the live rip-server `/health` figure (`catalog.songs: 106494`) recorded in
`docs/legal/legal-posture-conformance.md` §2.

**This is the load-bearing consequence:** every footprint count in §7.1–§7.6 (546 iTunes
artwork, 346 Discogs, 269/268 Wikipedia, 555 websearch, 9,139 lyrics) was measured over
`current-index.json` alone — **11.8% of the catalog** — and presented as the whole. Those counts
are correct *for that file* and are retained below with the file named explicitly. They are not
catalog-wide, and no subsection below should be read as if they were. The promise that "counts
were measured from the shipped file, not estimated" was true of one file and false of "the
shipped catalog".

**Correction 2 — the catalog does provide access to audio.** The earlier draft's standing
posture read: *"the public catalog is metadata only. It exists so people can browse and get
ideas. It never provides access to audio."* That was unmarked and it is false today.

The public catalog keys songs `sng_*`. The rips manifest is keyed by **the same `sng_*` ids**,
and it is world-readable. Verified with no credentials:

- `GET .../rips/manifest.json` → **HTTP 200**, 1,519 entries, mapping `sng_*` ids to
  `rips/<songId>.mp3`, plus isolated stems (`rips/stems/<songId>/{vocals,drums,bass,other}.mp3`),
  beat grids, waveform images and lyrics JSON.
- A range request on `rips/<songId>.mp3` → **HTTP 206 `audio/mpeg`**.
- A range request on `rips/stems/<songId>/vocals.mp3` → **HTTP 206 `audio/mpeg`**.

All of it sits under the public-read `rips/*` prefix (§0). Holding the catalog is therefore
sufficient to fetch the audio, the isolated vocal, and the transcript for any of those 1,519
songs, from anywhere, with no credential.

**This contradicted a sibling document, and the sibling was right.** `PRIVACY.md` §4.2 carries a
`#TOUPDATE` calling the shared-key public bucket "the largest gap between this document and
shipped code", with a five-item remediation list. The earlier §7 asserted the *conclusion of that
remediation* as present fact. Two documents in the same directory took opposite postures on the
same fact; this one was the wrong one.

<!-- #TOUPDATE: "the public catalog is metadata only and never provides access to audio" is the INTENDED posture and must not be restated as present fact until the §0 remediation lands: per-user keys, per-user auth, no cross-user dedup, public-read policy removed, Public Access Block ON. This is the single most important unmarked claim the earlier draft carried — it is an assertion of access control that does not exist. Do not ship it, and do not let it reappear, until an unauthenticated fetch of rips/manifest.json returns 403. -->
<!-- #TOUPDATE: re-measure all three index files at submission and update the table above. The Apple Music index is refreshed incrementally by a nightly job, so its counts drift between drafts. -->

### 7.0.1 Standing posture, stated accurately

The catalog is metadata. The **audio is separate infrastructure** — but it is not access-
controlled, and the catalog is the key to it. Until the §0 remediation lands, the honest
statement of posture is: *the catalog is metadata, and the audio it references is publicly
readable by anyone who has the catalog.*

### 7.1 Apple — iTunes Search API

| | |
|---|---|
| **Service** | iTunes Search API (`itunes.apple.com/search`, `/lookup`) |
| **Terms** | Apple Media Services terms / Apple Services Performance Partners terms |
| **What we take** | Album and track names, artist, genre, release year, track duration, explicit flag, and **artwork URLs** |
| **Footprint** | **546** of the 1,361 albums **in `current-index.json`** carry artwork from `is1-ssl.mzstatic.com`. Not measured across `apple-music-index.json` (§7.7) or `digital-index.json`. |

**Obligations, stated as Apple states them:**

1. **Attribution.** Content from the API must be attributed — for promotional content such as
   song previews, Apple's language is that it be identified as "provided courtesy of iTunes."
2. **Badge adjacency.** API-derived content must sit near an approved badge that links directly
   into Apple's store or Apple Music. This is the same badge obligation as §3.1.
3. **No caching of artwork.** Apple's terms permit artwork that is *"streamed only, and not
   downloaded, saved, cached, or synchronized."*
4. **No independent entertainment value.** The content must serve a promotional purpose, not
   stand on its own as the product.
5. **Rate limit.** Roughly 20 requests per minute, per calling identity.

**Honest assessment of where we stand:** obligations 2 and 3 are not met today. There is no
badge anywhere in the app (§3.1), and the art pipeline mirrors thumbnails to our own storage
with a one-year immutable cache, which is precisely the caching the terms exclude. Obligation 5
is also strained by routing all users' searches through one shared proxy identity, which
aggregates everyone under a single rate-limit bucket.

<!-- #TOUPDATE: three changes make this section true — (a) add the Apple Music badge (§3.1); (b) retire the artwork mirror and hot-link from the licensed origin at display time, caching per-device only, with embedded cover art extracted on-device for user-supplied files; (c) replace runtime iTunes Search with MusicKit catalog search, which is licensed for exactly this and is already integrated. These are items B6 / F9 / F14 in the copyright audit. -->

### 7.2 Discogs

| | |
|---|---|
| **Service** | Discogs public API (`api.discogs.com`) |
| **Terms** | Discogs API Terms of Use |
| **What we take** | Release metadata, tracklists with vinyl side/position, and **artwork URLs** |
| **Footprint** | **346** of the 1,361 albums **in `current-index.json`** sourced from Discogs; **346** carry artwork from `i.discogs.com` |

**Obligations:**

1. **Descriptive User-Agent.** Discogs requires a descriptive User-Agent identifying the
   client. We send one (`PocketDJ-Indexer/1.0`) — **it currently embeds a personal email
   address**, which should become a role address before launch. This is **not** limited to the
   Discogs UA: the same personal address is sent to MusicBrainz (§7.3) and Wikimedia (§7.4),
   neither of which flagged it. It appears in **four** live files:
   <!-- #TOUPDATE: replace the personal email address with {{CONTACT_EMAIL}} in ALL FOUR call sites — .claude/skills/analog-indexer/lib/enrich-playwright.mjs:50 (Discogs UA), .claude/skills/analog-indexer/lib/enrich.mjs:44, .claude/skills/analog-indexer/lib/mirror-art.mjs:48 (Wikimedia UA), and .claude/skills/analog-indexer/workflow/index-vinyl.workflow.js:135 (MusicBrainz UA). An earlier draft named only the first; following it as written would have left three live. Note the address also persists in .claude/worktrees/* copies — fix the canonical .claude/skills/ path and confirm no worktree is the one that runs. -->
2. **Rate limit.** Unauthenticated access is roughly 25 requests/minute; our indexer throttles
   to a single shared lane at ~1 call / 2.6 s, which is inside it.
3. **Data vs. images — the distinction that matters.** Much of the Discogs *database* is
   released **CC0**, which permits commercial use with no attribution required. **Images are
   not CC0.** Discogs hosts user-contributed images and does not own most of them; its terms
   restrict transferring "restricted data" to third parties and using it commercially. Mirroring
   346 album covers from `i.discogs.com` into our own bucket and serving them to users is
   exactly that kind of transfer.

<!-- #TOUPDATE: the artwork-mirror retirement in §7.1 covers the Discogs images too. Until then, the 346 mirrored Discogs covers are outside what CC0 grants. -->

We credit Discogs voluntarily even though CC0 does not require it.

### 7.3 MusicBrainz

| | |
|---|---|
| **Service** | MusicBrainz web service (`musicbrainz.org/ws/2`) |
| **What we take** | Artist country/area only — one field, best-effort |
| **Licence** | **Core data: CC0** (public domain). **Everything else: CC BY-NC-SA 3.0.** |

**Obligation:** the artist–area relationship is core data and therefore CC0 — no attribution
required, commercial use permitted. We credit MusicBrainz and the MetaBrainz Foundation anyway.

**The trap to avoid:** the non-core portion of the database is **CC BY-NC-SA 3.0** —
*non-commercial*. If the indexer is ever extended to pull tags, ratings, annotations, or other
non-core fields, that data cannot ship in a commercial app without a MetaBrainz commercial
licence. Keep the MusicBrainz surface at core data only.

**Attribution text:** "Includes data from MusicBrainz, licensed under CC0."

### 7.4 Wikipedia (English) — CC BY-SA 4.0, and this obligation is live

| | |
|---|---|
| **Source** | English Wikipedia, via REST search + article scrape |
| **Licence** | **Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)** |
| **What we take** | Infobox release date and genre, album artist, and **track listings**; also the infobox image URL |
| **Footprint** | **269** of the 1,361 albums **in `current-index.json`** have `wikipedia` in `enrichment.sources`; **268** carry artwork from `upload.wikimedia.org` |
| **Scraper** | `.claude/skills/analog-indexer/lib/enrich-playwright.mjs`; art mirror `.claude/skills/analog-indexer/lib/mirror-art.mjs` |

**A compounding problem in the art-mirror pipeline.** `mirror-art.mjs:48` identifies itself to
Wikimedia on every art fetch as
`PocketDJ-art-mirror/1.0 (https://pocketdj.app; <personal-address-redacted>)`. Both halves are
wrong: the email is a personal address (§7.2), and **`pocketdj.app` is not a registered domain**
(§9.12). The pipeline that produced the 268 Wikimedia covers announces itself to the rights
holder with a URL that does not resolve. That is the opposite of the good-faith identification
Wikimedia's user-agent policy asks for, and it is done at the exact moment we are taking their
files.
<!-- #TOUPDATE: fix the mirror-art.mjs User-Agent — real registered domain and {{CONTACT_EMAIL}} — or, preferably, retire the Wikimedia art path entirely per the marker below, which makes the UA moot. Note .claude/skills/analog-indexer/schema/index.schema.json:3 also declares an "$id" of "https://pocketdj.app/schema/index.schema.json" against the unregistered domain. -->

**CC BY-SA has two mandatory conditions, and failing either terminates the licence.**

1. **BY — attribution.** Credit the source, link the licence, and indicate whether changes were
   made.
2. **SA — share-alike.** Adaptations of the licensed material must be released under CC BY-SA
   4.0 or a compatible licence.

**Where PocketDJ stands.** Provenance *is* recorded — every album carries
`enrichment.sources` — but it is **never displayed anywhere**. Recording provenance in a JSON
field the user never sees does not discharge an attribution obligation. So today: 269 albums'
worth of Wikipedia-derived metadata ships with no attribution and no licence link.

**The honest nuance, because it cuts both ways.** Much of what we extract — a release year, a
genre string, a track title, a duration — is **fact**, and facts are not copyrightable in the
United States. A pure-facts extraction arguably never triggers CC BY-SA at all. Three reasons
not to rely on that:

- A **track listing** is a compilation. The individual titles are facts; the selection and
  arrangement may attract thin copyright, and in the EU the **sui generis database right**
  protects substantial extraction regardless of originality. The app is not US-only.
- There is direct evidence raw article markup reached shipped fields: `src/starmap/constellationMap.ts`
  contains a routine whose comment is "Strip Wikipedia CSS-blob leaks." Code that strips leaked
  markup is proof markup leaked.
- Attribution costs one line of UI. Losing a CC BY-SA argument costs the licence entirely.

**What discharges it:** an acknowledgements entry naming Wikipedia, linking
https://creativecommons.org/licenses/by-sa/4.0/, and stating that content was adapted — better
still, rendering `enrichment.sources` on the album card so the credit sits next to the data it
describes.

<!-- #TOUPDATE: (a) add the CC BY-SA 4.0 notice + link to the in-app licences screen; (b) surface enrichment.sources on the album detail card; (c) sanitise the scraper to factual fields only so no Wikipedia prose or markup can reach a shipped field. None of the three exists today. -->

**The share-alike question counsel must answer** is in §11 — whether the shipped catalog is an
"adaptation" of Wikipedia content such that SA reaches it. A metadata catalog assembled from
many sources is not obviously an adaptation of any one of them, but 269 albums is not
incidental, and getting this wrong means the catalog itself would have to be CC BY-SA.

**Wikimedia images are the sharper problem.** The 268 covers hot-linked from
`upload.wikimedia.org` are overwhelmingly **non-free files** — album covers uploaded to English
Wikipedia under a fair-use rationale that is specific to encyclopedic use. That rationale does
not travel to a commercial DJ app. The minority that genuinely are freely licensed carry
attribution requirements that our pipeline strips when it rewrites the art source. Both
failure modes point the same way.

<!-- #TOUPDATE: stop sourcing cover art from upload.wikimedia.org entirely. This is not fixable with attribution — the non-free files have no licence to attribute. Falls out of the same art-mirror retirement as §7.1. -->

### 7.5 Lyrics providers

The catalog's lyrics coverage came from two lineages: machine transcription (§5.3), and, before
that, third-party lyrics sites (`api.lyrics.ovh`, Genius, AZLyrics). See §9.4 — this is a
rights problem, not an attribution problem, and it does not belong in a notices file except to
say why nothing is credited here.

**Measured state of `current-index.json` today:** 9,139 of its 12,525 songs are marked
`lyricsStatus: "found"`; 300 carry `lyricsSource: "whisper"`; **0 carry inline lyrics text** in
that index. The text itself lives in separate files.

**"Separate files" is not containment, and this section previously implied it was.** Those files
are **6,256 objects under `lyrics/`** in the web bucket, served publicly over the same CloudFront
distribution as the web app (`GET /lyrics/` → HTTP 200). Moving lyric text out of the catalog
JSON did not move it out of public reach; it only moved it out of *this document's* count. A
further 1,217 lyrics documents ride the rips manifest (§7.0), also public.

**This contradicts a sibling document, and neither statement was complete.** `PRIVACY.md` §4.3
says the catalog documents contain "metadata only — titles, artists, albums, genres, tempo, key,
beat grids, waveform images, cover art, **and lyric text**". This file said the catalog carries
no lyric text. Both are true of different artifacts and both omit the operative fact: **the lyric
text is publicly served either way.**

**Under this document's own scope note, that makes it a redistribution.** §9.4 defers lyrics as
"a rights problem, not an attribution problem", which is a defensible answer to the *licence*
question — there is no licence to attribute, so no attribution row can be written. But §0
defines redistribution as serving bytes from our infrastructure to a device, and §12 makes this
file the inventory of what we redistribute. Serving 6,256 lyric texts from our CDN meets that
definition. The deferral and the scope note were inconsistent; the row is recorded here even
though its licence column reads "none held".
<!-- #TOUPDATE: reconcile with PRIVACY.md §4.3 — one description of what the catalog contains, agreed across both files, naming the lyrics/ prefix explicitly. -->
<!-- #TOUPDATE: the 6,256 public lyrics objects need a disposition, not just a deferral: take the prefix private, or delete it. Removing the scraper from the pipeline does not remove the objects already served. This is the same class of problem as the 369 Apple Music captures (§5) and the 1,217 stem sets (§9.1) — code changes do not retract published bytes. -->

### 7.6 Web search

555 of the 1,361 albums in `current-index.json` list `websearch` as their enrichment source — a
general-purpose search backfill for albums the structured sources could not match. This produced
factual fields (artist, album, year) rather than copied text.

An earlier draft added here that this was "worth naming so the provenance table has no blank
rows". The table had a blank row. `current-index.json`'s enrichment sources partition exactly:
`websearch` 555 + `discogs` 346 + `wikipedia` 269 + **`single-synth` 191** = 1,361. The fourth
bucket appeared nowhere in this document. It is §7.8 below.

<!-- #TOUPDATE: confirm the websearch backfill wrote only factual fields and copied no prose from any source page. It was an agent-driven recovery pass and its outputs have not been audited field-by-field. See §9.8. -->

### 7.7 Apple — the "Apple Music (Local)" library index ⚠️

**This is the largest data source in the product, and an earlier draft omitted it entirely** —
no subsection, no summary-table row, no marker. It is roughly **170x** the iTunes Search
footprint that §7.1 analyses at length.

| | |
|---|---|
| **Source** | The operator's macOS Music/iTunes `Library.xml`, indexed by the `apple-music-indexer` skill |
| **File** | `public/apple-music-index.json` — manifest `source: "Library.xml"`, `sourceName: "Apple Music (Local)"`, `enrichment.sources {"apple-music-library": 11432}` |
| **Footprint** | **11,432 albums / 93,123 songs**, including **75,282 Apple Music catalog ids** (`songsWithAppleMusicId`) |
| **How it reaches users** | **Publicly served, no authentication** — HTTP 200, 32,716,139 bytes from the CloudFront origin; listed by name in `scripts/deploy.sh:47` |
| **Terms** | Apple Media Services terms — the same terms §7.1 analyses for the 546-album iTunes footprint |

**Why this needs its own analysis rather than inheriting §7.1's.** The content is
Apple-Media-Services-derived metadata describing Apple Music catalog items, and we publish it
openly. Every obligation §7.1 enumerates applies here at 170x the scale:

1. **Attribution** — not present.
2. **Badge adjacency** — not present anywhere (§3.1, §9.2).
3. **No independent entertainment value** — this is the hard one. A 93,123-song publicly
   browsable index of one person's Apple Music library, served with no authentication, is
   difficult to characterise as promotional content adjacent to a purchase path. It reads as a
   standalone catalog, which is the thing the term excludes.
4. **The 75,282 catalog ids** are the join key into Apple's catalog. Publishing them openly is a
   different act from using them in-app to start playback.

<!-- #TOUPDATE: this section is an inventory, not a compliance conclusion — the analysis has not been done. Before submission, decide and record: (a) does apple-music-index.json need to be publicly served at all, or can it move behind the same per-user auth as the rest of the §0 remediation; (b) if it stays public, does a 93,123-song open index survive the "no independent entertainment value" condition; (c) do the 75,282 published Apple Music catalog ids raise a distinct issue from the metadata. This is a counsel question and it is added to §11 as question 9. -->
<!-- #TOUPDATE: the index is rebuilt nightly by the am-sync job, so it grows between drafts. Re-measure at submission. -->

### 7.8 `single-synth` — first-party synthesised metadata

**191 of the 1,361 albums** in `current-index.json` carry `enrichment.sources: ["single-synth"]`
— the fourth and previously unnamed provenance bucket (§7.6). These are synthesised
single-track album records generated by our own indexer rather than fetched from any third
party.

**Obligation: none.** The records are first-party. This subsection exists so the provenance
partition is complete and so a future reader does not have to re-derive that these 191 albums
are safe.
<!-- #TOUPDATE: confirm the single-synth generator copies no third-party field into the records it synthesises — if it seeds any of them from a Discogs or Wikipedia lookup, these 191 albums inherit that source's terms and this "no obligation" line is wrong. The generator has not been read for this. -->

---

## 8. Build tooling (not distributed — no obligation)

Listed for completeness so a future reader does not have to re-derive that they are safe.

| Tool | Licence | Why no obligation |
|---|---|---|
| XcodeGen | MIT | Generates the Xcode project at build time; no code ships |
| Vite, TypeScript, Vitest, Playwright | MIT / Apache-2.0 | Build and test only |
| AWS CLI | Apache-2.0 | Operator tooling |
| Docker | Apache-2.0 | Operator tooling |

---

## 9. UNRESOLVED — must determine before shipping

Each item is either unresolved or resolved *against* us.

**Ordering note.** §9.1–§9.12 are ordered by severity. §9.13–§9.19 were added later and are
appended rather than interleaved, so that existing cross-references (in this file and in
`legal-posture-conformance.md`) keep resolving. **Read the markers, not the position** —
**§9.13 is ⛔ blocking** and sits after several ⚠️ items purely because of numbering stability.

**The blocking set is: §9.1, §9.2, §9.3, §9.4, §9.13.** Of those, §9.1 and §9.13 each have a
remediation half covering output that is *already published*, which no code change retracts.

### 9.1 ⛔ Demucs pretrained weights are licensed for scientific purposes only — BLOCKING

**Status: resolved, and resolved badly.** This is not an open question about what the licence
says; the licence position is clear and it does not permit what we are doing.

The Demucs author states the weights "are not covered by the MIT license, and are provided only
for scientific purposes." The cause is MUSDB18, the non-commercial training corpus. PocketDJ is
a commercial App Store application whose Stemify, Mix stem-deck, Performance, and Demuxer
features all depend on those weights.

**Attribution does not fix this.** No notice text makes a research-only grant cover commercial
use.

**This is not a question about whether to ship — the output is already published.** An earlier
draft of this section was written entirely in the prospective ("this is the question that decides
whether the feature ships"; option E, "ship anyway"). That framing was wrong and it understated
the exposure. Measured from the public manifest:

- **1,217 songs already carry `htdemucs` stems** — 988 `digital`, 229 `analog`, `stemModel:
  "htdemucs"`.
- Each is **four world-readable mp3s** at `rips/stems/<songId>/{vocals,drums,bass,other}.mp3`,
  confirmed HTTP 206 `audio/mpeg` with no credentials (§0, §7.0).
- The 988 `digital` entries include output derived from the **369 Apple Music captures** in §5 —
  so for those, research-only weights were applied to captured Apple Music audio and the isolated
  stems are public.

The decision is therefore not only forward-looking. It has a **remediation half** that no option
below removes.

**The options, honestly:**

| Option | What it costs | What it buys |
|---|---|---|
| **A. Replace the separator** with a model whose weights permit commercial use | Engineering + quality regression risk; needs a survey of what exists on commercially-clear weights | Clean **going forward**. Everything downstream keeps working. Does **not** address the 1,217 existing stem sets. |
| **B. Licence the weights from Meta** | Contact Meta Research; unknown timeline, likely unavailable for a solo commercial app | Clean if granted, and potentially the only option that also cures the existing output |
| **C. Train our own weights** on a commercially-clear corpus | Substantial — data, compute, expertise | Clean, and the weights are ours. Existing output still needs regenerating. |
| **D. Cut stem separation from v1** | Loses Stemify, stem decks, per-stem Performance, the Demuxer, and the vocals-stem input to lyrics transcription | Removes forward exposure; a large product cut. Existing output still needs deleting. |
| **E. Ship anyway** | — | **Not recommended. Do not.** |
| **R. Remediate existing output** — delete or regenerate all 1,217 stem sets | Storage churn; regeneration cost under whichever of A–C is chosen | **Not optional and not an alternative to A–D.** Pair it with whichever is chosen. |

**Note the coupling:** lyrics transcription (§5.3) runs over the *vocals stem*, so option D
removes the transcription pipeline's input as well — and the 1,217 existing transcripts were
themselves produced from research-weight stems.

<!-- #TOUPDATE: option R is unscheduled and unowned. Whichever of A-D is chosen, the 1,217 published stem sets (4,868 mp3 objects) and the transcripts derived from them need an explicit disposition — delete, or regenerate under clean weights. "We changed the model" does not retract bytes already served from a public bucket. -->

**Counsel question:** does server-side use of research-only weights to generate output for a
commercial app's users infringe, and does it matter that the weights themselves are never
distributed? Our working assumption is that it is outside the grant regardless. **Note for
counsel: the premise "the output only reaches our own users" is false** — the stems are public,
so the output has been distributed to anyone who asked. Please advise on the existing 1,217 as
well as on future use.

### 9.2 ⛔ Apple Music badge and Apple Music link are absent — required by two frameworks

MusicKit (§3.1) and ShazamKit (§3.2) both condition our use on linking to Apple Music with an
Apple-supplied badge. No badge asset exists in the project. Reviewers check this on MusicKit
apps. Resolvable in hours, but it must not be forgotten — and it also carries the iTunes Search
API's adjacency requirement (§7.1).

### 9.3 ⛔ Wikipedia CC BY-SA attribution is not surfaced, and Wikimedia cover art has no licence to attribute

Two distinct problems in one source (§7.4). The metadata problem is fixable with a notice. The
**268 non-free cover images are not fixable with a notice** — they must stop being used.
Counsel must also answer whether share-alike reaches the catalog.

### 9.4 ⛔ Lyrics have no licence from anyone — outside this document's scope, flagged so it is not lost

Lyrics are the **musical composition** — a separate copyright, owned by publishers, unrelated to
any recording right. Neither scraping a lyrics site nor machine-transcribing a vocal creates a
licence: *ML Genius Holdings v. Google* (2d Cir. 2022, cert. denied) held that even Genius's own
transcription effort produced no rights it could assert. Enforcement in this area is systematic.

This is a rights problem, not an attribution problem, so it is handled in the copyright audit
and not here. It appears in this section only so that "nothing is credited for lyrics" is not
mistaken for an oversight. **It is a ship-blocking decision in its own right.**

### 9.5 ⚠️ GeneralUser GS sample provenance — disclosed residual risk

The author cannot fully verify where every sample originated (§4.1), and flags this specifically
for commercial software products. Mitigating: 26 years published, no ownership complaint, other
commercial products use it. **Unresolvable by us** — we cannot audit the provenance of samples
the author himself cannot trace. Counsel should decide whether the disclosed uncertainty is
acceptable or whether a different bank is warranted.

### 9.6 ⚠️ App icon and visual asset provenance is not recorded

The icon is believed to be first-party original artwork. That belief is not written down
anywhere. Before signing the Content Rights declaration, record who created it and when, and
confirm no licensed stock, no third-party icon set, and no generative-AI asset with restrictive
output terms was used.

### 9.7 ⚠️ `studio-fixture.m4a` provenance is unverified

A 9.7 KB bundled audio file used as a test fixture. Its size strongly suggests a synthetic tone
or near-silence, but **nobody has listened to it** and its provenance is not recorded. If it is
an excerpt of a commercial recording it must not ship. Cheapest fix: regenerate it as a
synthesised tone and note that here.

### 9.8 ⚠️ The `websearch` enrichment pass (555 albums) has not been audited for copied text

The largest single provenance bucket in the catalog is a general web-search backfill. It was
intended to produce facts only. That has not been verified field-by-field. If it copied
descriptive prose from source pages, those pages have their own licences and this section
becomes an attribution problem.

### 9.9 ⚠️ FFmpeg build variant unknown

Whether the workers' FFmpeg is an LGPL or a GPL build is unrecorded (§5.8). Immaterial while we
only invoke it as a subprocess; material the moment a worker image containing it is handed to
anyone outside {{LEGAL_ENTITY}}.

### 9.10 ⚠️ Shipped SoundFont bytes are not verified against the official release

We serve `banks/generaluser-gs-2.0.3.sf2` from PocketDJ cloud services. Its SHA-256 has not been
checked against the official GeneralUser GS 2.0.3 release. Verify before launch so we can state
what we redistribute. The publisher script already records a SHA-256 at upload time — compare
it to upstream.

### 9.11 ⚠️ Transitive server-side dependency licences not exhaustively enumerated

§5.7 lists the top layer by inspection. A full transitive audit of the worker Python
environment has not been run. Low risk (the scientific-Python ecosystem is overwhelmingly
BSD/MIT), but "low risk" is not "verified."

### 9.12 ⚠️ `pocketdj.app` is not registered — every URL in this document is a placeholder

Verified: the domain resolves to a parking IP with **no registration record**. No address at
that domain exists or receives mail. Nothing in this document, the privacy policy, the EULA, or
App Store Connect may state a `@pocketdj.app` address as if it worked. Registering the domain
and standing up real mailboxes is a prerequisite for the privacy-policy URL (a hard App Store
submission blocker under Guideline 5.1.1), the DMCA designated-agent registration, and the
support URL.

**The remediation above is too narrow — the domain is already being advertised to third
parties from live code.** This is not only a question of what our documents *will* say. Today:

- `.claude/skills/analog-indexer/lib/mirror-art.mjs:48` sends
  `User-Agent: PocketDJ-art-mirror/1.0 (https://pocketdj.app; <personal-address-redacted>)` to
  **Wikimedia on every art fetch**. The pipeline that produced the 268 Wikimedia covers flagged
  in §7.4 and §9.3 identifies itself to the rights holder with a domain that does not exist
  (§7.4).
- `.claude/skills/analog-indexer/schema/index.schema.json:3` declares
  `"$id": "https://pocketdj.app/schema/index.schema.json"`.

<!-- #TOUPDATE: extend the fix beyond documents to live code — every outbound User-Agent and every published identifier that names pocketdj.app. Grep the repo for the domain before submission, not just this file. -->

### 9.13 ⛔ Apple Music capture — an open decision this document previously stated as settled

§3.1's posture paragraph ("PocketDJ does not download, capture, record, store, or modify Apple
Music content") is written in the present indicative and carries a `#TOUPDATE`. That marker is
necessary but it was not sufficient, because this section — the place in this document reserved
for exactly this kind of item — had **no Apple Music entry at all**, and §3.2 restated the same
posture obliquely with no marker (now fixed).

`docs/legal/legal-posture-conformance.md` §8.A does not treat this as a described posture. It
lists Apple Music capture as **OPEN DECISION A** — "what happens to it?" — recommends A1 (remove
entirely), and records that the decision **has not been taken**. This document presented as
settled what its sibling presents as undecided.

**The facts that make it a decision rather than a description:**

- **369 Apple Music captures already exist** (`legal-posture-conformance.md` §8.A), inside the
  1,215 `digital` manifest entries.
- **988 of those have been through Demucs and faster-whisper**, so isolated vocals and
  transcripts derived from captured Apple Music audio are public (§5, §9.1).
- The capture path is live in code: `scripts/rip-server.mjs:234-240` (`ripFromCloud`) and the
  `amrec_*` recogniser path (§3.2), with **4 `amrec_*` entries** in the public manifest.
- The repo ships a `backfill-rip` skill whose stated purpose is real-time Apple Music capture
  to S3.

**Two halves, and the second has no owner.** Removing the code path makes §3.1's sentence true
going forward. It does nothing about the 369 existing captures and everything derived from them,
all of which is world-readable today.

<!-- #TOUPDATE: take open decision A in docs/legal/legal-posture-conformance.md §8.A and record it here. If A1 (remove entirely) is chosen, that means BOTH removing the ripFromCloud and amrec_ paths AND deleting the 369 existing captures, the 988 derived stem sets, and the derived transcripts. Until the decision is taken and executed, §3.1's posture sentence must not ship in the present indicative and Apple's Content Rights declaration cannot be answered. -->

### 9.14 ⚠️ The web app's licence obligations are live and unmet

§6. The web client is publicly served today (HTTP 200), so the `hls.js` Apache-2.0 obligation
and the seven MIT/ISC notices are owed now. There is no licences page. An earlier draft filed
this as a future product decision; it is a present breach. Cheapest fix in this document —
publish a static licences page — but it has to actually happen.

### 9.15 ⚠️ PocketDJ ships no privacy manifest of its own

§2.1. `find apple -name "*.xcprivacy"` outside build output returns nothing. This is an App
Store submission blocker independent of every licensing question in this file, and the earlier
draft's ZIPFoundation-only paragraph invited the reader to think the subject had been checked.

### 9.16 ⚠️ The public catalog is the key to public audio

§7.0. Until the §0 remediation lands — per-user keys, per-user auth, no cross-user dedup,
public-read policy removed, Public Access Block ON — holding the catalog is sufficient to fetch
audio, isolated stems, and transcripts for 1,519 songs with no credential. `PRIVACY.md` §4.2
already carries this as its largest gap. It is repeated here because §7 previously asserted the
opposite as fact, and because several obligations in this document are engaged at their widest
reading while it remains true.

### 9.17 ⚠️ Apple Music library index (93,123 songs) is published and unanalysed

§7.7. The largest data source in the product, publicly served with no authentication, governed
by the same Apple Media Services terms as §7.1, and absent from every earlier draft of this
document. The compliance analysis has not been done — see §11 question 9.

### 9.18 ⚠️ 6,256 lyric files and 1,160 art files are publicly served with no licence

§4.7 and §7.5. Both are redistributions under this document's own scope note (§0). Neither has a
licence behind it. Both need a disposition — take private, or delete — and neither is addressed
by changing the pipeline that created them.

### 9.19 ⚠️ This document is not routed to from any sibling

§0, §12. `grep -n "NOTICE.md" docs/legal/*.md` returns only this file citing itself. §12 declares
it "the source of truth for the in-app licences screen" and §11 question 8 asks whether that
screen discharges the obligations — but `TERMS.md`, `PRIVACY.md` and `DMCA.md` mention neither
this file nor Demucs nor the SoundFont, and `PRIVACY.md` §5's processor table lists AWS without
the model-weight posture §5.1 calls blocking. A source of truth nothing points at is not one.

---

## 10. Placeholders used in this document

| Placeholder | What it stands for | Blocked on |
|---|---|---|
| `{{LEGAL_ENTITY}}` | The publishing legal entity — sole proprietorship or formed company | Entity decision |
| `{{CONTACT_EMAIL}}` | Working contact address for licence and attribution questions | Domain registration (§9.12) |
| `{{NOTICE_EFFECTIVE_DATE}}` | Date this notice takes effect | Publication |

No company name, address, jurisdiction, phone number, or support email has been invented
anywhere in this document. Every one is a placeholder above.

**Nor is any real personal contact detail reproduced here.** The personal email address embedded
in four indexer User-Agent strings (§7.2, §7.4, §9.12) is referred to but never quoted — it
appears as `<personal-address-redacted>`. This matters because this file is destined for the
in-app Third-Party Licences screen: a document that fixes a personal-data leak in code by
reprinting the leaked value has not fixed it. The same applies to filesystem paths, which are
repo-relative throughout (§12 step 10).

---

## 11. For counsel

This document is a draft prepared by and for the developer. It is not legal advice. The
specific questions it cannot answer:

1. **Demucs weights (§9.1).** Does server-side use of model weights granted "for scientific
   purposes" to produce output for a commercial app's users infringe? Does it matter that the
   weights are never distributed to users? **Note the premise correction:** the output is not
   confined to our users — 1,217 songs' worth of `htdemucs` stems are publicly readable with no
   credential, so the output *has* been distributed. Given that, is option A (replace the model)
   sufficient going forward, and separately, what must be done about the 1,217 existing stem
   sets and the transcripts derived from them?

2. **Wikipedia share-alike (§7.4).** Is a metadata catalog assembled from several sources, 269
   of the 1,361 albums in `current-index.json` of which draw on Wikipedia infoboxes and track
   listings, an "adaptation" under CC BY-SA 4.0 such that share-alike reaches the catalog? If
   yes, what is the minimum compliant response — attribute and relicense the affected records,
   re-derive them from CC0/licensed sources, or drop them?

3. **Facts vs. compilation (§7.4).** Does extracting release year, genre, and a track listing
   from an encyclopedia article take only uncopyrightable facts, or does the track listing's
   selection and arrangement attract protection? Does the answer change outside the United
   States, particularly under the EU database right?

4. **Non-free Wikimedia images (§9.3).** Confirm that the 268 hot-linked cover images cannot be
   cured by attribution and must be removed — our reading is that a Wikipedia fair-use rationale
   does not extend to a commercial app, and we want that confirmed before we spend engineering
   time on alternatives.

5. **iTunes Search API artwork (§7.1).** Apple's terms permit artwork "streamed only, and not
   downloaded, saved, cached, or synchronized." Does an on-device display cache violate this,
   or only a server-side mirror? This determines whether the fix is "retire the mirror" or "do
   not cache artwork at all."

6. **GeneralUser GS residual risk (§9.5).** Is the author's disclosed uncertainty about sample
   provenance an acceptable risk for a commercial product, given a 26-year clean record and
   other commercial products relying on it? If not, what standard should a replacement bank
   meet?

7. **Content Rights declaration.** Given §4.1 (redistributed SoundFont) and §7 (third-party
   metadata and artwork), should Apple's Content Rights declaration be
   `USES_THIRD_PARTY_CONTENT`? Note it is effectively one-shot — Apple marks it required and
   not editable once the app is live — and Apple may request the authorisation, for which this
   document would be the answer.

8. **Sufficiency of this notice.** Does an in-app Third-Party Licences screen reproducing these
   texts discharge the reproduction obligations for a binary distributed through the App Store,
   or is a bundled licence file or a web-hosted equivalent also needed? Note the web client is
   separately and publicly served (§6), which may require its own licences page regardless of
   the answer for the app.

9. **The Apple Music library index (§7.7).** We publish `apple-music-index.json` — 11,432 albums
   / 93,123 songs of Apple-Media-Services-derived metadata, including 75,282 Apple Music catalog
   ids — openly, with no authentication. Does that survive the Apple Media Services conditions
   §7.1 enumerates, in particular "no independent entertainment value"? Is publishing the
   catalog ids a distinct act from using them in-app for playback? This is the largest data
   source in the product and it was absent from earlier drafts of this document.

10. **Public distribution generally (§0, §9.16).** Several analyses in this file would read
    differently if the infrastructure were access-controlled. Today it is not: audio, isolated
    stems, lyric texts, mirrored cover art, the SoundFont, and both catalogs are readable by
    anyone with a URL. Which of the obligations in this document change once per-user
    authentication lands, and which are already breached in a way that authentication does not
    cure retroactively?

11. **Retraction generally.** A recurring pattern across §5, §7.5, §9.1 and §9.13: fixing the
    code that generates something does not retract bytes already served from a public bucket.
    For each of — 369 Apple Music captures, 1,217 stem sets, 6,256 lyric files, 1,160 mirrored
    cover images — is deletion sufficient, and does anything further need doing given they have
    been publicly available for some period?

---

## 12. Maintenance

This file is the source of truth for the in-app licences screen and must be updated whenever a
dependency, model, asset, or data source is added, upgraded, or removed. Before each
submission:

1. `grep -n '#TOUPDATE' docs/legal/NOTICE.md` and confirm every marked claim is now true, or
   revise the claim. **This is the gate.** An unmarked forward-looking claim is the failure mode
   this document is most exposed to — the earlier draft asserted that the public catalog "never
   provides access to audio" with no marker, which would have passed this grep while being false
   (§7.0).
2. Re-read `apple/project.yml` and `Package.resolved` for new Swift packages.
3. Re-read `scripts/upload-instrument-packs.sh` and `apple/PocketDJ/Resources/` for new assets.
4. Confirm §9 is empty, or that every remaining item has a written decision behind it.
5. **Re-measure, do not recall.** Every count in this file drifts. At minimum: the three index
   files (§7.0), the SF Symbols total (§3.3), the `art/` and `lyrics/` object counts (§4.7,
   §7.5), and the rips manifest totals including stem coverage (§7.0, §9.1).
6. **Re-probe the access posture.** The claims in §0 and §7.0 are about live infrastructure, not
   about code. Fetch `rips/manifest.json` and one `rips/<songId>.mp3` **with no credentials** and
   record the status codes. If they still return 200/206, every "redistribution" entry in this
   file is an unauthenticated public distribution and must be read that way.
7. **Check both request handlers** (`scripts/rip-server.mjs`, `scripts/jukebox-server.mjs`) for
   new third-party dependencies (§6).
8. **Reconcile the siblings.** Confirm this file agrees with `PRIVACY.md`, `TERMS.md`, `DMCA.md`
   and `legal-posture-conformance.md`, and that at least one of them routes to this one (§9.19).
   Where they disagree, flag the disagreement inline rather than resolving it silently — the
   earlier draft silently took the opposite position to `PRIVACY.md` §4.2 and was wrong.
9. **Verify every cross-reference resolves.** The earlier draft cited "the critical-path doc",
   which does not exist (§4.6). `PRIVACY.md` cites `DECISIONS.md` and `APPSTORE-SUBMISSION.md`,
   neither of which exists. Pointing counsel at a missing document is a live problem.
10. **Grep for leaked personal infrastructure** — absolute `/Users/...` paths, personal email
    addresses, hostnames — in this file *and* in the code paths it describes (§7.2, §9.12). This
    document is destined for an in-app screen and for Apple.

---

*Prepared for review by {{LEGAL_ENTITY}} and its counsel. Not legal advice.*
