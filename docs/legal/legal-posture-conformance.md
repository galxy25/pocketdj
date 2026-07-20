# PocketDJ — Legal Posture Conformance and the Copy That Makes It True

**Status:** Internal working document. **Not legal advice.** Written by an engineering audit, for an
engineer, to be handed to counsel.
**Date:** 2026-07-20
**Scope:** the three-pillar legal posture as stated by the developer, audited against the code, the
live infrastructure, and the controlling authority.
**Jurisdiction:** §§1–4 and §§6–9 analyze **U.S. law only**. §5 addresses the rest of the world, where
several of this document's core conclusions **reverse**. Do not read any section but §5 as applying
outside the United States.

---

## 0. How to read this

You stated a posture in good faith and asked whether the code implements it. The useful answer is
not reassurance. This document does three things in order:

1. **Tests the posture.** One pillar is sound within its scope but scoped too narrowly to cover what
   the project actually publishes; one is sound as an architectural north star and unimplementable on
   the current API; one is stated in a form that cannot do the work you want it to do. All three are
   worth keeping as *design constraints* even where they fail as *legal defenses*.
2. **Reports the gap honestly.** Every code claim carries `file:line`. Where the code contradicts the
   posture, this document says so flatly.
3. **Designs the copy and the code together**, because publishing copy that describes a system you have
   not built is the single worst outcome available. Under the transmit-clause analysis, a written
   internal statement that a stream is private, while the code makes it publicly reachable, is not a
   mitigating fact — it is evidence you knew.

### Two readers, two different problems — do not merge them

Much of the remediation below serves one of two audiences, and they respond to opposite stimuli:

| | **App Review** | **A rights-holder's counsel** |
|---|---|---|
| What they see | The submitted binary, the listing, the screenshots, the strings | Conduct, reconstructed from infrastructure, repo history, and design docs |
| What a word like *Rip* does | Trips a pattern-match; may cause rejection on its own | Corroborates conduct they intend to prove independently |
| What fixes it | Renaming the string | **Nothing but not having done the thing** |
| Timeline | Before submission | Statute of limitations: 3 years, §507(b) |

A rename satisfies the first reader completely and the second reader **not at all**. Every item below
is tagged **[REVIEW]** or **[LIABILITY]** where the distinction changes what you should do. Items that
are purely submission-readiness are called that, so they do not consume attention budgeted for exposure.

### A note on this document's own storage

Caveat (d) below argues that internal writings become evidence. That argument applies to *this file*.
It records, in durable form, that 369 commercial recordings were captured and publicly served, and that
a design document recommended against an exposure that shipped anyway. Before committing it:

- The remote is `git@levi.github.com:galxy25/pocketdj.git` (verified via `git remote -v`). **Whether
  that repository is private, and who has read access, was not verifiable from the CLI and must be
  confirmed by looking at the GitHub settings page.** If it is public, or has collaborators outside
  privilege, do not commit this file.
- Git history is **append-only in practice**. A later `git rm` does not remove the blob from clones,
  forks, or GitHub's servers. Committing is a one-way decision.
- The reason to commit anyway is that this is an engineering work plan that must sit next to the code
  it audits, and losing it is worse than storing it. The reason to hesitate is that it is also the most
  quotable document in the repository.
- **The safest handling is to route it to counsel first and let counsel decide whether it should live in
  the repo at all**, potentially rewritten as an attorney-directed assessment. That is the one
  privilege-adjacent question worth resolving before anything else in §7 (see Q19).

This is flagged, not resolved. It is not an engineering call.

**The one-line summary:** the posture describes a defensible product. The code today ships a different
product — a world-readable shared library of 1,519 commercial recordings, plus an anonymous on-demand
ripper for a 106,494-song catalog, plus a self-described internet radio station. Nothing in Section 6
(the copy) may ship before the MUST items in Section 7 (the code).

---

## 1. Verdict on the posture itself

### The grades — the idea and the code, in one table

The earlier draft of this document graded the *idea* in this section and the *code* in §2, and the two
tables disagreed. A reader who stopped at the first table came away believing two of three pillars
passed. They do not. **Both grades now appear together, and the right-hand column is the one that
describes the product that exists.**

| Pillar | **Grade as an idea** | **Grade as implemented** | One-line verdict |
|---|---|---|---|
| **0 — Source provenance** *(unstated predicate)* | **Absent** — the posture never addresses acquisition | **VIOLATES** | Not a pillar you stated. It is the gap the largest exposure walks through, and no architecture fixes it. §4. |
| **1 — Individual copies (Cablevision)** | **Sound-with-limits** | **VIOLATES — unrepresentable** | Correct as an architectural north star; overreaching as a legal defense. Necessary, nowhere near sufficient, inapplicable to unlicensed sources. In code there is no user to namespace *by*. |
| **2 — Inspiration-only public catalog** | **Sound for what it covers; under-scoped as written** | **VIOLATES on three independent surfaces** | The metadata idea is right and has real shipping precedent. But the pillar as scoped contemplates *metadata* only — it never says anything about artwork or lyrics, both of which the project publishes. That is a **scoping defect in the posture**, not only an implementation defect. |
| **3 — Private performance only** | **Overreaching as stated** | **VIOLATES** | "Private" is a conclusion about the audience, not a term you can declare. The underlying instinct (allocate performance licensing to the host) is sound and is what shipping products actually say. |

**On Pillar 2 specifically.** The earlier grade of "Sound — the strongest pillar … fails today only
because the project publishes things that are not metadata" was too generous on this document's own
evidence. §3 finds **three independent public-surface failures** under this pillar, on **three
different CDNs**, written by **three different scripts**:

- the rips manifest, a complete download index (2.2);
- ~16,200 lyrics files across dev and prod (2.5);
- 1,160 re-hosted album covers (2.6), plus embedded cover art extracted from source files (2.7).

"Fails only because" implies a single slip. Three surfaces is a pattern, and the pattern's cause is that
the pillar was written about `index.json` and never extended to cover everything else the project
publishes. **Fix the posture's scope, not just the code.**

### The three caveats, addressed directly

**(a) Cablevision protected LICENSED content, so the posture cannot reach Apple Music capture.**

This is the most important sentence in the document and the one most likely to be resisted. *Cartoon
Network v. CSC Holdings*, 536 F.3d 121, 123 (2d Cir. 2008) records that plaintiffs provided the
programming to Cablevision "pursuant to numerous licensing agreements." Cablevision was already
authorized to transmit every frame to every one of those subscribers. The only question litigated was
whether a time-shifted replay was an *additional* infringement against a baseline of zero.

PocketDJ's baseline is not zero. There is no reproduction license, no public performance license, and
the Apple Music capture path takes a stream licensed for ephemeral playback and makes it permanent.
Strip the license from Cablevision and the case has no foundation: both load-bearing holdings
(volitional conduct, transmit clause) were answering "is this an *extra* wrong?"

Two further facts are routinely dropped: plaintiffs pleaded **only** direct infringement, and
Cablevision **waived fair use** (536 F.3d at 124). No real plaintiff accepts those constraints. A label
suing PocketDJ pleads direct reproduction, direct public performance, contributory, vicarious,
inducement, and §1201 — and PocketDJ would have to win all of them.

**(b) Aereo made per-user copies and still lost.**

*ABC v. Aereo*, 573 U.S. 431 (2014). Aereo's architecture was strictly *better* than PocketDJ's on
every axis the unique-copy theory cares about: a dedicated physical antenna per user, a genuinely
per-user copy made on that user's command, transmitted only to that user, sourced from **free
over-the-air broadcast the user was already lawfully entitled to receive**. Aereo lost 6–3, because
those differences "concern the behind-the-scenes way in which Aereo delivers television programming"
(573 U.S. at 441). The Court said flatly: "We do not see how the fact that Aereo transmits via personal
copies of programs could make a difference."

The practical instruction: *"we'll namespace the bucket per user"* is table stakes, not a cure. Pitching
it internally as the fix would be a mistake.

**(c) Private performance is about audience, not declaration.**

17 U.S.C. §101 asks who is "capable of receiving" the transmission. **Capability is a technical fact;
permission is a contractual fact.** Encryption, authentication, and short-TTL signed URLs constrain
capability. A clickwrap constrains only permission. That is precisely why Cablevision won — not because
subscribers promised not to share, but because the playback copy "can be decoded exclusively by that
subscriber's cable box."

The House Report the *Cablevision* court itself quotes approvingly forecloses the restricted-access
argument: a transmission is public "even though the recipients are not gathered in a single place …
[t]he same principles apply whenever the potential recipients … represent a limited segment of the
public, such as the occupants of hotel rooms or the subscribers of a cable television service."
H.R. Rep. No. 94-1476, at 64–65 (1976). Aereo's audience was paying, contracted, individually
authenticated subscribers, and was still "the public." *Redd Horne*'s patrons were alone in closed
booths, and were still "the public." 749 F.2d 154, 159 (3d Cir. 1984).

**This caveat is doctrine the rest of the document is held to.** Where a later section credits a
restraint, that credit is valid only if the restraint reduces *capability*. §2.8 has been rewritten
because two of its five credits failed that test.

**(d) Internal writings and feature naming are evidence.**

*Grokster* makes design documents, marketing copy, and feature names admissible on intent. This cuts
both ways here, and §3 marks where each way fires. It also governs this document (see §0).

### What the posture DOES buy — and it is real

Do not read the above as "the posture is worthless." It buys four concrete things:

1. **It rebuts inducement.** *MGM v. Grokster*, 545 U.S. 913, 936–37 (2005) turns on "clear expression
   or other affirmative steps taken to foster infringement." A developer whose design documents say
   *private only, per-user copies, no audio distribution* — and who builds toward it — is assembling the
   opposite record from Grokster. This matters more than it sounds: Grokster makes internal docs and
   feature naming into evidence, and PocketDJ's docs currently cut **both ways** (see §3, Pillar 3).
2. **It shapes architecture toward the defensible pattern.** Per-user keys, signed URLs, and no
   cross-user dedup are exactly what a §512(c) "storage at the direction of a user" analysis requires.
   The instinct is right even though §512 is separately forfeited today.
3. **It puts you on the right side of the MP3.com line — once implemented.** *UMG v. MP3.com*,
   92 F. Supp. 2d 349, 350–52 (S.D.N.Y. 2000) turned on provenance of the bits: the service was "re-playing
   for the subscribers converted versions of the recordings **it copied**." A true per-user locker where
   the bytes the user supplied are the bytes the user gets back is a materially different case.
4. **Aereo's own gloss genuinely supports one configuration.** Whether recipients are "the public"
   "often depends upon their relationship to the underlying work," and transmitting to people "in their
   capacities as owners or possessors" is not public. 573 U.S. at 447–48. **For your vinyl** — physical
   LPs you own, recorded by you, played back to you — that is a real argument, and it is stronger than
   anything MP3.com had. It is the thing worth designing toward.

Its limits are equally real. It does nothing for Apple Music captures (a subscriber is a licensee, not
an owner or possessor). It does nothing for a shared bucket. It does nothing for jukebox guests, who are
the Aereo audience exactly — "unrelated and unknown to each other." **And every one of these four
benefits is a statement about U.S. law; see §5 for how they fare elsewhere.**

### Where the posture is silent, and must not be

The posture governs **copying and transmission architecture**. It says nothing about **acquisition**.
That is the gap through which the largest exposure walks (§4). A flawless per-user, signed-URL,
authenticated, DMCA-registered rebuild leaves §106(1) reproduction untouched. *Disney v. VidAngel*,
869 F.3d 848 (9th Cir. 2017) rejected space-shifting fair use on better facts than yours — VidAngel
**bought the discs outright**, a stronger position than a revocable subscription — and lost on every
defense.

---

## 2. Conformance scorecard

Read this first. It is the answer to "are we there yet." **The grades here are the same grades as the
right-hand column of §1** — there is one verdict system in this document, not two.

| Pillar | Stated intent | What the code does today | Verdict | The single most important gap |
|---|---|---|---|---|
| **1 — Individual copies** | Every rip/burn produces a copy belonging to ONE user, made at that user's volition, downloadable only by that user. | S3 keys are `rips/<songId>.mp3` — keyed by **content**, never by user. Zero occurrences of `userId`/`profileId`/`tenant` in any key template. `rip-server.mjs:543` hands the first user's object to every later requester. Four separate dedup layers exist *specifically* to avoid making a second copy. | **VIOLATES** — aspirational, not implemented | There is no user. `authed()` (`rip-server.mjs:1904`) compares one process-wide shared token; the API has no identity to namespace *by*. Per-user copies are not merely unimplemented, they are **unrepresentable**. |
| **2 — Inspiration-only catalog** | Public surface exposes metadata so others can be inspired, not obtain audio. | The metadata catalog itself **conforms** — `current-index.json` carries no audio URLs. But `rips/manifest.json` is equally public and embeds the exact S3 key for every mp3, stem, cut, and transcript; **and** ~16,200 lyrics files and 1,160 mirrored covers are published on the web buckets, neither of which the pillar ever contemplated. | **VIOLATES** — on three independent surfaces, and **under-scoped as written** | The catalog defeats itself. Anonymous `GET /rips/manifest.json` → **HTTP 200, 1,283,718 bytes** — the authoritative download index for 1,519 recordings. `s3:ListBucket` is correctly denied; the manifest makes listing unnecessary. |
| **3 — Private performance only** | App is for private listening and private events; not public broadcasting. | The guest page is a functioning internet radio: `<audio>` element (`template.html:73`), drift-sync to the DJ's playhead (`:219-220`), "📻 On air" (`:222`), lock-screen station card. No presence binding, no listener cap, no listener credential, and `timeless` sessions never expire. | **VIOLATES** — and the feature is *named* what the law calls it | Both §101 clauses fire independently: the **place** clause and the **transmit** clause (a public S3 URL served to arbitrary pollers). |
| **0 — Source provenance** *(the unstated predicate)* | *(not stated — this is the gap)* | **The shipped app can capture Apple Music audio through four user-facing entry points**, and has: 369 of 1,519 live objects are Apple Music stream captures. | **VIOLATES** — and unfixable by architecture | This is an **acquisition** defect. No per-user copy, no signed URL, and no EULA reaches it. See §4. |

### The live facts that make this urgent

All re-verified from this machine during the audit, with **no credentials of any kind**:

```
GET  .../rips/manifest.json                       → HTTP 200,  1,283,718 bytes  (full key index)
GET  .../rips/sng_0265871ce36d.mp3   (range)      → HTTP 206,  audio/mpeg
GET  .../rips/stems/sng_.../vocals.mp3 (range)    → HTTP 206,  audio/mpeg  (isolated acapella)

GET  https://levis-imac...:10000/health  → {"catalog":{"songs":106494},"cached":1519,
                                            "auth":false,"public":true,"rateLimit":false}
GET  https://levis-imac...:8443/jukebox/health → {"sessions":4,"auth":false}
```

`"auth":false` on both live services means no token is configured, and both `authed()` and
`adminAuthed()` **fail open**. Every endpoint — including `POST /rip`, the explicitly uncapped
`POST /rip-collection`, and the entire admin path set — is currently reachable by anyone on the
internet.

### The observability facts — verified with credentials, and they are worse

The first question counsel will ask is **"was any of it actually downloaded?"** That question is, as of
today, **permanently unanswerable**. Verified against the account:

| Check | Command | Result |
|---|---|---|
| S3 server access logging, rips bucket | `aws s3api get-bucket-logging --bucket pocketdj-rips-011183829623` | **Empty response, exit 0 → never configured** |
| S3 versioning, rips bucket | `aws s3api get-bucket-versioning --bucket pocketdj-rips-011183829623` | **Empty response, exit 0 → never enabled** |
| CloudFront access logging | `get-distribution-config` on `E123GKAO9JVETP`, `E1SP8M1SIF7Q8D` | **`"Enabled": false` on both** |
| Is the rips bucket even behind CloudFront? | `list-distributions … Origins` | **No.** Origins are only the two web buckets and an API Gateway. The rips bucket is served **direct from S3**. |
| CloudTrail | `aws cloudtrail describe-trails` | **`[]` — no trails configured at all** |

Three consequences, and each is independently significant:

1. **There is no request-level record of any kind for the 1,519 audio objects.** Not S3 access logs, not
   CloudFront logs (the bucket isn't fronted by CloudFront anyway), not CloudTrail data events. If a
   scraper harvested the manifest and pulled the entire 74.55 GB corpus, **nothing in this account would
   show it.** Counsel's first question has no retrospective answer, and that fact is itself a finding.
2. **Enabling logging is a same-day action that must happen BEFORE the bucket is closed** (MUST-0b).
   Logging turned on today answers the question *going forward* and captures any harvesting still in
   progress. Turned on after the bucket closes, it records nothing of interest.
3. **Versioning is off, so deletion is terminal.** This resolves a question in the *opposite* direction
   from the intuitive worry: there are no retained prior versions silently preserving deleted objects.
   Deletes are real deletes. But it also means **there is no recoverable record after deletion** — which
   is exactly why the pre-deletion inventory snapshot in MUST-0c is not optional (§4, "Preservation").

---

## 3. Pillar-by-pillar findings

Ranked within each pillar. **IMPLEMENTED** / **ASPIRATIONAL** marks whether the posture is real in code.

### Pillar 1 — Individual copies

**1.1 — ASPIRATIONAL. Keys are content-keyed with zero user namespace.** `critical`

Every S3 key in the entire pipeline is a pure function of a content id:

| Artifact | Key template | Writer |
|---|---|---|
| Analog album | `rips/<albumId>.mp3` | `scripts/rip-server.mjs:841` |
| Per-song cut | `rips/<songId>.cut.mp3` | `scripts/rip-server.mjs:891` |
| Cloud capture | `rips/<songId>.mp3` | `scripts/rip-one.mjs:146` |
| Digital ingest | `rips/<songId>.mp3` | `scripts/index-digital-files.mjs:287` |
| Stems | `rips/stems/<songId>/<stem>.<ext>` | `scripts/stem-worker.mjs:121` |
| Analysis / lyrics | `rips/analysis/<songId>.json`, `rips/lyrics/<songId>.json` | `scripts/stem-worker.mjs:145,191` |

A grep for `users/|userId|user_id|owner|tenant` across all four writers returns **zero** matches
(every `--profile` hit is an AWS CLI flag). Two users ripping the same song get one object, because
the key is byte-identical. This is the structural property that separated MP3.com (lost) from
Cablevision (won).

**1.2 — ASPIRATIONAL. The shared-master short-circuit.** `critical`

```js
// scripts/rip-server.mjs:543
if (manifest[songId]) return { job: null, status: 'ready', url: publicUrl(manifest[songId].key) };
```

A second user's "rip" is not a rip — it is a redirect to the first user's file. This is stated as an
intended feature in `docs/design/user-profiles-cloudkit-public-rip.md:187`: *"The rip lands in
`rips/manifest.json` (public bucket) ⇒ every user can stream/burn it."*

Note the volition consequence, which is worse than the storage consequence: user #2 performs **no
copying act at all**. There is no volitional conduct to attribute to them. The only copy was made by
the service and is being redistributed. The short-circuit sits *above* the library probe at `:551`, so
no ownership-like check is ever reached.

**1.3 — ASPIRATIONAL. No access control on the objects.** `critical`

`publicUrl()` (`rip-server.mjs:148-149`) builds a raw, permanent, unsigned S3 URL — no signature, no
expiry, no identity binding. The bucket policy is `Allow * s3:GetObject` on `rips/*`
(`docs/architecture/07-distribution-and-clients.md:28-38`), with all four Public Access Block flags
false. The client depends on this: `Config.swift:21` hardcodes the raw bucket host and
`RipsStore.refreshManifest` sends no `Authorization` header at all.

There is **no presigner anywhere in the repo** for this bucket — the only SigV4 code is the OpenSearch
tooling. `docs/design/streaming-rips.md:227-228` marks private delivery as "Phase 4 — FUTURE" and
records the current state as an accepted risk.

**1.4 — ASPIRATIONAL. Concurrent users are merged onto one copy.** `critical`
`rip-server.mjs:551-556` — `resourceKey` is the songId or albumId, never the user. Two users
requesting the same resource concurrently do not each get a job; the second joins the first's.

**1.5 — ASPIRATIONAL. Analog rips are not even per-song.** `high`
`rip-server.mjs:845-856` transcodes the whole vinyl side to `rips/<albumId>.mp3` and registers a
manifest entry for every song on the album pointing at that one key with a per-song `startMs` seek.
Playback reads the shared album object; the per-song `cutKey` cuts exist but the code is explicit they
are burn-only. *Correction to a common overstatement:* the guard at `:847-848` skips songs that already
have a per-song cloud rip, so the collapse is "every song that lacks a per-song rip," not literally
every song.

**1.6 — ASPIRATIONAL. Three deliberate dedup layers.** `high`
`stem-worker.mjs:81-100` (`existingStems`, described in-code as "the worker-level song-id DEDUP"),
`:165-178` (`existingLyrics`), plus 1.2 and 1.4. Dedup is the exact mechanism that collapses per-user
copies into a shared master, and here it is named, documented, and load-bearing across three artifact
classes.

**1.7 — PARTIALLY IMPLEMENTED. Volition is mixed.** `high`

Genuinely user-volitional: tap → `POST /rip` (`RipsStore.swift:419`), Rip-all → `/rip-collection`
(`:887`), Stemify. **Not user-volitional:**

- `autoStemOnRip` defaults **ON** (`rip-server.mjs:119-123`; the ternary falls through
  `POCKETDJ_AUTO_STEM_ON_RIP` → `POCKETDJ_STEM_OFFLOAD` → `true`), firing at `:1096` per song and `:919`
  looped over every song of an analog album; stems then auto-chase lyrics at `:1714`.
- The 05:00 nightly digital indexer — **installed and loaded** in `~/Library/LaunchAgents`, not
  hypothetical — transcodes and uploads (`index-digital-files.mjs:287-291`) then POSTs
  `/backfill-stems` with `confirmLarge:true` (`digital-sync-nightly.sh:223`), whose own comment concedes
  the flag exists to defeat "the server's candidate cap."
- The `backfill-rip` skill mass-POSTs `/rip-collection` over a whole CSV of catalog misses
  (`.claude/skills/backfill-rip/backfill-rip.mjs:217-218`, live POST at `:349`).

*Correction:* `resumePending`/`resumeStems`/`resumeAnalysis` are **not** independent defects — they
re-drive work already accepted pre-crash. Their volitional root is whatever enqueued the work.

**1.8 — CORRECTED FINDING. `RIP_AGENT` is a latent capability, not active conduct.** `medium`

The audit initially flagged `rip-server.mjs:1049-1060` — a headless `claude -p
--dangerously-skip-permissions` agent instructed to *add* a missing track to the Apple Music library
and retry the capture — as destroying the volitional-conduct defense. **On verification this
overstates it.** `CFG.useAgent` is `process.env.RIP_AGENT === '1'` (`:85`), and a repo-wide search finds
**no launcher, plist, or install script that sets it**. The default path spawns the deterministic
worker, which cannot add anything — `rip-one.mjs:138` hard-fails with `no-match`. Even with the flag on,
the prompt is scoped to the single song already named in the user's own job and ends "Do nothing else."

The client-side `addSongToLibrary` (`RipsStore.swift:795-797`) is reached only from an explicit "＋ Add"
tap and calls Apple's own sanctioned MusicKit API against the user's own subscription. That is user
volition and **strengthens** the posture.

Residual truth worth keeping: the capability is checked in, and enabling it on a server strangers can
reach would weaken the volitional story. It warrants a documented do-not-enable note, not a five-alarm.

**1.9 — NOT IMPLEMENTED. There is no user.** `high`
`authed()` (`rip-server.mjs:1904-1908`) compares one process-wide `RIP_TOKEN`; `setup-rip-funnel.sh`
generates **a single token for all beta testers**. No rip request carries any user identifier — bodies
are `{songId}` / `{songId, ripFromCloud}`. `ProfileStore.id` (`ProfileStore.swift:47`) exists but is
used **only** for CloudKit private-DB document identity (`CloudSyncService.swift:160`); it appears
nowhere in `RipsStore`, `BurnStore`, or `TransferCoordinator`. `OwnerIdentity` is a binary owner
gate for favorites and never reaches S3 keys.

**Per-user copies cannot be implemented on top of an API that cannot tell users apart.**

**1.10 — PARTIALLY IMPLEMENTED. The on-device burn is the one real per-user artifact — and it is
also the one copy you cannot recall.** `info`
`BurnStore.swift:982` downloads to Application Support / a user-picked folder. It is genuinely
per-device and user-initiated — but it is downstream of the violation, fetched from the shared public
object. Do not cite it as evidence Pillar 1 is implemented.

**The remediation consequence is in §4 ("What deletion does not reach"): every burned file already on a
TestFlight tester's device survives every S3 deletion in §7.** There is no expiry, no remote
invalidation, and no server-side record of what any device burned.

### Pillar 2 — Inspiration-only catalog

**Scoping note, before the findings.** This pillar as stated governs *metadata*. Findings 2.5, 2.6, and
2.7 concern **lyrics** and **artwork** — two categories the posture never enumerates as permitted or
forbidden. They are not implementation failures against a clear rule; they are exposures in a space the
rule never covered. The remediation therefore has two halves: unpublish the content (§7), **and rewrite
the pillar to enumerate every class of thing the project publishes**, so the next new artifact type is
governed on arrival rather than audited later.

**2.1 — IMPLEMENTED (and the model for everything else). The metadata catalogs conform.** `info`

`current-index.json` (12,525 songs), `apple-music-index.json`, `digital-index.json` carry titles,
artists, albums, BPM, key, Camelot, sentiment keywords, explicit flags, and Apple Music catalog ids —
and **no fetchable audio location**. `pointer` is `{fileLocation:"Vinyl crate A", filename:"…Raw.mp3"}`
— a shelf location and a local filename. The 25,101 `"key"` hits are *musical* keys. Zero of 12,525
songs carry inline lyric text. The OpenSearch index stores metadata only and requires SigV4.

This is exactly what the posture describes, correctly implemented, and it is the legal basis that makes
the safe design genuinely safe rather than merely lower-risk: words and short phrases — names, titles,
slogans — are not copyrightable. 37 C.F.R. §202.1(a). *1001Tracklists* has published complete,
timestamped tracklists of copyrighted DJ performances for years on precisely this basis.

**Territorial caveat:** this reasoning is U.S.-specific in one respect that matters — the EU/UK *sui
generis* database right protects the **compilation** regardless of whether the individual facts are
copyrightable. See §5.4.

**2.2 — ASPIRATIONAL. The public manifest is a complete download index.** `critical`
`rips/manifest.json` sits inside the public `rips/*` prefix and is fetched anonymously by design
(`src/store/useRipsStore.ts:5-6,14-15` — *"The manifest is PUBLIC (fetched straight from S3)"*). Every
entry embeds the mp3 key, four stem keys, the cut, waveform, beatgrid, and lyrics transcript. Joining
the two public documents yields working anonymous download URLs for 392 named catalog songs.

The one access control that works — `s3:ListBucket` denied, HTTP 403 — is rendered moot. **The project
publishes the authoritative index of every object.**

This finding is load-bearing for 3.8 below: any control that gates a *payload field* while the manifest
publishes the same URL permanently is not a control.

**2.3 — ASPIRATIONAL. Anonymous download of full commercial recordings.** `critical`
Verified live: `rips/sng_0265871ce36d.mp3` → HTTP 200, `audio/mpeg`, 6,429,900 bytes. ID3:
Bryson Tiller, *Outta Time (feat. Drake)*. ffprobe: MPEG layer III, **256 kbps**, 48 kHz, stereo. A full
major-label master. Corpus: 1,519 recordings, 74.55 GB including stems.

**2.4 — ASPIRATIONAL. Isolated stems shipped against an explicit written recommendation.** `high`
4,868 stem files (1,217 songs × 4), including acapella vocals of commercial recordings, plus 1,217
word-timed Whisper transcripts — all anonymously fetchable at deterministic, manifest-enumerated keys.

`docs/design/stems-demucs-stemify-spec.md:815` reviewed this exact exposure, ranked three options, and
concluded: *"the entire isolated-acapella/instrumental corpus is trivially scrapeable with zero auth.
Isolated stems are materially more sensitive and independently redistributable than full-mix rips. This
is a real escalation over ripping, not parity… Recommend (1) or (2); **do not silently ship (3)**."*
Neither the authed proxy nor the opaque token was implemented. §6.3's question is still open at `:854`.

Under caveat (d) this is the aggravating fact: a written internal risk assessment that identified the
exposure, named the mitigations, and was not followed. *Precision:* nothing overrode it — the gate was
simply never closed, which is marginally worse evidentially, because no countervailing rationale was
ever recorded.

**This document has previously treated that finding only as *Grokster* inducement evidence. That
undersells it.** Its more direct role is as a **willfulness** predicate under 17 U.S.C. §504(c)(2):
willfulness means knowledge or reckless disregard, and a contemporaneous internal document that names
the exposure, ranks mitigations, and says "do not silently ship (3)" — followed by shipping (3) — is the
cleanest possible documentary proof of knowledge. It raises the statutory ceiling from $30,000 to
$150,000 per work. See §4, "The number counsel will ask for."

**2.5 — ASPIRATIONAL. ~16,200 lyrics files on the CDN — outside the posture entirely.** `high`
`scripts/lyrics-cdn.sh` syncs per-song lyrics to `s3://pocketdj-{env}-web-<acct>/lyrics/` with
`public,max-age=86400`. **9,945 objects in dev and 6,256 in prod** — this is shipped production
exposure, not a dev artifact. Anonymous `GET /lyrics/sng_0001e631f47f.txt` → HTTP 200, real lyric text.
Path is deterministic and songIds come from the public index, so the whole corpus is harvestable from
two public URLs.

Lyrics are separately copyrighted literary works reaching **publishers** — a different and more
aggressive enforcement population than the labels. They appear nowhere in the posture's enumeration of
permitted exposure. Stripping lyrics from `index.json` while serving the same text from `/lyrics/*.txt`
relocates the exposure without reducing it.

**Two provenance classes, and they are not the same legal object.** The corpus is a mix of
scraped publisher lyrics (Genius/AZLyrics, `docs/architecture/02-ingest-and-enrichment.md:218`) and
machine transcripts produced by Whisper from the vocal stem. The remediation is identical — unpublish
both — but the analysis is not, and merging them was a defect in the earlier draft:

| | **Scraped lyrics** | **Whisper transcripts** |
|---|---|---|
| What it is | A copy of a publisher's or licensee's published text | A machine transcription of the recording's vocal performance |
| Primary theory | §106(1) reproduction of the underlying **musical work's lyrics** (a literary work); plus the scraped site's own ToS and any compilation/annotation rights | Still §106(1) as to the underlying lyrics — transcription is a reproduction *of the words*, and accuracy is the point of the feature |
| Secondary theory | — | **§106(2) derivative work**, and separately a possible reproduction of the *sound recording* if timing/phrasing data is treated as fixation-derived |
| The "it's just facts" argument | Weak — the text is the work | **Also weak, and it is the tempting one.** "We didn't copy the lyrics, we observed them" fails: a transcript of a copyrighted text is a copy, not a fact. Compare a human transcribing a novel by ear. |
| Where it might differ | — | Word-level *timings* are arguably unprotected measurements of the recording; the *words* are not |
| Rightsholder | Publisher (+ scraped site) | Publisher; label has a secondary theory |

The practical upshot: **Whisper does not launder the lyric.** The one place the distinction may help is
the timing data alone, which is closer to the BPM/beat-grid analysis in 2.1 than to text. Counsel
question Q13 now asks about the two classes separately rather than as one merged question.

**2.6 — PARTIALLY IMPLEMENTED. 1,160 mirrored album covers, three sources, no recorded basis.** `medium`
`scripts/mirror-art.sh` thumbnails covers server-side to `/art/` and rewrites `coverArtSources` so the
CDN copy is **preferred over** the original — deliberately demoting the compliant hotlink to a fallback.

*Correction to the original finding:* sources are **mixed**, not Apple-only — `is1-ssl.mzstatic.com`
546, `i.discogs.com` 346, `upload.wikimedia.org` 268. Only ~47% is Apple.

The earlier draft resolved this with "keep, but earn it" and a one-line fair-use gesture. That was the
document's only optimistic fair-use call, it was unargued, and it sat oddly beside the document's
refusal of fair-use optimism everywhere else (*VidAngel*, *ReDigi*). Here is the actual analysis.

**The thumbnail cases, and why they fit worse than they look.** *Kelly v. Arriba Soft*, 336 F.3d 811
(9th Cir. 2003) and *Perfect 10 v. Amazon.com*, 508 F.3d 1146 (9th Cir. 2007) both upheld thumbnail
reproduction as fair use. Both turned on **transformative purpose through indexing**: the thumbnails
existed to help a user *find the source page*, "a different function" from the original's aesthetic
purpose (*Perfect 10*, 508 F.3d at 1165). Two facts about PocketDJ cut against importing that holding:

1. **A catalog browser is arguably not a search engine.** The art here decorates a listing of music in a
   library — the same ornamental/identifying function the original art serves on Apple Music or Discogs.
   That is *consumptive*, not transformative-by-indexing. *Perfect 10* is explicit that the transformation
   was "in the context of a search engine" pointing to third-party sources.
2. **Preference inversion is the worst fact.** *Perfect 10* leaned on the thumbnails driving traffic
   *to* the source. `mirror-art.sh` does the reverse: it rewrites `coverArtSources` so the mirrored copy
   is **preferred** and the compliant hotlink is demoted to fallback. The project deliberately chose to
   *replace* rather than *point at* the source. That is the single fact most likely to break the analogy,
   and it is a fact of the project's own construction.

Four-factor sketch, stated honestly:

| Factor | Reading |
|---|---|
| **(1) Purpose/character** | Weak-to-neutral. Non-commercial today, but identifying-use rather than indexing-use, and the preference inversion undercuts the *Perfect 10* framing. |
| **(2) Nature of the work** | Against. Album art is creative visual work at the core of copyright. |
| **(3) Amount** | **Favorable — the strongest factor.** 254×256 is a genuine thumbnail; *Kelly* and *Perfect 10* both accepted that reduced resolution forecloses substitution for the full-size work. |
| **(4) Market effect** | Mixed. No licensing market is displaced for a 254px thumbnail, but the mirror substitutes for the rightsholder-controlled delivery endpoint, and *Perfect 10* treated the existence of a thumbnail licensing market (cell-phone downloads) as cognizable harm. |

**Net:** materially less severe than audio or lyrics — but not the free pass the earlier draft implied.
The honest statement is *"a real fair-use argument on factor 3, weakened by our own preference
inversion, and never analyzed before now."* The cheapest way to strengthen it is to **invert the
preference back** (SHOULD-24), which costs nothing and removes the worst fact.

**2.7 — NOT ANALYZED UNTIL NOW. Two artwork surfaces the art analysis missed.** `medium`

**(a) Discogs — 346 images, governed by contract, not fair use.** The earlier draft named Discogs's ToS
and stopped there. That is the wrong place to stop, because a **contractual** restriction is not
defeated by a fair-use finding — breach of contract is a separate claim with separate remedies, and
*ProCD v. Zeidenberg*, 86 F.3d 1447 (7th Cir. 1996) is the standard cite for terms binding even where
copyright would not reach. Discogs's API terms have historically restricted commercial use and bulk
retrieval and required attribution; **the actual current terms were not read during this audit and must
be** (action: SHOULD-24, question: Q12). Note the asymmetry — the Wikimedia share got a license
analysis; the Discogs share, which is larger, got a sentence. That gap is closed by reading the terms,
not by reasoning about them.

**(b) Wikimedia — 268 images, and share-alike is the harder half.** This document has repeatedly
described CC-BY-SA as "attribution-required." That is the *easy* half and describes only the BY. The
**SA** is the term with teeth:

- **BY** is satisfied by crediting author, license, and source, with a link. Cheap. Do it regardless.
- **SA** requires that if you distribute an **adapted work**, you license the adaptation under the same
  or a compatible license. The live question is whether thumbnailing into a catalog creates an adapted
  work, and whether the catalog itself becomes subject to SA.
  - The defensible reading: resizing is a mere technical reproduction, and the index is a
    **collection** (CC 4.0 §1(a) distinguishes "Adapted Material"; a collection that merely aggregates
    does not become an adaptation). On that reading the obligation is attribution + license notice on
    the image, and nothing propagates to the catalog.
  - The uncomfortable reading: a derivative *crop/scale* plus incorporation into a compiled JSON
    distributed as a product invites the argument that the distribution triggers SA on the
    incorporating work.
- Two further traps specific to Wikimedia: **not everything on Commons is CC-BY-SA** (some is CC0/public
  domain, some is *non-free album art uploaded under a fair-use rationale on en.wiki* — which cannot be
  relicensed by us at all), and **license version matters** (3.0 vs 4.0 differ on how attribution and
  cure work; 4.0 has a 30-day cure provision that 3.0 lacks).

The correct engineering answer is the same either way: **record the actual license per image at mirror
time** (SHOULD-24), which converts an open legal question into a data field. The correct legal answer is
Q12, and it is now asked about SA specifically, not attribution generally.

**(c) Embedded cover art — missed entirely until now.** `low`–`medium`
The art analysis covered `/art/*` only. Two other surfaces carry the same images:

- **ID3 frames inside the mp3s.** The 1,519 objects in the rips bucket are transcoded from sources that
  carry embedded artwork; the ID3 read in 2.3 confirms tag data survives the pipeline. Embedded art
  ships with every anonymous mp3 download and every burn.
- **The extraction path is explicit.** `index-digital-files.mjs:250-266` picks a cover source (a loose
  `cover`/`folder`/`front` image, else the file's **embedded** stream) and extracts it with ffmpeg
  `-map 0:v:0` to `/art/<albumId>.jpg` on the **public web bucket** (`:19`, `:266`). So embedded art is
  not only carried along — it is actively promoted onto a public CDN.

This does not change the analysis for any image; it changes the **count and the surfaces**, which is
what MUST-6's purge scope and SHOULD-24's licensing field have to cover. Neither previously did.

The posture's hedge — "artwork-as-permitted" — is the right instinct with nothing behind it. Note the
project *does* record attribution when it believes one is needed
(`scripts/upload-instrument-packs.sh:40`, GeneralUser GS). That is proof the team knows how; the silence
on art is a genuine gap.

**2.8 — PARTIALLY VERIFIED. `.pdjcollection` export shares metadata only — claim confirmed.** `info`

§6.2 row 11 tells users an export *"shares the tracklist, not the audio."* That was the only factual
claim in the copy with no `file:line` behind it. **It is now verified and it is true.**
`PocketZip.export` (`apple/PocketDJ/Services/PocketZip.swift:94-105`) and `PlaylistZip.export`
(`PlaylistZip.swift:115-138`) build a zip containing `pocket.json`/`playlist.json` plus, when portable,
`items.json` — encoded by `PortableItems.encode(songIds:albumIds:songsById:albumsById:)` from
`IndexSong`/`IndexAlbum` **metadata structs**. There is no audio payload, no key reference into the rips
bucket, and no burn file. Import materializes provisional catalog entries, not media.

The claim may ship as drafted. Recorded here because unverified factual claims in legal copy are exactly
the thing that turns a good-faith statement into a misrepresentation.

### Pillar 3 — Private performance only

**3.1 — ASPIRATIONAL. The guest page is a functioning internet radio.** `critical`

| Element | Location |
|---|---|
| `<audio id="au" playsinline>` | `scripts/jukebox-site/template.html:73` |
| `au.src = curStream; au.play()` | `:211` |
| Drift-sync to DJ playhead, re-seek on >3 s error | `:219-220` |
| `"📻 On air — tap to stop"` | `:222` |
| `// View + Hear — the LIVE RADIO` | `:195` |
| `// any number of listeners, zero load on the host` | `scripts/jukebox-server.mjs:9-10` |
| *"Every guest is listening to a radio station whose distribution is S3"* | `docs/design/jukebox-hero.md:13` |

This is audio delivery to the listener's device, not a remote control. Both §101 clauses fire:

- **Place clause.** A party is "a place where a substantial number of persons outside of a normal circle
  of a family and its social acquaintances is gathered." This does not care how many copies exist or
  whether anything is transmitted. Note that **in the United States** there is no general performance
  right in sound recordings (§114(a)) — so the room-speakers case implicates the **musical work**,
  meaning exposure runs to publishers and the PROs, a different enforcement population from the labels.
  **Outside the United States this reverses completely and the labels are in the room too — §5.2.**
- **Transmit clause.** `streamUrl` is a permanent unauthenticated public object URL. §106(6) switches on
  the labels' digital-audio-transmission right, which no blanket license anywhere covers.

**3.2 — ASPIRATIONAL. No presence binding, no cap, no credential, no expiry.** `high`
Grep for `localNetwork|Bonjour|NWBrowser|geo|presence|proximity|listenerCap` returns **no access-control
hits**. Session ids are 8 base32 chars (40 bits, `jukebox-server.mjs:75`) — a bearer capability. The app
actively forwards it off-site (`JukeboxView.swift:145-154`, `ShareLink` + "Copy link"). `timeless`
sessions are exempt from both expiry and deletion (`:121`, `:357-358`), and `sweep()` at `:375-378`
**re-uploads the guest page every 10 minutes**, actively resurrecting it.

*Correction:* the hear-resume path (`JukeboxStore.swift:122`) restores `hearEnabled` only for a resumed
session; `:141` forces it false for every **new** session ("every party starts as a view-only request
line"). The original "hear comes back on every relaunch" framing was too broad.

**3.3 — ASPIRATIONAL. The service is interactive by construction.** `high`
Guests submit a specific title/artist (`template.html:330`), the host places it `.next`/`.end`/`.random`
(`JukeboxStore.swift:349-356`), and the guest hears that specific recording. Under §114(j)(7) this is
an interactive service — categorically excluded from the §114(d)(2) statutory license. **There is no
SoundExchange path at any price.** *Arista v. Launch Media*, 578 F.3d 148 (2d Cir. 2009) is the
blueprint for the alternative: LAUNCHcast survived because a user could never make a *chosen* track
play. PocketDJ already has the machinery (FM matcher, sentiment/BPM/key index) for a defensibly
non-interactive "request a mood" flow.

**3.4 — ASPIRATIONAL. Live services run with auth disabled.** `critical`
Both `/health` endpoints report `"auth":false`. `authed()` and `adminAuthed()` fail open
(`rip-server.mjs:1904`, `:1911`), `CFG.public` defaults **true** (`:59`), rate limiting defaults **off**
(`:62`), and the installed `com.pocketdj.jukeboxserver.plist` sets no `JUKEBOX_TOKEN`. An anonymous
stranger can mint jukebox sessions that spend your AWS credentials, and can drive the entire admin path
set (`/ingest-digital`, `/am-sync`, all `/backfill-*`). Both tokens exist in
`~/.pocketdj/rip-server.env` **commented out** — remediation is an uncomment plus a restart.

**3.5 — CORRECTED. `upNext` disqualifies; `played` does not.** `medium`
§114(d)(2)(C)(ii) bars publishing an advance program schedule. `composeState`
(`jukebox-server.mjs:213-222`) publishes `upNext` unconditionally — including when `hear` is on — and
the page renders the next 12 titles. That is a genuine independent disqualifier.

**The "Previously Played" card is not.** (C)(ii) is forward-looking ("to be transmitted"); a
retrospective log is not a prior announcement, and §114(d)(2)(B)(iii) affirmatively *requires* textual
identification of the recording being transmitted. Keep `played`.

**3.6 — RE-UPGRADED. The broker's view-only gate is not a control, because the broker is
unauthenticated.** `high` *(was downgraded to `medium`; that downgrade is withdrawn)*

`sanitizeNowPlaying` (`jukebox-server.mjs:174-185`) gates `streamUrl` on `/^https:\/\//` alone with no
reference to `hear`, so the server-side gate is scheme-only. The earlier draft downgraded this on the
ground that `hearStreamURL` (`JukeboxStore.swift:291-295`) returns nil unconditionally when
`hearEnabled` is false, all three payload constructors route through it, and posting state requires the
`hostKey` — therefore **"no shipped code path emits `hear:false` + an https `streamUrl` today."**

**That reasoning is invalid and the downgrade is withdrawn.** It is a client-side invariant asserted
about a server that reports `"auth":false` (3.4). The argument assumes the only writer is the shipped
app. It is not:

- Session minting is unauthenticated, so **anyone on the internet can mint a session and receive its
  `hostKey`.** The `hostKey` requirement is not an access control when the issuer hands one to any
  caller; it scopes writes to a session, it does not restrict *who* may have a session.
- With a self-issued `hostKey`, an arbitrary caller POSTs whatever state they like — including
  `hear:false` with an `https://` `streamUrl` — and `sanitizeNowPlaying` passes it, because the only
  check is the scheme.
- "No shipped code path does X" is a statement about **our** client. The relevant question under caveat
  (c) is **capability**, and the capability belongs to the internet.

Restored to `high`. The fix (SHOULD-19) is one line, and it should be made **authoritative on the
server** precisely because the client cannot be assumed to be ours. The existing test
(`test-jukebox-server.mjs:165-170`) remains misleading — it flips `hear` false *and* uses an `http://`
URL, so the null result is attributable to the scheme check alone, and it should be split.

**3.7 — CORRECTED. The code comments do NOT misdescribe this as private.** `info`
An earlier draft asserted the comments called public-bucket serving "the safe path," triggering caveat
(d). **That is wrong and is withdrawn.** The codebase is uniformly and explicitly honest:
`jukebox-server.mjs:176` "a **PUBLIC** rips-bucket mp3"; `JukeboxView.swift:167` "the current track's
**public** S3 rip"; `template.html:196` "straight from the rips bucket, no app needed." The
`JukeboxStore.swift:288` line ("ONLY rips-bucket audio ever leaves the building") is a **DRM-scope**
statement — accurate, and "leaves the building" concedes egress. Caveat (d) fires on the *stems* spec
(2.4), not here.

**3.8 — IMPLEMENTED. Real restraints that deserve credit — three, not five.** `info`

The earlier draft listed five. **Two have been removed because they do not survive this document's own
doctrine**, and leaving them in was a case of crediting a restraint to make the section read better:

> ~~"Hear defaults off and is force-reset per new session."~~ and ~~"the broker gates `streamUrl`."~~
> **Withdrawn.** Both gate a *payload field*. The value of that field is a **permanent public URL that
> `rips/manifest.json` publishes anyway** (2.2). A guest who can read the guest page can read the
> session id, and the manifest is anonymously fetchable by anyone at any time. Hear-off changes what the
> guest page *offers*; it does not change what the guest *can obtain*. Caveat (c) says capability is the
> test, and by that test these reduce nothing. They are UI defaults, not controls, and calling them
> restraints while insisting elsewhere that capability governs was incoherent.

The three that are real, because each removes a capability rather than a default:

- **MusicKit/DRM audio is never redistributed.** Only rips-bucket URLs are ever published
  (`JukeboxStore.swift:286-295`). This is a genuine class restriction on what can *ever* egress, not a
  toggle — there is no code path that publishes a DRM stream.
- **The Mix broadcast does not transmit the mixed output.** `JukeboxStore.swift:255-262` sends the
  on-air deck's *individual unmixed* rip with `positionMs: nil`. `MixRecorder` writes `.m4a` only to a
  local session folder with **no upload path anywhere** — the capability is absent, not disabled.
  `docs/design/jukebox-hero.md:211-214` explicitly defers live mix streaming. This avoids adding a
  derivative-work argument on top of the public-performance one, and it was a deliberate choice.
- **The `STUDIO_ID` fence** (`rip-server.mjs:503-514` + client twin `RipsStore.swift:211-217`) is the
  proof the architecture can do what the posture needs. Its own comment reasons through exactly the right
  failure mode: an old build "would otherwise fire a rip-on-demand here, live-search-capture some
  arbitrary Apple Music result, and upload it to the PUBLIC rips bucket." Two layers, defense in depth.
  **This is the template for the entire remediation.**

---

## 4. The source problem

**Top-line finding: yes — the shipped app can capture Apple Music audio, through four distinct
user-facing entry points, and it already has.** Of 1,519 live objects, **369 are Apple Music stream
captures**: 277 from the "Apple Music (Local)" source, 4 ad-hoc `amrec_` captures of arbitrary catalog
tracks, and 88 songs *you own on vinyl* whose audio was taken from Apple Music instead of the record.

The posture governs copying and transmission architecture. **It does not govern acquisition.** No
amount of per-user namespacing, signed URLs, or private-performance framing reaches a §106(1)
reproduction. This section is therefore independent of Sections 1–3 and survives every mitigation
proposed in them.

### The number counsel will ask for

§9 previously asked counsel "what is our exposure" without supplying the arithmetic this document
already had. That was an omission, because the magnitude determines whether this is a weekend of
engineering or a lawyer-first situation. **It is the second.**

17 U.S.C. §504(c), per work infringed, at the plaintiff's election in lieu of actual damages:

| Tier | Statutory range | × 369 works |
|---|---|---|
| Reduced (innocent, §504(c)(2)) | $200 | $73,800 |
| Statutory minimum | $750 | **$276,750** |
| Statutory maximum, non-willful | $30,000 | **$11,070,000** |
| **Statutory maximum, willful (§504(c)(2))** | **$150,000** | **$55,350,000** |

Five qualifications, all of which matter and none of which change the order of magnitude:

1. **"Per work," not per file.** 369 recordings is the work count for the *sound recordings*. Each also
   embodies a separately owned **musical work**, and publishers may sue independently — so the true
   denominator is plausibly larger, not smaller. Stems and transcripts derived from the same recording
   would not normally multiply the count (they are derivatives of one work), but they are separate acts
   of reproduction and distribution and are relevant to willfulness and to any actual-damages theory.
2. **§412 registration prerequisite.** Statutory damages and fees require registration before
   infringement (or within three months of publication). For commercial major-label recordings,
   registration is effectively certain, so the statutory election is available. This is the qualification
   that most often defeats statutory damages in practice, and it does **not** help here.
3. **Willfulness is where the stems finding bites.** §504(c)(2) requires knowledge or reckless
   disregard. `stems-demucs-stemify-spec.md:815` is a contemporaneous internal document that named the
   exposure, ranked mitigations, and said **"do not silently ship (3)"** — after which (3) shipped, with
   no recorded countervailing rationale. That is a willfulness exhibit, and it is why the top row of the
   table is the row to plan against rather than the row below it. The earlier draft filed this finding
   only under *Grokster* inducement (a **secondary-liability** theory); its more direct role is as a
   **damages multiplier on direct liability**.
4. **Fees.** §505 permits attorney's fees to a prevailing party, which is what converts a defensible
   case into an unaffordable one.
5. **Statute of limitations: three years** (§507(b)), running per the discovery rule in most circuits.
   Time does not cure this quickly.

**How to use this number:** not as a prediction. No plaintiff obtains a maximum award against a
single-developer non-commercial project, and settlements in this posture are ordinarily a small
fraction. Use it for exactly one decision — **whether remediation happens before or after counsel is
engaged.** At $276,750 floor exposure with a documented willfulness exhibit, the answer is that counsel
is engaged first and the engineering work in §7 proceeds in parallel, not that the engineering work
substitutes for it.

### The three tiers

| Tier | Sources | Rights story | Live count | Disposition |
|---|---|---|---|---|
| **STRONG** | **My Vinyl** — physical LPs you own, captured over line-in (`rip-server.mjs:807-853`, local ffmpeg, no third party contacted). Studio artifacts (`smp_`/`lp_`/`ptn_`/`tk_`), Mix/mic recordings. | Genuine. You own the object; the copy is yours; *Aereo*'s "owners or possessors" gloss (573 U.S. at 447–48) applies with real force; the *Sony*/*Diamond* time-shifting tradition is available. Materially stronger than anything MP3.com had. **U.S. only — see §5.3.** | 304 analog cuts | **Keep.** The only defect is *destination*, not source — they sit in the same world-readable bucket. |
| **WEAK** | **My Digital** — `index-digital-files.mjs` walks a user-pointed filesystem root and ingests any audio it finds. No provenance recorded or requested: a CD you ripped and a downloaded torrent are handled identically and are indistinguishable afterward. | Depends entirely on provenance the app cannot verify. Standing alone this is the defensible middle — personal files, personal library, a plausible space-shifting story *if* they came from media you own. **This story has no statutory basis in the UK at all (§5.3).** | 846 | **Keep the source, fix the destination + attest.** On a private per-user store these are the *easiest* category to defend. Publishing them to a world-readable bucket forfeits the personal-use framing entirely, because personal-use doctrines protect the copy, never the public distribution of it. |
| **INDEFENSIBLE** | **Apple Music capture** — `rip-one.mjs:2,61-62` drives the `rip` skill to play the track in Music.app while Audio Hijack records system output, transcodes to 256k, uploads. | None. A subscription is a licence to listen, not to fix a copy. Apple Media Services Terms: *"You may use the Services and Content only for personal, noncommercial purposes"* and *"may not modify, rent, loan, sell, share, or distribute."* *VidAngel* rejected space-shifting on **better** facts (purchased discs, not a revocable subscription) — and in the Ninth Circuit, the likely venue for an App Store product. | **369** | **Must go.** |

### The four entry points that reach Tier 3

1. **`POST /rip` from the shipped app** — `RipsStore.swift:419` (the play/download choke point), `:642`
   (`requestRipIfNeeded`), `:684` (`requestRip`), `:887` (`/rip-collection` batch). Server routing at
   `rip-server.mjs:798-800`: *"Digital songs always capture from Apple Music"* —
   `if (song.sourceType !== 'analog' || job.preferCloud) return runDigitalJob(job, song)`.
   `project.yml:32` declares the app target's sources as a whole-directory glob, so this compiles into
   the shipped iOS/macOS/visionOS binary; `SettingsStore.swift:488` seeds the rip-server URL from
   `Config.swift:31`, so the affordances are live on first launch with zero configuration.
2. **Browse ▸ Discover "＋ Add"** — `BrowseDiscover.swift:108-111`, whose own doc comment says the
   capture *"lands in the PUBLIC rips manifest, streamable/burnable by every user,"* and whose UI string
   at `:144` reads **"Search Apple Music — added songs are ripped to the shared catalog."** The app's own
   copy states the MP3.com pattern. *Correction:* the search runs **two** catalogs in parallel
   (`:41-49`) — MusicKit direct plus the `/search` iTunes proxy — so the capture surface is *broader*
   than the original finding described.
3. **"Rip from cloud source"** — `SettingsView.swift:475` → `RipsStore.swift:428` → `rip-server.mjs:549`.
   This is the most self-defeating path in the system: it takes the one category with a genuinely strong
   rights story and substitutes the one with none. **88 vinyl-owned songs** have already been redirected.
   Every one had a lawful local source. *Two corrections:* the toggle defaults **off**
   (`SettingsStore.swift:492`), and the result is **not** indistinguishable in the manifest — a cloud rip
   writes `source:'digital'` while a vinyl cut writes `source:'analog'` + `cutKey`. That field is exactly
   what made the 88 countable. The indistinguishability is at the *audio-object* level.
4. **`amrec_` ad-hoc synthesis** — `rip-server.mjs:533-541` synthesizes a digital row for any
   `amrec_<trackId>`, so an anonymous caller can `GET /search` → `POST /rip` → download, against a
   106,494-song catalog with no length limit on `/rip-collection`.

### The capture capability survives every app-level fix — and it must not

This is the most important structural correction in this revision. MUST-3, MUST-4, and MUST-5 close the
**app** doors and the **route** door. They do not remove the capture machinery, which is independently
invokable from a shell on the machine that serves the beta:

| Component | Path | Still runnable after MUST-3/4/5? |
|---|---|---|
| Capture worker | `scripts/rip-one.mjs` | **Yes** — `node scripts/rip-one.mjs <songId>` |
| Capture skill | `.claude/skills/rip/rip.mjs` | **Yes** — drives Music.app + Audio Hijack directly |
| Bulk backfill skill | `.claude/skills/backfill-rip/backfill-rip.mjs` | **Yes** — and it **mass-POSTs `/rip-collection`** (`:217-218` build, `:349` live call) over a whole CSV |

So after all twelve MUST items as previously ordered, **the machine can still mass-capture Apple Music**,
and the only thing standing between it and a repeat of the 369 is that nobody runs the command. The
earlier draft filed removal under SHOULD-14 ("gate behind operator confirmation"). That is inconsistent
with recommending A1: **if the recommendation is "remove the capability," deletion of the capture worker
and both skills belongs in MUST, not SHOULD.** It is now MUST-5b.

### Four runnable copies, not one

Every MUST/SHOULD item previously cited the `scripts/` copy of each file. There are more, verified by
`find`:

```
./scripts/rip-server.mjs
./.claude/worktrees/agent-a5bbb83921315bcda/scripts/rip-server.mjs
./.claude/worktrees/agent-a5f0c7abeca77ef37/scripts/rip-server.mjs
./.claude/worktrees/agent-af706589fdd7af12e/scripts/rip-server.mjs     → 4 copies

./scripts/rip-one.mjs  + the same three worktrees                      → 4 copies
./scripts/mirror-art.sh + the same three worktrees                     → 4 copies
./.claude/skills/analog-indexer/lib/mirror-art.mjs + three worktrees    → 4 copies
```

**A remediation that edits one copy leaves three runnable capture servers on the same machine that
serves the beta.** Each worktree is a complete checkout with its own `scripts/` tree; nothing prevents
`node .claude/worktrees/agent-*/scripts/rip-server.mjs` from binding a port and serving. MUST-5c
enumerates and removes the worktrees, and CI (SHOULD-25) asserts the count stays at one.

### The provenance field exists — wired to the wrong layer

The catalog layer carries a real discriminator: `sourceName` ∈ {`"My Vinyl"`, `"Apple Music (Local)"`,
`"My Digital"`}, loaded into `songById` at `rip-server.mjs:220-223`. **But the routing decision at
`:800` tests only `sourceType`**, which is binary `analog|digital` and conflates *your own files* with
*Apple Music*. And the rips manifest — the record that actually governs what is served — stores only
`source: 'analog'|'digital'`; both the capture writer (`:1088`) and the ingest writer (`:2301`) set the
identical value.

Two concrete harms: **prospectively**, a "My Digital" song missing from the manifest routes to an Apple
Music capture of a track you already own on disk; **retrospectively**, you cannot selectively audit or
purge, because nothing records how any object was acquired. I had to reconstruct provenance by joining
manifest keys against the index files.

### Preservation: do not delete before you snapshot

This document simultaneously (a) records in writing that 369 recordings were captured and publicly
served, and (b) recommends deleting those objects. That combination raises a question engineering
instinct will skip and counsel will not: **spoliation.**

The deletion is still right. Continuing to serve infringing copies is ongoing conduct and every day of
it is worse than the evidentiary awkwardness of having deleted them. But the sequence matters:

- **A duty to preserve attaches when litigation is reasonably anticipated** — not when it is filed. No
  claim, notice, or demand is known as of this date. That is the fact that makes deletion clean *today*
  and would make it much less clean the day after a demand letter arrives. **If any notice arrives,
  stop all deletion immediately and consult counsel before touching another object** (this instruction
  is repeated in MUST-6).
- **Versioning is off (§2), so deletion is irreversible.** There is no S3 version history quietly
  retaining what you delete. This cuts both ways: nothing lingers, and nothing is recoverable.
- **Therefore snapshot first.** MUST-0c takes a complete pre-deletion inventory — `rips/manifest.json`
  verbatim, a full `s3api list-objects-v2` dump with keys/sizes/etags/timestamps, and the join output
  identifying the 369 — committed to the private repo and stored with the audit. That preserves the
  *record* of what existed while removing the *copies*, which is the posture that best withstands both
  the "you destroyed evidence" question and the "you kept infringing" question.
- The snapshot is cheap (minutes) and blocks nothing.

### What deletion does not reach

MUST-1 closes the bucket policy and MUST-6 deletes 369 objects. Neither is retraction. Three distinctions
the earlier draft did not draw:

1. **"No longer exposed" ≠ "never distributed."** Closing a policy stops future access. It does not
   un-serve anything already served, and because there are **no access logs of any kind** (§2), the
   quantity already served is unknown and unknowable. This is the single most consequential unknown in
   the document.
2. **~1,150 objects stay in the bucket.** MUST-6 purges the 369 Tier-3 objects. The **846 My Digital**
   and **304 analog** objects remain — correctly, since their sources are defensible — but they remain
   *only because MUST-1 closed the policy*, and MUST-1 is an infrastructure change that a later
   misconfiguration can undo. That is what SHOULD-25's CI guard on the public-access-block exists for.
3. **Copies on tester devices are unreachable.** `BurnStore.swift:982` writes files to each device's
   Application Support or a user-chosen folder (1.10). Every burn a TestFlight tester performed is a
   local copy that **no S3 deletion touches**. There is no expiry, no remote invalidation, and no
   server-side record of what any device burned. The only lever is the one in MUST-0d: **suspend the
   TestFlight builds and tell testers what to delete** (§6.9 drafts that message). Even then compliance
   is voluntary. This is the clearest illustration of why "close the bucket" is not the end of the
   matter.

### Adjacent exposures to log separately

- **Demucs stems are derivative works** under §106(2). Every stem derived from one of the 369 captures is
  an unlicensed derivative of an unlicensed copy, publicly served.
- **Lyrics reach publishers**, not labels — a distinct rightsholder population with its own posture, and
  with two distinct provenance classes (2.5).
- **Pre-1972 vinyl gets no safe harbor.** §1401 (CLASSICS Act, Title II of the MMA) pulled pre-1972
  recordings into the §114 regime. A 1968 vinyl rip streamed through hear mode is in the same posture as
  a 2024 release.
- **§1201 is genuinely uncertain and does not matter much.** Capturing decrypted output from Music.app on
  a licensed device is the classic analog hole and is arguably not circumvention of FairPlay at all; no
  controlling authority squarely decides output capture. But the trend is adverse, and **§106(1)
  liability does not depend on §1201 either way**.

---

## 5. Territory: this analysis is U.S. law, and the App Store is not

**This is the largest structural omission in the earlier draft after Pillar 0.** Every case cited in
§§1–4 is a U.S. case; every statute is Title 17. The App Store ships to ~175 storefronts by default.
Several of this document's load-bearing conclusions **reverse** outside the United States — not soften,
reverse — and at least one piece of drafted compliance copy is **actively misleading** to a non-US user.

### 5.1 The summary table

| Conclusion in §§1–4 | Basis | Outside the U.S. |
|---|---|---|
| Room-speakers playback implicates only the **musical work**; labels are not in the room | §114(a) — no general public performance right in sound recordings | **False.** UK/EU/AU/CA give the **recording** a full public performance right. The labels *are* in the room, via a second collecting society. §5.2 |
| Decision B1: request-only jukebox is "legally free" — **nothing copyrightable is performed** | §114(a) + titles aren't copyrightable | **Materially weaker.** The room performance is licensable in most of the world and requires a *second* licence. §5.2 |
| My Digital space-shifting is "the defensible middle" | *Sony*, *Diamond*, fair use | **No statutory basis in the UK at all.** No fair use; the private-copying exception was **quashed in 2015**. §5.3 |
| Pillar 2: facts about recordings aren't copyrightable, so a metadata catalog is safe | 37 C.F.R. §202.1(a), *Feist* | **Does not travel intact.** The EU/UK *sui generis* database right protects the **compilation** regardless of the facts. §5.4 |
| Stem separation is a §106(2) derivative-work question | Title 17 economic rights | **Adds a non-economic claim.** Moral rights (integrity) are personal, often inalienable, and directly implicated. §5.5 |
| Privacy is unmentioned | — | **GDPR/UK GDPR apply** to guest requests, broker IP logs, and CloudKit profiles. §5.6 |

### 5.2 Public performance: the sound recording right exists everywhere else

§114(a) is a genuine U.S. peculiarity — the product of a 1971 compromise that gave sound recordings a
reproduction right but withheld a general public performance right. Almost nowhere else did that.
Under the **Rome Convention** (Art. 12) and **WPPT** (Art. 15), most countries provide performers and
phonogram producers a right to equitable remuneration for public performance and broadcasting.

Practically this means a venue outside the U.S. needs **two** licences, not one:

| Territory | Musical work (composition) | **Sound recording** |
|---|---|---|
| **UK** | PRS for Music | **PPL** — usually together as *TheMusicLicence* from PPL PRS Ltd |
| **Germany** | GEMA | **GVL** |
| **France** | SACEM | **SCPP / SPPF** (via SPRE for equitable remuneration) |
| **Netherlands** | Buma | **Sena** |
| **Italy** | SIAE | **SCF** |
| **Spain** | SGAE | **AGEDI / AIE** |
| **Australia** | APRA AMCOS | **PPCA** |
| **Canada** | SOCAN | **Re:Sound** |
| **Japan** | JASRAC | **RIAJ** members / CPRA |

Three consequences for this document:

1. **§3.1's parenthetical is US-only** and is now labelled as such.
2. **Decision B1's "nothing copyrightable is performed, transmitted, or reproduced to them" is a U.S.
   sentence.** The recommendation (request-only) is still right everywhere — it is *more* right outside
   the U.S., because hosted audio would trigger both rights rather than one — but the *reason* given must
   not be repeated abroad. B1 has been rewritten accordingly.
3. **§6.3 and EULA §4.5 as drafted name only ASCAP, BMI, SESAC, and GMR.** A host in Manchester reading
   that notice is told to get a licence from four American organisations, none of which can licence
   their event, and is told nothing about PPL PRS — whom they actually need. **That is not merely
   incomplete, it is affirmatively misleading, and it is presented as compliance copy.** Fixed in §6.3
   with a territory-aware notice.

### 5.3 Private copying and space-shifting: no fair use, and in the UK, no exception at all

The *My Digital* tier's entire story is "personal files, personal library, plausible space-shifting."
That story is U.S.-shaped.

- **The UK has no fair use.** It has *fair dealing*, a closed list of enumerated purposes (research and
  private study, criticism/review, quotation, parody, news reporting — CDPA ss.29–30A). **Personal
  space-shifting is not on the list.**
- **The UK private-copying exception was quashed.** s.28B CDPA (personal copies for private use) was
  introduced in 2014 and **struck down in 2015** in *R (British Academy of Songwriters, Composers and
  Authors) v Secretary of State for Business, Innovation and Skills* [2015] EWHC 1723 (Admin), with the
  quashing order in [2015] EWHC 2041 (Admin) — because the government introduced it without the fair
  compensation the InfoSoc Directive requires. **It was never reinstated.** Format-shifting a CD you own
  to MP3 is, formally, infringement in the UK today.
- **EU private-copying exceptions are levy-conditioned and narrower than they look.** InfoSoc Art.
  5(2)(b) permits private copying only where rightsholders receive *fair compensation*, typically via
  hardware levies — and it does not reach redistribution. *VCAST v RTI* (C-265/16, 2017) is directly on
  point and adverse: a cloud service that recorded broadcasts for individual users was held to require
  the rightsholders' authorisation, notwithstanding the private-copy exception, because the service
  performed a separate act of communication to the public. **That is the closest European analogue to
  PocketDJ's architecture, and it lost.**
- **Germany** permits private copies (UrhG §53) but not from an obviously unlawful source, and not for
  distribution.

**Implication:** the "keep the source, fix the destination + attest" disposition for My Digital is sound
U.S. policy and is *not* a legal safe harbour in the UK or much of the EU. It remains the right product
decision. It should not be described to users, or to counsel, as legally settled outside the U.S.

### 5.4 The metadata catalog: the EU database right

Pillar 2 rests on *Feist*-style reasoning: the individual data points are facts, facts aren't
copyrightable, therefore the catalog is safe. The EU and UK have a **second, independent** right that
does not care about that argument.

**Directive 96/9/EC** creates a *sui generis* database right for a maker who makes a substantial
investment in **obtaining, verifying, or presenting** the contents. It is infringed by extraction or
re-utilisation of a substantial part, or by repeated extraction of insubstantial parts. It is
independent of copyright and survives even where every element is an unprotectable fact.

Two refinements that matter here, both from the CJEU:

- *British Horseracing Board v William Hill* (C-203/02) held that investment in **creating** the data
  does not count — only investment in *obtaining* pre-existing data. This is the limitation most likely
  to help PocketDJ: much of the catalog's value is analysis PocketDJ *created* (BPM, key, beat grid,
  sentiment), not data it obtained.
- *Football Dataco v Yahoo!* (C-604/10) restricted copyright in fixture lists, but the sui generis
  analysis runs separately, and European litigation over setlist/tracklist databases has repeatedly
  turned on it.

**The consequence is symmetric and worth understanding in both directions:** PocketDJ may *hold* a
database right in its own analysis (an asset), and PocketDJ may *infringe* one by bulk-ingesting a third
party's compilation. The concrete exposure is on the ingest side — the iTunes/MusicKit catalog crawl and
the Discogs image/metadata retrieval are exactly the "repeated extraction of insubstantial parts"
pattern the directive targets, and Discogs's own terms sit on top of it (§2.7(a)). "1001Tracklists does
it" is a U.S.-law observation about a U.S.-facing site and does not answer the European question.

### 5.5 Moral rights and stem separation

Civil-law jurisdictions grant authors and performers **moral rights** that have no general U.S. analogue
for music (VARA covers visual art only). The relevant one is the **right of integrity** — to object to
distortion, mutilation, or other modification prejudicial to honour or reputation. Berne Art. 6bis;
UK CDPA s.80; France CPI Art. L121-1 (perpetual, inalienable, imprescriptible); Germany UrhG §14.

PocketDJ's Producer and Mix features are unusually exposed here compared to a plain music player:

- **Demucs stem separation** decomposes a finished recording into isolated parts — the paradigm case of
  modifying a work into something its author did not sanction.
- **The 16-step sequencer, slicing to pads, and remix loops** recombine those parts.
- **Time-stretch and per-step retargeting** alter the performance itself.

Three mitigating facts, and they are real: these features operate on the user's own copy; output is
local; and in France/Germany the right belongs to the *author* and is asserted rarely against private
use. The exposure is not in the feature — it is in **distribution**, which is precisely what the public
stems corpus (2.4) creates. Isolated acapellas of identifiable performers, publicly fetchable, is the
configuration most likely to attract an integrity claim in a civil-law forum, and it is the one that
exists today.

Unlike an economic right, a moral right frequently **cannot be waived by a EULA** in these
jurisdictions. So nothing in §6.7 fixes it. Unpublishing the stems does.

### 5.6 GDPR / UK GDPR / DSA

Nothing in the earlier draft mentioned privacy, and the App Store requires a privacy policy URL
regardless (§6.8). Personal data is being processed today:

| Data | Where | Issue |
|---|---|---|
| Guest song requests (free text, submitted from arbitrary phones) | `jukebox-server.mjs`, guest page | Personal data when tied to a session/device; free text can contain anything a guest types |
| **IP addresses reaching an unauthenticated broker** | jukebox server logs | IP is personal data under GDPR (*Breyer*, C-582/14). An unauthenticated endpoint collecting them has no identified lawful basis, no notice, and no retention policy |
| Profile data, play history, favorites | CloudKit private DB (`CloudSyncService.swift:160`) | Apple is a processor; PocketDJ is controller for what it defines. Needs a lawful basis and a retention story |
| Session ids shared off-device | `ShareLink` (`JukeboxView.swift:145-154`) | A 40-bit bearer capability forwarded off-platform |

Minimum obligations if any EU/UK user is in scope: a lawful basis (legitimate interests is available for
the jukebox but must be documented and balanced); **Art. 13/14 transparency** at the point of collection
— i.e. one line on the guest page, which today says nothing; data minimisation and a **retention
period** for requests and logs (today: unbounded, and `timeless` sessions never expire — 3.2); Art. 30
records of processing; and an international-transfer basis, since the data lands in a US-hosted AWS
account.

**DSA** becomes relevant only if the product turns multi-sided (user-to-user content at scale) —
trader identification and notice-and-action would then attach. Not today; worth knowing before Discover
becomes social.

### 5.7 The cheapest mitigation is territorial, and it was never proposed

**Limit initial App Store availability to the United States.**

App Store Connect makes territory a per-app setting; restricting it is a checkbox, reversible, and
takes minutes. It buys, in one move:

- Every sentence of §6's copy becomes accurate for its actual audience. The PRO notice names the right
  organisations. The space-shifting framing sits in the one jurisdiction with *Sony* and *Diamond*.
- §5.2–5.5 stop being live problems and become *pre-expansion* problems.
- GDPR/UK GDPR scope narrows sharply (not to zero — a US-only storefront does not guarantee no EU data
  subjects — but the risk profile changes materially).
- The database-right and moral-rights questions can be answered before they are exposures rather than
  after.

The cost is real but small at this stage: you cannot beta abroad. Given that the beta is currently a
handful of testers and the recommendation in Decision E is to ship single-user, **that cost is close to
zero and the benefit is that §6 stops being wrong for most of the planet.** This is now Decision F, and
it is recommended.

---

## 6. The copy

**Precondition, stated once and meant literally: none of this may ship before the §7 MUST items.**
Copy that describes a system you have not built is worse than silence — it converts an architecture
problem into an evidence problem.

**Second precondition, new in this revision: the copy that is ALREADY shipped is not covered by that
sentence.** There are live TestFlight builds carrying the current strings — including
`BrowseDiscover.swift:144` ("added songs are ripped to the shared catalog") and
`OnboardingView.swift:277` ("Without it, songs still play through the rip server"). The precondition
governs *future* copy. The already-distributed copy is handled by MUST-0d (suspend the builds), not by
this section. See §6.9.

### 6.0 Four blockers before any of this can ship

These are hard blockers, not drafting notes. Every one is unresolved today.

| # | Blocker | Status | Owner action |
|---|---|---|---|
| **1** | **`pocketdj.app` ownership is not established.** DNS resolves to `216.150.1.1`, a domain-parking address; the registrar WHOIS for the `.app` TLD returned no registration record for it. **Assume you do not own it.** | **Blocking** | Register the domain (or choose one you own) before any address in this document is published |
| **2** | **`abuse@pocketdj.app` does not exist.** | **Blocking** | Create the mailbox; it must be monitored |
| **3** | **`dmca@pocketdj.app` does not exist — and a DMCA agent registration (MUST-12) requires a working address before filing.** The Copyright Office registration takes a real, deliverable contact. | **Blocking MUST-12** | Create the mailbox first, then file |
| **4** | **`[Full attributions →]` is an unresolved placeholder** with no target screen or file. | **Blocking §6.6** | Build the attributions screen (GeneralUser GS + any recorded `artLicense` values from SHOULD-24) |

Every `[bracketed]` string below is a placeholder that must be resolved, not shipped. **Do not publish
any of §6 with a placeholder in it** — an unmonitored or non-existent abuse address is worse than no
address, because §512(i) conditions safe harbour on a policy that is actually *implemented*, and a
bounced notice is affirmative evidence it is not.

### 6.0.1 A note on voice: the single-user vacuousness problem

Several drafted strings are written in multi-user voice about a product that has exactly one human:

- EULA §4.2: *"PocketDJ does not serve your copies to anyone else."*
- App Store: *"Your library is yours — it isn't shared with other users."*
- About: *"PocketDJ doesn't share your audio with other people."*

In a one-user product these are **vacuously true** — there is no one else — while reading as claims
about a multi-tenant system with per-user isolation that **does not exist** (1.9: there is no user).
The earlier draft diagnosed this in Decision E and then shipped the strings anyway. That is the gap.

**Resolution, applied throughout §6: vacuous truth is not acceptable copy.** A statement that is true
only because its subject is empty is the kind of statement that reads as a lie the moment the subject
is populated — and Decision E's whole plan is to populate it later. Two failure modes, both real: a
reviewer or user reasonably infers a multi-tenant guarantee that isn't built; and the sentence silently
becomes false on the day the second user arrives, with no code change to trigger a copy review.

The fix is to **make claims about what the app does, not about what it does not do to other users**:

| Vacuous (cut) | Non-vacuous replacement |
|---|---|
| "It isn't shared with other users" | "Your library lives in your own storage and on your devices." |
| "PocketDJ does not serve your copies to anyone else" | "PocketDJ serves your copies back to you, over an authenticated connection. It has no feature for distributing them to other people." |
| "PocketDJ doesn't share your audio with other people" | "PocketDJ has no feature that publishes your audio. Sharing is limited to tracklists and playlists." |

Each replacement is a statement about implemented behaviour, verifiable in code after MUST-1, and it
stays true when a second user appears. This rewrite is applied in 6.6, 6.7, and 6.10 below.

### 6.1 Vocabulary: the "rip" / "burn" question — and which reader it is for

**Register: [REVIEW], primarily.** This matters because the earlier draft merged two audiences in one
sentence and drew a conclusion that only holds for one of them.

The market answer on the word itself is unambiguous and adverse. rekordbox's EULA §2.2(f) — the
market-leading DJ product, i.e. the ambient legal vocabulary of this exact category — enumerates
**"rip"**, in scare quotes, as *prohibited conduct*:

> "You will not copy, reproduce, redistribute, **'rip'**, record, perform, frame, link to or display to
> the public, broadcast or make available to the public…"

Within DJ software, "rip" is not neutral audio-culture slang. It is the industry's own term of art for
the infringing act. The DJ-culture heritage argument does not survive contact with the actual documents.

**But the two readers respond to the rename completely differently, and the earlier draft's sentence —
"An App Review reader or a rights-holder's counsel … will read your Rip button as the product naming its
own violation" — flattened them into one.** They are opposites:

| | **App Review** | **Rights-holder's counsel** |
|---|---|---|
| What the word does | Pattern-match → possible rejection | Corroborates conduct they will prove from infrastructure and repo history |
| What the rename does | **Fixes it entirely.** The string is the problem; change the string, problem gone | **Nothing.** They are not proving the conduct from your button label |
| Worse: what the rename *can* do | — | **A rename that post-dates a written internal risk assessment can read as concealment**, not remediation — especially with git timestamps showing the sequence |

That last row is the reason for a sequencing rule the earlier draft did not state, and which its own
*Grokster* reasoning demands. §1 correctly says internal docs and feature naming are evidence. It
follows that renaming the button **while the capture conduct is still present in the repo changes the
label, not the act** — and does so on a timeline that is permanently visible in version control.

**Sequencing rule: the rename ships strictly AFTER MUST-3, MUST-4, MUST-5, MUST-5b, and MUST-6.**

Rename after the capability is gone and the record reads: *removed the capture paths, deleted the
corpus, then updated the vocabulary to match the product.* Rename before, and the same commits read:
*wrote an internal assessment, renamed the buttons, kept capturing.* The engineering cost of the
ordering is zero. The evidentiary difference is not.

**`burn` is weaker but should also go.** It has legitimate CD heritage, but PocketDJ does not burn
discs — it caches audio. "Burn" appears in no shipping competitor's copy, and its meaning to a reviewer
is *make an unauthorized copy*.

The replacement vocabulary comes from the same EULA, §5.1(c): content is **"imported or uploaded into
the Program by users."** Every product surveyed uses *import, upload, add to your collection, catalog,
showcase, sync, available offline, your library, your profile, listening history, tracklist*. None uses
*rip*, *burn*, *capture*, *grab*, or unqualified *share*.

**Rename table — every user-visible string found in the audit:**

| Current string | `file:line` | Replacement |
|---|---|---|
| `Label("Rip \(noun)", systemImage: "arrow.down.circle")` | `CollectionRipBurn.swift:35` | **"Add to your library"** |
| `Label("Burn \(noun)", systemImage: "flame")` | `CollectionRipBurn.swift:41` | **"Download for offline"** — and change the **flame** icon to `arrow.down.circle.fill`; a flame is the CD-burning metaphor and reads as *destroy/copy*, not *save*. |
| `"\(r.notRipped) not yet ripped"` | `CollectionRipBurn.swift:341` | **"not in your library yet"** |
| `"\(r.ready) already ripped"` | `CollectionRipBurn.swift:133` | **"\(r.ready) already in your library"** |
| `"Nothing to rip."` | `CollectionRipBurn.swift:137` | **"Everything's already in your library."** |
| `"Ripped \(total) of \(total)"` | `CollectionRipBurn.swift:193,202` | **"Added \(total) of \(total)"** |
| `"Burned \(r.burned) of \(r.total)"` | `CollectionRipBurn.swift:338` | **"Downloaded \(r.burned) of \(r.total)"** |
| `"Couldn't write to the burnt-music folder"` | `CollectionRipBurn.swift:336` | **"Couldn't write to your offline library folder"** |
| `"Play from burned files"` | `PlaybackModeToggle.swift:36` | **"Play from downloads"** |
| `"Burnt music"` / `"Burnt music counts everything a burn downloads…"` | `StorageView.swift:140,156` | **"Offline library"** / **"Your offline library counts everything a download includes…"** |
| `"Rip server URL"` / `"Rip server"` | `SettingsView.swift:465,491` | **"Import server"** |
| `"Rip from cloud source"` | `SettingsView.swift:475` | **Delete the feature** (§7 MUST-4) |
| `"Search Apple Music — added songs are ripped to the shared catalog."` | `BrowseDiscover.swift:144` | **Delete the capture affordance** (§7 MUST-3) |
| `"Guests can play along on their phones (ripped tracks)."` | `JukeboxView.swift:181` | **Delete or gate** (§7 MUST-10 / Decision C) |
| `"The digitized vinyl catalog — every ripped record."` | `OnboardingView.swift:338` | **"Your vinyl, digitized — every record you've imported."** |
| `"The digital library — pre-ripped, streams and burns with no rip step."` | `OnboardingView.swift:341` | **"Your digital files — already in your library, ready to play offline."** |
| `"Without it, songs still play through the rip server"` | `OnboardingView.swift:277` | **Delete** — this sentence describes serving the shared corpus to subscription-less testers as the designed fallback (Decision E). It must go with MUST-11. |

Internal identifiers (`/rip`, `RipsStore`, `com.levi.pocketdj.burn-drain`, accessibility ids like
`collection-rip`) may lag — they are not user-visible and the a11y ids are load-bearing for tests.
**Any string a user or a reviewer can see should change before submission.**

---

### 6.2 First-run rights attestation

**Placement:** a fourth onboarding stage between `.appleMusic` and `.sources`
(`OnboardingView.swift:27-29`). Continue is **disabled** until both boxes are checked. There is **no
attestation of any kind in the app today** — this is net-new.

> ### Your music, your rights
>
> PocketDJ organizes and plays music you already have. It doesn't sell you music and it doesn't
> license music on your behalf.
>
> Before you import anything, please confirm:
>
> ☐ **I own or have permission to use the music I import into PocketDJ.** Records I own, files I
> bought, or recordings I made myself.
>
> ☐ **I'm responsible for the licences my events need.** If I play music where the public can hear it
> — a bar, a club, a ticketed party — the venue or I need a public-performance licence from the
> relevant rights organisations.
>
> Streaming subscriptions like Apple Music let you *listen*. They don't let you keep a copy or play to
> a crowd. PocketDJ won't import from them.
>
> [ Continue ]

*Drafting notes.* "Own or have permission" is the disjunctive DistroKid and SoundCloud both use — it is
broader and more honest than "I own this," which is false for every lawful purchaser (you own the object,
not the copyright). The last paragraph is the single most common user misconception, and VirtualDJ
addresses it head-on; it is also the sentence that will make the code true once §7 MUST-3/4 ship.

---

### 6.3 Contextual notices — one line per real trigger

Enumerated from the audit. Each is a one-line footnote at the point of action, not a modal. **Rows 9 and
10 previously forwarded to other sections instead of supplying text; a designer could not paste them.
They now contain the actual copy.**

| # | Trigger | Where | Copy |
|---|---|---|---|
| 1 | Collection **Add to your library** | `CollectionRipBurn.swift:35` | *Imports from your own records and files. Songs you don't have rights to won't import.* |
| 2 | Collection **Download for offline** | `CollectionRipBurn.swift:41` | *Saves your own copies to this device for offline play.* |
| 3 | Single-song import (play/download choke point) | `RipsStore.swift:419,642,684` | *Imported from your library — this copy is yours and stays yours.* |
| 4 | **My Digital** ingest | `index-digital-files.mjs` / `POST /ingest-digital` | *Only add files you own or bought. PocketDJ can't check this for you — you're confirming it by importing.* |
| 5 | **Vinyl** capture (analog) | `runAnalogJob`, `rip-server.mjs:807` | *Recording a record you own, for your own use. The audio stays in your library.* |
| 6 | **Stemify** (per-song) | Song detail ▸ Stemify | *Separates stems from your own copy, in your own library. Stems stay on your devices and in your own storage.* |
| 7 | **Stemify collection** | `/stemify-collection` | *Separates stems for every song in this collection. Stems stay on your devices and in your own storage.* |
| 8 | **Demux ▸ Import an audio file** | Producer ▸ Demuxer | *Import audio you own or made. Don't import files you don't have rights to.* |
| 9 | **Jukebox — start a session** | `JukeboxView.swift` | *Guests see what's playing and send requests. The music comes from your speakers — PocketDJ doesn't send audio to their phones. Playing where the public can hear needs a licence; see the note before you start.* → full gate at §6.4 |
| 10 | **Jukebox — View + Hear** toggle | `JukeboxView.swift:175-186` | **Recommended: remove (Decision C).** If retained: *Sending audio to your guests' phones is a broadcast. It needs licences PocketDJ doesn't provide and can't get for you — an on-demand service like this can't be covered by the statutory webcasting licence at any price. Leave this off unless you hold direct licences from the rights holders.* |
| 11 | **Collection export** (`.pdjcollection`) | Collection ▸ Export | *Shares the tracklist, not the audio. Whoever opens it plays from their own library.* — **verified: `PocketZip.swift:94-105`, `PlaylistZip.swift:115-138`; the zip carries `pocket.json` + `items.json` metadata only (2.8).** |
| 12 | **Discover ＋ Add** | `BrowseDiscover.swift` | **Removed** (§7 MUST-3). Replaced by: *Opens in Apple Music.* |

---

### 6.4 Jukebox / session host notice

**Placement:** on session creation, as a gate — not boilerplate. Modeled on VirtualDJ (the most explicit
in the industry) and mubo (the closest analog product). The gate itself is the point: a product that
affirmatively asks "is this event licensed?" is building the opposite record from one that advertises a
radio station.

**Territory-aware, per §5.2.** The earlier draft named only the four U.S. PROs. Shipped as written to a
UK or German host, it would be affirmatively misleading. The organisation names must be selected from
the device's storefront region, with the U.S. list as fallback.

> ### Starting a jukebox
>
> Your guests scan a code, see what's playing, and send you requests. **You** decide what plays. The
> music comes out of your speakers — PocketDJ doesn't send audio to your guests' phones.
>
> **About licences.** PocketDJ doesn't license music — it controls what music plays. If you're playing
> where the public can hear it, that performance needs a public-performance licence, usually held by the
> venue.
>
> *[Region: US]* In the United States that means a licence covering the songwriting, from **ASCAP, BMI,
> SESAC, or GMR**.
> *[Region: UK]* In the UK you need **TheMusicLicence** from PPL PRS — it covers both the songwriting
> (PRS) and the recording (PPL). **Both are required**, and a songwriting licence alone is not enough.
> *[Region: EU/other]* Most countries outside the United States require **two** licences — one for the
> songwriting and a separate one for the recording (for example GEMA + GVL in Germany, SACEM + SCPP in
> France, APRA AMCOS + PPCA in Australia, SOCAN + Re:Sound in Canada). Check what your country requires.
>
> A private party for your own friends and family generally doesn't need one. A bar, club, ticketed
> event, or corporate party generally does — even if it's invitation-only. If you're being paid to DJ,
> confirm the venue's licence in writing before the gig.
>
> A streaming subscription is not a performance licence.
>
> ☐ **This event is a private gathering, or the venue holds the licences it needs.**
>
> [ Start jukebox ]

*Drafting notes.* "You and/or your venue" is VirtualDJ's phrasing and is legally accurate about joint
responsibility — it avoids falsely promising the venue covers the DJ. It matters that this is honest:
BMI's own guidance says the licence goes to the establishment, but *Shapiro, Bernstein v. H.L. Green*,
316 F.2d 304 (2d Cir. 1963) and *Gershwin v. Columbia Artists*, 443 F.2d 1159 (2d Cir. 1971) mean a DJ
performing at an unlicensed venue is a direct infringer; the PROs simply find it more efficient to sue
the establishment. Telling users "get your own licence" would *also* be bad advice — the PROs generally
won't sell to a DJ who isn't promoting the event.

"Even if it's invitation-only" is doing deliberate work: H.R. Rep. No. 94-1476 at 64 names **clubs and
lodges** as semipublic and therefore public, so a members-only club or a fraternity party is on the wrong
side no matter who was invited.

**The two-licence point for non-US regions is not padding.** It is the single most common compliance
error for a DJ outside the U.S., precisely because U.S.-authored software (including, until this
revision, this document) tells them there is one licence to get.

---

### 6.5 Public catalog page notice

**Placement:** footer of every public surface — jukebox guest page (`template.html`), public profile,
Discover, any shared collection view.

**Unverified-placement warning.** This footer is specified for "public profile, Discover, any shared
collection view," but **no finding in this document establishes what those CloudKit-backed surfaces
actually expose.** The audit examined the jukebox guest page in detail and did not audit the profile or
Discover surfaces. Before this footer ships on them, SHOULD-27 requires an audit answering: what fields
leave the device, which are world-readable vs. shared-with-known-users, whether any audio key or URL
appears in a public CloudKit record type, and whether Discover exposes other users' libraries. **Do not
place a footer describing a surface's contents on a surface whose contents are unaudited** — that is how
accurate-sounding copy becomes a misrepresentation.

> **This is a listening history, not a library.**
>
> You're looking at what someone played and how they built the set — titles, artists, keys, tempos, and
> the order they went in. PocketDJ doesn't share the audio. If you want to hear something here, look it
> up on your own music service.
>
> Titles, artists, and tempos are facts about recordings, not the recordings themselves. Artwork is shown
> under the terms of its source and remains the property of its owners. Nothing here is licensed for
> redistribution.
>
> Something on this page shouldn't be? Write to **[abuse@pocketdj.app — BLOCKER 2]** and it comes down.

*Drafting notes.* "Listening history," not "library" or "catalog," is Last.fm's framing and is the
difference between publishing facts about a person and publishing an index of copies. "Look it up on
your own music service" is Apple Music's own resolution model — a follower who wants the music taps ＋Add
and gets it from their own subscription — which is both the safest posture and the one most legible to an
Apple reviewer, because it is Apple's.

The abuse contact is not decoration. §512(i) conditions **all** safe harbors on a repeat-infringer
policy, and §512(c)(2) requires an agent registered with the Copyright Office. Both are currently at
zero, and both are the cheapest items on the entire remediation list — **but see Blocker 1/2: the
address must exist and be monitored before it is published.**

---

### 6.6 Settings ▸ About / Legal

> ### About PocketDJ
>
> PocketDJ is a personal music library and DJ tool. It organizes music you already have — records you've
> digitized, files you own, and your Apple Music library — and gives you a catalog, playlists, a mixer,
> and a request line for parties.
>
> **What PocketDJ does with your music**
> Music you import stays yours. Your copies live in your own storage and on your devices, and PocketDJ
> streams them back to you over an authenticated connection. PocketDJ has no feature that publishes your
> audio or distributes it to other people.
>
> **What PocketDJ doesn't do**
> PocketDJ doesn't sell or license music. It doesn't copy from streaming services — Apple Music tracks
> play through Apple Music, using your own subscription, and are never captured or stored. It doesn't
> give you the right to play music in public.
>
> **What you're responsible for**
> Having the rights to the music you import, and having the licences your events need. You take sole
> responsibility for determining, obtaining, and complying with any third-party terms that apply to
> music you bring into PocketDJ.
>
> **Copyright**
> PocketDJ respects copyright. If you believe something made available through PocketDJ infringes your
> rights, contact our designated agent at **[dmca@pocketdj.app — BLOCKER 3]**. We terminate accounts of
> repeat infringers.
>
> **Privacy**
> See our Privacy Policy at **[https://pocketdj.app/privacy — BLOCKER 1]**.
>
> **Third-party content and licences**
> Apple Music playback is provided through MusicKit under Apple's Media Services Terms. Instrument
> sounds include GeneralUser GS by S. Christian Collins, used under its licence.
> **[Full attributions → — BLOCKER 4: screen does not exist]**

*Drafting note.* "Determining, obtaining, and complying" is rekordbox's triad (§2.4) and shipping counsel
uses it because it covers three distinct users: the one who never looked, the one who looked and didn't
buy the licence, and the one who bought the wrong one.

**Every sentence in "What PocketDJ doesn't do" is false today.** It becomes true on MUST-1 through
MUST-6. That is exactly why the copy ships after the code.

**The "What PocketDJ does with your music" paragraph has been rewritten per §6.0.1** — the earlier
"doesn't share your audio with other people and doesn't serve one person's copy to anyone else" was
vacuously true of a one-user product and implied a per-user isolation guarantee that 1.9 shows does not
exist.

---

### 6.7 The fail-closed error string — the most user-visible new string in the release

**This was never drafted and belongs in the code, not just the copy deck.** MUST-5 makes capture fail
closed for Apple Music songs. That error is what a user sees **the first time a song they expect to play
stops playing** — which, for a tester with 277 Apple Music objects, is a routine event, not an edge case.
An unhandled or generic failure here ("Rip failed", "Something went wrong") is the single most likely
cause of a bug report that reads as a regression rather than as intended behaviour.

**Placement:** returned by `rip-server.mjs:800` as a structured error, surfaced by `RipsStore` at the
three call sites (`:419`, `:642`, `:684`) and by the collection batch (`:887`).

> ### This song plays through Apple Music
>
> **[Song title]** comes from your Apple Music library, so PocketDJ plays it through Apple Music using
> your own subscription. It can't be added to your offline library — a subscription lets you listen, not
> keep a copy.
>
> Songs you can add offline: records you've digitized and files you own.
>
> [ Play in PocketDJ ]   [ Learn more ]

Server-side shape (so the client can branch rather than string-match):

```json
{ "error": "capture-not-eligible",
  "sourceName": "Apple Music (Local)",
  "playable": true,
  "message": "Plays through Apple Music; not eligible for offline import." }
```

`"playable": true` is the load-bearing field: the song still **plays**, it just doesn't **download**.
Copy and UI must not imply the track is broken or missing.

**Batch variant** (collection add, `CollectionRipBurn.swift`):

> **Added 41 of 63.** 22 songs play through Apple Music and can't be added offline — they'll still play
> normally.

---

### 6.8 Migration copy — the 369 deletions

**Also never drafted, and it is the other moment a tester notices something changed.** MUST-6 deletes
369 objects that existing testers can currently play, and that some have already burned locally (1.10).
§6.3 covers new-import moments only; nothing tells an existing user why their library shrank.

**Placement:** one-time in-app notice on first launch after the migration build, plus the TestFlight
"What to Test" note.

> ### Some songs moved back to Apple Music
>
> PocketDJ used to keep offline copies of songs from your Apple Music library. It shouldn't have — a
> subscription lets you listen, not keep a copy — so we've removed them.
>
> **What changed:** 369 songs no longer have an offline copy. They still appear in your catalog, and they
> still play, through Apple Music with your own subscription.
>
> **What didn't:** everything you digitized from vinyl and every file you imported yourself is
> untouched.
>
> If you downloaded any of those songs to a device, please delete them — they were never ours to give
> you. **[Show me how]**
>
> [ OK ]

*Drafting notes.* Three deliberate choices. **"It shouldn't have"** is a plain admission; hedging here
("to improve compliance") reads worse to every audience and is the kind of sentence caveat (d) turns
into an exhibit. **"They still play"** is the fact that prevents this reading as a feature removal.
**The delete request** is the only lever that reaches copies already on devices (§4, "What deletion does
not reach") — it is voluntary, it will be partially ignored, and asking is still materially better than
not asking, both practically and evidentially.

**This notice must not ship before MUST-6 completes**, or it describes a deletion that hasn't happened.

---

### 6.9 TestFlight tester notice — the already-distributed copy

MUST-0d suspends the current builds. Testers need to be told why, and this is also the message that
carries the delete request to the devices S3 deletion cannot reach.

> **PocketDJ beta — paused**
>
> I've paused the beta while I fix how PocketDJ stores and serves music. The current build keeps offline
> copies of Apple Music tracks and serves audio from shared storage — both are wrong, and I'm rebuilding
> that part before the beta continues.
>
> **Please do two things:**
> 1. Stop using the current build.
> 2. If you downloaded music to your device through PocketDJ, please delete it. Settings ▸ Storage ▸
>    Delete all offline music removes everything in one step.
>
> Nothing you created — playlists, pockets, mixes, recordings — is affected, and none of it is going
> away. I'll send a new build when the storage rebuild is done.
>
> Thanks for testing, and sorry for the interruption.

*Drafting note.* This is written to be true and unembarrassing if it is later read by someone adverse.
It does not characterise the conduct legally, it does not speculate, and it does not minimise. It is
also the reason MUST-0d is a **MUST**: an unsuspended beta continues distributing the corpus while the
remediation is in flight, which converts every additional tester into another multi-user distribution
fact (Decision E).

---

### 6.10 EULA

**The earlier draft's §5.6 was one section — Acceptable Use — presented as "the EULA." It is not a
EULA.** Shipping it alone means shipping **Apple's standard EULA plus a conflicting custom section**,
which is the worst of both: Apple's default terms govern, your section may contradict them, and none of
the protections a developer actually needs are present.

Apple permits a custom EULA but requires it to include, at minimum, the terms in the **Apple Developer
Program License Agreement, Schedule 1 / "Instructions for Minimum Terms of Developer's End-User Licence
Agreement."** A custom EULA missing them is non-compliant.

**What was missing and is drafted below:** warranty disclaimer (§5), limitation of liability (§6),
termination (§7), governing law and venue (§8), dispute resolution (§9), and **all** of Apple's mandatory
minimum terms (§10) — including the third-party-beneficiary clause, which is the one Apple checks for.

**Counsel must review this before it ships.** The clauses below are structurally correct and drafted in
real language, but enforceability of a liability cap, an arbitration clause, and a class-action waiver
is jurisdiction-specific, and consumer-protection law in the EU/UK restricts several of them (a
consumer's statutory rights cannot be excluded, and the arbitration/venue clauses in §§8–9 are likely
unenforceable against EU/UK consumers — another argument for Decision F, US-only).

> ## PocketDJ End User Licence Agreement
>
> **1. This agreement.** This is an agreement between you and **[LEGAL ENTITY NAME — see Q18]**
> ("PocketDJ", "we"). It is **not** an agreement with Apple. By downloading or using PocketDJ you accept
> it. If you don't accept it, don't use the app.
>
> **2. Licence.** We grant you a personal, non-transferable, non-exclusive licence to use PocketDJ on
> Apple-branded devices you own or control, as permitted by the App Store Terms of Service. You may not
> copy (except as this licence allows), reverse-engineer, decompile, modify, rent, lease, lend, sell,
> redistribute, or sublicense the app, except where that restriction is prohibited by applicable law.
>
> **3. Your account and your data.** You are responsible for your device, your storage, and the security
> of any credentials. You keep ownership of everything you import.
>
> ## 4. Acceptable use
>
> **4.1 Your music.** You keep ownership of everything you import into PocketDJ. You represent that you
> have all necessary rights to the music you import and to make it available through the app. You take
> sole responsibility for determining, obtaining, and complying with all third-party terms that apply to
> that music. PocketDJ excludes, to the fullest extent permitted by law, all liability arising from
> content imported into the app by users, including claims for infringement of intellectual property
> rights.
>
> **4.2 Your copies.** Music you import is stored in your own storage and on your devices, and PocketDJ
> makes it available to you over an authenticated connection. PocketDJ has no feature for distributing
> your copies to other people, and you may not use PocketDJ to distribute music to other people.
>
> **4.3 Streaming services.** Apple Music and similar services licence you to listen, not to keep a
> copy. You may not use PocketDJ to record, capture, or otherwise retain audio from a streaming service,
> and PocketDJ does not provide a means of doing so. When you use Apple Music through PocketDJ, you agree
> to comply with Apple's Media Services Terms and Conditions.
>
> **4.4 Sharing.** PocketDJ lets you share what you played — tracklists, playlists, collections, and
> listening history. These share information about recordings, never the recordings themselves. Anyone
> you share with plays the music from their own library or their own subscription. Sharing is intended
> for family and close, personal friends.
>
> **4.5 Public performance.** PocketDJ does not grant you any right to perform music in public. Playing
> music where the public can hear it — including bars, clubs, ticketed events, corporate functions, and
> paid DJ engagements — requires a public-performance licence, normally held by the venue. In the United
> States that is a licence from ASCAP, BMI, SESAC, or GMR. **Outside the United States you will usually
> need two licences — one covering the songwriting and a separate one covering the sound recording** (for
> example PRS and PPL in the United Kingdom, GEMA and GVL in Germany, SACEM and SCPP in France, APRA
> AMCOS and PPCA in Australia, SOCAN and Re:Sound in Canada). You and/or your venue are responsible for
> obtaining them, and could face substantial penalties for playing music in public without them.
>
> **4.6 No broadcasting.** You may not use PocketDJ to broadcast, webcast, or otherwise transmit music to
> people who are not present at your event. If you want to stream a DJ set, use a platform with a
> licensed DJ programme.
>
> **4.7 Repeat infringement.** We will terminate the accounts of users who repeatedly infringe copyright.
>
> ## 5. No warranty
>
> PocketDJ is provided **"as is" and "as available"**, without warranty of any kind, express or implied,
> including implied warranties of merchantability, fitness for a particular purpose, and
> non-infringement. We don't warrant that the app will be uninterrupted, error-free, or that it will
> preserve your data. **Nothing in this agreement excludes or limits any warranty or right you have as a
> consumer that cannot be excluded or limited under the law of your country.**
>
> ## 6. Limitation of liability
>
> To the fullest extent permitted by law, we will not be liable for indirect, incidental, special,
> consequential, exemplary, or punitive damages, or for lost profits, lost data, or loss of music
> libraries, however caused. Our total liability for any claim relating to PocketDJ will not exceed the
> greater of **(a)** the amount you paid for the app in the twelve months before the claim, or
> **(b) [US$50 — confirm with counsel]**. **This section does not limit liability for death or personal
> injury caused by negligence, for fraud, or for anything else that cannot be limited under applicable
> law.**
>
> ## 7. Term and termination
>
> This licence lasts until terminated. It terminates automatically if you breach it. We may suspend or
> terminate your access if you use PocketDJ unlawfully, infringe copyright repeatedly (§4.7), or attempt
> to circumvent the app's restrictions. On termination you must stop using PocketDJ and delete it. §§4.1,
> 5, 6, 8, and 9 survive termination.
>
> ## 8. Governing law
>
> This agreement is governed by the laws of **[STATE — see Q18]**, excluding its conflict-of-laws rules
> and the UN Convention on Contracts for the International Sale of Goods. Courts located in **[COUNTY,
> STATE]** have exclusive jurisdiction, subject to §9. **If you are a consumer resident in the EU, the
> UK, or another jurisdiction whose law grants you the right to bring proceedings locally, nothing here
> deprives you of that right or of the protection of your local mandatory consumer law.**
>
> ## 9. Disputes
>
> **[COUNSEL DECISION — do not ship as drafted.]** Options: (a) courts only, per §8 — simplest, no
> enforceability risk; (b) informal-resolution period followed by binding individual arbitration with a
> class-action waiver and a small-claims carve-out. Option (b) is standard for U.S. consumer apps and is
> **unenforceable against EU/UK consumers**. If Decision F (US-only) is adopted, (b) is available; if not,
> (a) is the safer default. **Whichever is chosen, it must be conspicuous and separately acknowledged.**
>
> ## 10. Apple
>
> **10.1** This agreement is between you and PocketDJ only, **not with Apple**. Apple is not responsible
> for PocketDJ or its content.
>
> **10.2 Scope.** Your licence is limited to using PocketDJ on Apple-branded products you own or control,
> as permitted by the App Store Terms of Service, including the Family Sharing and volume-purchase rules.
>
> **10.3 Maintenance and support.** **PocketDJ is solely responsible** for maintenance and support. Apple
> has no obligation to provide any maintenance or support.
>
> **10.4 Warranty.** **PocketDJ is solely responsible** for any product warranties, whether express or
> implied by law, to the extent not effectively disclaimed. If PocketDJ fails to conform to any
> applicable warranty, you may notify Apple, and **Apple will refund the purchase price**; to the maximum
> extent permitted by law, Apple has no other warranty obligation whatsoever with respect to PocketDJ.
>
> **10.5 Product claims.** **PocketDJ, not Apple, is responsible** for addressing any claims relating to
> PocketDJ or your use of it, including product liability, failure to conform to legal or regulatory
> requirements, and claims under consumer-protection, privacy, or similar legislation, including in
> connection with the app's use of HealthKit/HomeKit-style frameworks where applicable.
>
> **10.6 Intellectual property.** If a third party claims PocketDJ infringes their intellectual property
> rights, **PocketDJ, not Apple**, is solely responsible for the investigation, defence, settlement, and
> discharge of that claim.
>
> **10.7 Legal compliance.** You represent that you are not located in a country subject to a U.S.
> Government embargo or designated as a "terrorist supporting" country, and that you are not listed on
> any U.S. Government list of prohibited or restricted parties.
>
> **10.8 Developer contact.** Questions, complaints, or claims: **[LEGAL ENTITY NAME, ADDRESS,
> support@pocketdj.app — BLOCKERS 1 and 18]**.
>
> **10.9 Third-party terms.** You must comply with applicable third-party terms when using PocketDJ —
> including Apple's Media Services Terms for Apple Music playback.
>
> **10.10 Third-party beneficiary.** **Apple and its subsidiaries are third-party beneficiaries of this
> agreement, and upon your acceptance, Apple will have the right (and will be deemed to have accepted the
> right) to enforce this agreement against you as a third-party beneficiary.**
>
> **11. Export.** You may not use or export PocketDJ except as authorised by United States law and the
> laws of the jurisdiction where it was obtained.
>
> **12. U.S. Government end users.** PocketDJ and related documentation are "Commercial Items" as defined
> at 48 C.F.R. §2.101, consisting of "Commercial Computer Software" and "Commercial Computer Software
> Documentation" as those terms are used in 48 C.F.R. §12.212 or 48 C.F.R. §227.7202. They are licensed to
> U.S. Government end users only as Commercial Items and with only those rights granted to all other end
> users.

*Drafting notes.* §4.1 is Plex's retain-plus-grant structure plus rekordbox §5.1(c)'s liability
allocation. §4.4's "family and close, personal friends" is Plex's help-centre ceiling, chosen because it
does real legal work (it gestures at the private-use boundary) while reading as friendly guidance. §4.5
is VirtualDJ's model extended for §5.2's two-licence reality. §4.6 is rekordbox §4.1's prohibitory model
("not to provide live distribution of such music data to third party"). §10 tracks Apple's Schedule 1
minimum terms; **§10.10 is the clause Apple specifically looks for** and omitting it is a common
rejection cause. §§5, 6, and 8 all carry an explicit consumer-law carve-out because a flat exclusion is
void in the UK/EU and, in some U.S. states, risks voiding more than intended.

---

### 6.11 Privacy policy

**The App Store requires a privacy policy URL for every app. There is none, and the earlier draft did
not mention one — neither in the copy nor in the counsel questions.** This is a submission blocker
independent of everything else in this document, and it is also a live GDPR obligation (§5.6) for the
guest data the jukebox already collects from arbitrary phones.

**Placement:** hosted at a stable URL (**Blocker 1**), linked from App Store Connect, Settings ▸ About,
and — critically — **the jukebox guest page**, which today collects data with no notice at all.

> # PocketDJ Privacy Policy
> **Last updated: [DATE]**
>
> PocketDJ is a personal music library and DJ app. This policy explains what it collects, why, and what
> you can do about it.
>
> ## What stays on your device
> Your music, playlists, pockets, collections, mixes, recordings, cue points, and play history are stored
> on your device and in your own storage. **PocketDJ does not upload your music library to us and does
> not sell or share your data with advertisers or data brokers.**
>
> ## What syncs to iCloud
> If you're signed in to iCloud, PocketDJ syncs your profile, playlists, collections, favourites, and
> play history to **your own private iCloud database** using Apple's CloudKit. It's stored under your
> Apple Account, governed by Apple's privacy policy, and we cannot read it except as needed to operate
> sync on your behalf. Turn it off in Settings.
>
> ## The jukebox request line
> When you host a jukebox, your guests use a web page to see what's playing and send requests.
>
> **From guests we receive:** the song requests they type, a randomly generated session identifier, and
> their IP address (unavoidably, as with any web request — used to operate the service and to prevent
> abuse). **We do not ask guests for a name, email, phone number, or account.**
>
> **What the host sees:** the request text. Nothing that identifies the guest personally.
>
> **How long we keep it:** requests and session data are deleted **[N days — set a real number; today it
> is unbounded and `timeless` sessions never expire, which must be fixed before this ships]** after the
> session ends. Server logs containing IP addresses are retained **[N days]**.
>
> **Legal basis (EU/UK):** legitimate interests — operating a request line you asked for, and keeping it
> secure.
>
> ## Diagnostics
> **[Complete truthfully after audit: whether any crash/analytics SDK is present. If none: "PocketDJ
> includes no third-party analytics or advertising SDKs. Crash reports you choose to share with Apple are
> governed by Apple's privacy policy." If any exists it must be named here and declared on the App
> Privacy nutrition label.]**
>
> ## Children
> PocketDJ isn't directed at children under 13, and we don't knowingly collect their personal
> information.
>
> ## International transfers
> Our servers and storage are in the United States. If you're in the EU or UK, using PocketDJ means your
> request data is transferred there. **[Transfer mechanism — SCCs or equivalent — see Q17.]**
>
> ## Your rights
> Depending on where you live, you may have the right to access, correct, delete, or export your data, or
> to object to processing. Most of it is on your device or in your own iCloud, so you control it
> directly. For anything we hold, write to **[privacy@pocketdj.app — BLOCKER 2]**.
>
> ## Changes
> We'll post changes here and update the date above.

**Guest-page notice (Art. 13 transparency, one line, on the request form):**

> *Your request and your IP address are handled by this jukebox to run the request line, and deleted
> after [N] days. No account needed. [Privacy]*

**The App Privacy "nutrition label" in App Store Connect must match this policy exactly.** A mismatch
between the label and the policy is a common rejection cause and, separately, an FTC-style
misrepresentation risk.

---

### 6.12 App Store description language

**Register: [REVIEW]. This section is submission optics, not legal copy** — an honest label the earlier
draft did not apply. It frames the app for a reviewer; it does not reduce liability to anyone.

The reviewer's question is *"does this app pirate music?"* — answer it in the first three lines, then
never use a verb that reopens it.

> **PocketDJ — your record collection, everywhere**
>
> PocketDJ turns the music you already own into a DJ-ready library. Digitize your vinyl, bring in your
> own audio files, and browse your Apple Music library — all in one catalog with tempo, key, and mood for
> every track.
>
> **Built for the music you own.** Import your own records and files. PocketDJ analyzes tempo, musical
> key, and beat grid, then keeps everything available offline on your devices. Your library lives in your
> own storage and on your devices.
>
> **Play your Apple Music library.** Full-length playback through your own Apple Music subscription, with
> your playlists and favourites in sync.
>
> **Mix and perform.** Two decks, crossfader, effects, cue points, loops, stem separation, and a 16-step
> sequencer. Record your sets and replay them.
>
> **Party mode.** Guests scan a code to see what's playing and send you requests from their phones. You
> decide what plays; the music comes from your speakers.
>
> **CarPlay, widgets, Siri Shortcuts,** and a Now Playing deck that spins at the track's real BPM.
>
> *PocketDJ organizes music you already have. It does not sell or license music, and does not grant
> rights to perform music in public — playing music publicly may require a licence from a
> performing-rights organisation.*

**Words to keep out of the listing entirely — [REVIEW] optics, explicitly:** *rip, burn, capture, record
from, download from, free music, unlimited, any song*. The last three are what a reviewer
pattern-matches on. **This list reduces rejection risk and nothing else.** It does not affect liability
to a rights holder, and it should not be counted as remediation.

*Voice note:* "Your library is yours — it isn't shared with other users" has been replaced with "Your
library lives in your own storage and on your devices," per §6.0.1. The original was vacuously true of a
one-user product and implied a multi-tenant isolation guarantee that does not exist.

---

## 7. The code changes that make the copy true

Ordered **by urgency, not by size** — the earlier draft listed a 3–5 day infrastructure rebuild ahead of
a 2-hour change that removes the largest live exposure, which contradicted the urgency §2 argues for.
**(a) MUST-0** — today. **(b) MUST** — before any copy. **(c) SHOULD** — hardening. **(d) LATER** —
multi-tenant readiness. Effort is engineering time, excluding review.

**Owner: Levi, for every item.** There is one engineer. Stating that explicitly matters because it means
the sequence below is a **critical path, not a backlog** — nothing runs in parallel except where noted,
and the calendar estimate is the sum, not the max.

### (a) MUST-0 — today, before anything else

These four take **under three hours combined** and each one is either irreversible-if-delayed or
stops ongoing exposure. Do them in this order, today.

| # | What | Where | Why it is today | Effort |
|---|---|---|---|---|
| **0a** | **Arm auth on both live services.** Set `RIP_TOKEN`, `RIP_ADMIN_TOKEN`, `RIP_RATE_LIMIT=1`, `JUKEBOX_TOKEN`. Restart. Confirm `/health` reports `"auth":true` on both. Audit the 4 live jukebox sessions and delete any you don't recognise. | `~/.pocketdj/rip-server.env` (both tokens already present, **commented out**); `scripts/launchd/com.pocketdj.jukeboxserver.plist` | **This is the largest live exposure and the smallest fix in the document.** Right now anyone on the internet can drive `POST /rip`, the uncapped `POST /rip-collection`, and the entire admin path set against a 106,494-song catalog, spending your AWS credentials. It is an uncomment and a restart. | **30 min** |
| **0b** | **Turn on access logging — BEFORE closing the bucket.** Enable S3 server access logging on `pocketdj-rips-011183829623` and both web buckets (to a separate log bucket); enable CloudFront standard logging on both distributions; create a CloudTrail trail with S3 data events for the rips bucket. | AWS | **§2: there is no log of any kind, so "was any of it downloaded?" is currently unanswerable.** Enabled today, it answers the question going forward and catches harvesting still in progress. Enabled after MUST-1 closes the bucket, it records nothing. **Order is load-bearing.** | **1 h** |
| **0c** | **Snapshot the pre-deletion inventory.** `aws s3api list-objects-v2` full dump (key, size, etag, last-modified) for the rips bucket and the two web buckets' `/lyrics/` and `/art/` prefixes; a verbatim copy of `rips/manifest.json`; and the join output identifying the 369. Commit to the private repo alongside this document; keep a copy off-machine. | `docs/legal/inventory-2026-07-20/` | **Versioning is off (§2), so MUST-6's deletes are irreversible.** This preserves the *record* while removing the *copies* — the posture that survives both "you destroyed evidence" and "you kept infringing." See §4, "Preservation." | **30 min** |
| **0d** | **Suspend the live TestFlight builds and stop distributing.** Expire the current iOS/macOS/visionOS builds in App Store Connect, halt new tester invitations, and send the §6.9 notice. | App Store Connect | **§7E's "before any stranger installs it" is already false** — there are live builds, and every additional tester converts a single-user architecture problem into a multi-user distribution fact. The earlier draft left this as narrative and its closing line addressed only *future* testers. The existing ones are the fact the document warns about. | **30 min** |

**If a takedown notice, demand letter, or any claim arrives at any point: stop all deletion immediately
(0c preserved the inventory; MUST-6 has not run yet) and consult counsel before touching another
object.** Deletion is right today precisely because nothing is anticipated.

### (b) MUST — ship before any copy

| # | What | Where | Why | How | Type | Effort |
|---|---|---|---|---|---|---|
| **1** | **Close the bucket.** Remove `Allow * s3:GetObject` on `rips/*`; enable all four Public Access Block flags. Re-admit exactly one narrow public grant for `rips/instruments/*` (licensed GeneralUser GS). | AWS bucket policy, `pocketdj-rips-011183829623` | Pillars 1.3, 2.2, 2.3, 2.4, 3.1 | See **"MUST-1 in detail"** below — this item previously had no file paths or route table despite being the largest change in the plan. **Note this breaks the documented "works with the rip server off" property** (`docs/architecture/05`, `07`) — that property and Pillar 1 are mutually exclusive; make the trade deliberately. | **Infra + server + app** | **3–5 d** |
| **2** | **Make auth structural** (0a was the config fix). `authed()`/`adminAuthed()` **fail closed** under public posture; refuse to bind the port when `CFG.public && !CFG.token`. | `rip-server.mjs:1905,1911,133,59,62` | Pillar 3.4 | Invert the defaults so misconfiguration cannot silently reopen the service. Add a startup log line stating the auth posture. | **Server** | **3 h** |
| **3** | **Delete the Discover capture path.** Remove "＋ Add" capture, `discoverAdd`/`discoverAddRip`, and the `ADHOC_ID` synthesis branch so an `amrec_` id can never create a job. | `BrowseDiscover.swift:108-111,144,301-313`; `RipsStore.swift:794-828`; `rip-server.mjs:533-541` | §4 entry point 2 | Keep catalog search for **discovery**; its only action becomes a MusicKit playback deep link (the licensed path already in `MusicLibraryContributor.swift`). Delete the 4 existing `amrec_` objects + stems. | **App + server** | **1 d** |
| **4** | **Delete "Rip from cloud source."** | `SettingsView.swift:475`; `SettingsStore.swift:76,492`; `RipsStore.swift:428,646,689,891,1036`; `rip-server.mjs:549,258-262` | §4 entry point 3 | Remove the toggle and the flag from all five POST bodies; delete `preferCloud` and the `hasExactAMMatch` probe. Then **re-import the 88 affected songs from vinyl** via `/backfill-cuts`. **Versioning is off (§2), so the overwrite is terminal — 0c must have run first.** | **App + server + data** | **1–2 d** |
| **5** | **Gate capture on provenance at the single choke point.** Replace the `sourceType` test with an allowlist on `sourceName`: `"My Vinyl"` → `runAnalogJob`; `"My Digital"` → file-copy path; `"Apple Music (Local)"` and **anything unknown** → **fail closed** with the structured error in §6.7. | `rip-server.mjs:800` (+ client twin in `RipsStore` `ensureURL`/`requestRip`) | §4 entry point 1 — the top-line finding | **Copy the `STUDIO_ID` fence** (`rip-server.mjs:503-514` + `RipsStore.swift:211-217`) exactly: generalize it into a shared `isCaptureEligible(song)` predicate enforced at both doors. Ship the §6.7 error string in the same commit. Model tests on `apple/Tests/Unit/RipsStoreAsyncRipTests.swift`. | **Server + app** | **2–3 d** |
| **5b** | **Delete the capture capability itself.** Remove `scripts/rip-one.mjs`, `.claude/skills/rip/`, and `.claude/skills/backfill-rip/`. | those three paths | §4, "The capture capability survives every app-level fix" | **Promoted from SHOULD-14.** MUST-3/4/5 close the app and route doors; these three remain directly invokable from a shell on the machine that serves the beta, and `backfill-rip.mjs:217-218,349` mass-POSTs `/rip-collection`. If Decision A1 is the recommendation, removal is not hardening — it *is* the decision. Gating a capability you have decided not to have is incoherent. | **Repo** | **1 h** |
| **5c** | **Remove the duplicate worktree checkouts.** `git worktree remove` (or delete) `.claude/worktrees/agent-a5bbb83921315bcda`, `agent-a5f0c7abeca77ef37`, `agent-af706589fdd7af12e`. | `.claude/worktrees/` | §4, "Four runnable copies, not one" | **There are 4 copies of `rip-server.mjs`, 4 of `rip-one.mjs`, 4 of `mirror-art.sh`, and 4 of `mirror-art.mjs`** — every MUST item above edits one. A remediation that edits one leaves three runnable capture servers on the machine that serves the beta. Verify with `find . -name rip-server.mjs -not -path "*/node_modules/*" \| wc -l` → must be `1`. | **Repo** | **30 min** |
| **6** | **Purge Tier-3 objects.** Delete the 277 "Apple Music (Local)" objects, the 4 `amrec_`, and every stem/lyric/analysis/waveform derived from them, plus their manifest entries. | S3 + `rips/manifest.json` | §4 | Join the manifest against `apple-music-index.json` to build the delete list. **Blocked on 0c (snapshot) and MUST-5 (so nothing re-creates them).** Deletion is irreversible — versioning is off. **Also purge the embedded-art surfaces in 2.7(c) for these objects.** Ship §6.8's migration notice in the build that follows. | **Data** | **4 h** |
| **7** | **Add `sourceName` to every manifest entry**, and backfill by joining against the index files. | `rip-server.mjs:1088` (capture writer), `:2301` (ingest writer) | §4 "provenance wired to the wrong layer" | Make `sourceName` the authority for three gates: capture-vs-cut routing, S3-upload eligibility, and public-exposure eligibility. Add a startup assertion that refuses to serve any entry lacking a `sourceName`. | **Server + data** | **1 d** |
| **8** | **Unpublish the lyrics prefix.** | `scripts/lyrics-cdn.sh`; `s3://pocketdj-{dev,prod}-web-*/lyrics/` (9,945 + 6,256 objects) | Pillar 2.5 | Remove the sync; `aws s3 rm --recursive` both. Keep lyrics device-local, fetched through the authenticated server for the signed-in owner. Same treatment for `rips/lyrics/*.json`. **Covers both provenance classes (scraped and Whisper) — 2.5 explains why Whisper is not exempt.** | **Infra + script** | **3 h** |
| **9** | **Tighten the web bucket.** Narrow `PublicReadGetObject` from `/*` to specific public prefixes (`/index.html`, `/assets/*`, app-config JSON, `/art/*` if retained); enable Public Access Block. | `pocketdj-{dev,prod}-web-011183829623` bucket policy | Pillars 2.5, 2.6, 2.7 | Currently the **entire bucket** is public with **no** Public Access Block configured at all. | **Infra** | **2 h** |
| **10** | **Decide the jukebox audio path** — Decision C. If request-only (recommended): delete the guest audio path entirely. | `template.html:71-73,195-302`; `JukeboxModels.swift:70`; `JukeboxStore.swift:261,272,280,291-295`; `jukebox-server.mjs:174-185,213-222`; `JukeboxView.swift:175-186` | Pillars 3.1, 3.3, 3.6 | ~60 lines deleted. The entire party experience — QR, live queue, played history, request box — is untouched. Also **stop publishing `upNext`** in any mode that carries a `streamUrl` (§114(d)(2)(C)(ii)); keep `played`. **Add the Art. 13 guest-page privacy line (§6.11) and a real retention period** — `timeless` sessions never expire today. | **App + server + site** | **1 d** |
| **11** | **Author the documents.** First-run attestation, contextual notices, host notice, catalog footer, About/Legal, **full EULA (§6.10)**, **privacy policy (§6.11)**, fail-closed error (§6.7), migration notice (§6.8), App Store copy. | §6, all drafted | All pillars | Wire the attestation as a 4th onboarding stage. **Resolve the four blockers in §6.0 first — domain, two mailboxes, attributions screen.** Delete `OnboardingView.swift:277`. **None ship before MUST-1…10.** | **App + documents** | **3–4 d** |
| **12** | **Register a DMCA agent and publish a repeat-infringer policy.** | Copyright Office (§512(c)(2)); About/Legal; EULA §4.7 | §512(i) is a **threshold** condition on all safe harbors | **Blocked on Blocker 3** — registration requires a working address. Note it does not rescue everything: §512(c) covers *storage*, never the operator's own public performance. | **Documents + filing** | **3 h + fee** |
| **13** | **Rename the user-visible `rip`/`burn` strings** per §6.1. | 17 sites, table in §6.1 | Vocabulary — **[REVIEW]** | **Sequenced deliberately last among the MUSTs.** §6.1 explains why: a rename that post-dates a written internal risk assessment, while the capture conduct is still in the repo, reads as concealment rather than remediation. After 3/4/5/5b/6 the same commit reads as vocabulary catching up to the product. | **App** | **1 d** |

**MUST-0 subtotal: ~2.5 hours.** **MUST subtotal: ~13–18 engineering days.**

#### MUST-1 in detail — the item that previously had no paths

The two largest new components in the plan (this and LATER-27) had no file, no route table, and no
client call sites beyond "repoint `Config.swift:21`." They are the multi-day items and had the least
specificity. Concretely:

**New server module: `scripts/media-auth.mjs`**

| Export | Responsibility |
|---|---|
| `signMediaURL(key, { ttl = 300 })` | `@aws-sdk/s3-request-presigner` + `GetObjectCommand`. The only presigner for this bucket; the repo currently has none (1.3). |
| `verifyCaller(req)` | Bearer token today (single-tenant); the seam LATER-27 replaces with a verified per-user session. Returns `{ ok, userId }` — `userId` is `'owner'` until LATER-27, so call sites never change shape. |
| `mediaRoutes(app)` | Mounts the routes below. |

**Route table (new):**

| Route | Behaviour |
|---|---|
| `GET /media/:songId` | `verifyCaller` → look up `manifest[songId]` → **check `sourceName` eligibility (MUST-7)** → `302` to `signMediaURL(key)` |
| `GET /media/:songId/stems/:stem` | Same, for `rips/stems/<songId>/<stem>.<ext>` |
| `GET /media/:songId/cut` | Same, for `cutKey` |
| `GET /media/manifest` | **Replaces anonymous `rips/manifest.json` (2.2).** Authenticated; returns entries **without** raw S3 keys — ids only, so the response is not a download index even if it leaks |

**Server call sites to change:** `rip-server.mjs:148-149` (`publicUrl()` → `signMediaURL`), `:543`
(shared-master short-circuit — returns a signed URL, and is the line LATER-29 removes), `:1088` and
`:2301` (manifest writers, coordinate with MUST-7).

**Client call sites to change:**

| File | Change |
|---|---|
| `apple/PocketDJ/Config.swift:21` | Raw bucket host → rip-server base URL |
| `RipsStore.refreshManifest` | Add `Authorization`; parse the key-free manifest shape |
| `RipsStore.cachedURL` / `ensureURL` | Resolve via `GET /media/:songId` instead of composing a bucket URL |
| `BurnStore.swift:982` | Download from the signed URL; handle 302 |
| `TransferCoordinator` | Background `URLSession` must carry the header **and tolerate a mid-transfer TTL expiry** — the one genuine engineering risk in this item |
| `src/store/useRipsStore.ts:5-6,14-15` | Same repoint; delete the "manifest is PUBLIC" comment |
| `jukebox-server.mjs:174-185` | If hear survives Decision C, `streamUrl` must become a short-TTL signed URL, not a permanent one |

**TTL: 300 s.** Long enough for a track to start, short enough that a leaked URL is not a distribution
channel. Background downloads need refresh-on-401, which is why `TransferCoordinator` is called out.

### (c) SHOULD — hardening the posture

| # | What | Where | Why | Effort |
|---|---|---|---|---|
| 14 | Default `autoStemOnRip` and the lyrics auto-chase **OFF**, so derived copies require an explicit per-song act. | `rip-server.mjs:119-123,1096,919,1714` | Pillar 1.7 volition | 2 h |
| 15 | Gate the nightly digital indexer behind explicit operator confirmation, recorded per song with timestamp. | `digital-sync-nightly.sh:223` | Pillar 1.7 | 4 h |
| 16 | Record **per-copy provenance** in the manifest: who requested it, when, from which source. | `rip-server.mjs` manifest writers | Pillars 1.7, 1.9; §512(c) | 1 d |
| 17 | Provenance attestation at digital ingest: a required `--provenance` flag (`owned-media-rip` \| `purchased-download`) persisted per object; exclude unattested files from upload by policy. | `index-digital-files.mjs`; `/ingest-digital` | §4 Tier 2 | 4 h |
| 18 | Forbid `timeless` + `hear` from coexisting; stop `sweep()` resurrecting guest pages for ended sessions; **add a real session-data retention period** (§6.11 needs a number). | `jukebox-server.mjs:252-259,375-378` | Pillar 3.2; §5.6 | 3 h |
| 19 | Make the broker's view-only gate **authoritative on the server**: `streamUrl: (s.hear && https) ? su : null`. Split the misleading test to assert `hear:false` + `https://` separately from the scheme case. | `jukebox-server.mjs:174-185`; `test-jukebox-server.mjs:165-170` | **Pillar 3.6 — re-upgraded to `high`**; the client-side invariant is not a control on an unauthenticated broker | 2 h |
| 20 | Remove the `RIP_AGENT` branch. | `rip-server.mjs:1049-1060` | Pillar 1.8 (latent) | 1 h |
| 21 | Add a test asserting the Mix branch can **never** emit a mix-bus or recording URL, and remove the "live radio mode" follow-up from `jukebox-hero.md:212` so it isn't read as an approved roadmap item. | `JukeboxStore.stateSnapshot()`; `docs/design/jukebox-hero.md` | Pillar 3.8 | 2 h |
| 22 | **Rewrite the posture itself** to enumerate every class of published artifact — audio, stems, lyrics, transcripts, artwork, analysis, waveforms, beat grids, tracklists — with an explicit permitted/forbidden disposition for each, and a rule that a new artifact type is forbidden by default until classified. | `docs/design/` | **Pillar 2's scoping defect (§1, §3 Pillar 2 preamble).** Three surfaces failed because the pillar only ever described `index.json`. | 4 h |
| 23 | **Read the Discogs API/ToS terms** and record what they actually permit for the 346 mirrored images. | — | 2.7(a): a contractual restriction is not defeated by fair use | 2 h |
| 24 | **Resolve the artwork question.** Record an `artLicense` + `artSource` + `artLicenseVersion` field per image at mirror time (Apple / Discogs / Wikimedia, the last needing **CC-BY-SA version** and a check for non-free Commons uploads), **and** invert `coverArtSources` so `remote` leads and `/art/*` is a client-side cache. **Do both, not either** — the preference inversion is the fact that most weakens the *Perfect 10* analogy (2.6). Cover the embedded-art path too (2.7(c)). | `scripts/mirror-art.sh`; **`.claude/skills/analog-indexer/lib/mirror-art.mjs`** (corrected path — there is **no** `scripts/mirror-art.mjs`); `index-digital-files.mjs:250-266`; index manifest | Pillars 2.6, 2.7 | 1–2 d |
| 25 | **CI guards** so none of this regresses: fail the build if (a) any published index field matches `^https?:.*\.(mp3\|m4a\|wav\|flac)$` or `^rips/`; (b) either bucket's public-access-block is off; (c) `find . -name 'rip-server.mjs' -not -path '*/node_modules/*' \| wc -l` ≠ 1 (MUST-5c regression guard); (d) any capture skill path reappears. | CI | All | 6 h |
| 26 | **Audit the CloudKit public surfaces** — public profile, Discover, shared collections — and record exactly what fields leave the device and which are world-readable. **Blocks the §6.5 footer from being placed on them.** | `CloudSyncService.swift`; profile/Discover views | §6.5's unverified-placement warning | 1 d |
| 27 | **Territory restriction** — set App Store availability to the United States only (Decision F). | App Store Connect | §5.7 | 15 min |

### (d) LATER — multi-tenant readiness

Required **before strangers install it** and Pillar 1 stops being vacuous. Today there is one human, one
bucket, one manifest, one token — "per-user copy" is not merely unenforced, it is *unrepresentable*.

| # | What | Where | Effort |
|---|---|---|---|
| 28 | **Real per-user identity.** Sign in with Apple / OIDC exchanged for a per-user server session, `userId` derived **server-side** from the verified credential. Never accept a client-supplied id. See **"LATER-28 in detail"** below. | New `scripts/auth-service.mjs`; `rip-server.mjs` | 1–2 wk |
| 29 | **User-namespaced keys** for audio, cuts, stems, analysis, waveforms, lyrics, **and the manifest**: `users/<userId>/rips/<songId>.mp3`, `users/<userId>/manifest.json`. **Migration: see the note below — the honest single-user answer is that there is nothing to re-attribute.** | Every writer; `RipsStore.cachedURL` | 1–2 wk |
| 30 | **Per-user scoping of all four dedup paths.** Probe only under the caller's namespace; cross-user dedup impossible **by construction**, not by policy. If N copies is unaffordable, that is the honest signal the design is distribution, not copying — and the posture should be rewritten rather than the code. | `rip-server.mjs:543,551-556`; `stem-worker.mjs:81-100,165-178` | 3–5 d |
| 31 | **Remove the shared analog album object from the playback path** — per-user, per-song objects; the whole-album transcode becomes an internal intermediate that is never served. | `rip-server.mjs:845-856`; playback | 3 d |
| 32 | **Real §512 posture**: user records to terminate, an implemented repeat-infringer policy, standard-technical-measure accommodation. Without users there is nobody to terminate, which makes §512(i) compliance not merely absent but *architecturally impossible*. | Auth + policy | 1 wk |
| 33 | **Non-US readiness** before lifting the territory restriction: two-licence PRO copy verified per region (§5.2), GDPR lawful-basis and retention implemented (§5.6), database-right position on ingest reviewed (§5.4), moral-rights exposure re-checked for any distributed stems (§5.5). | Copy + infra + counsel | 1 wk + counsel |

#### LATER-28 in detail

**New service: `scripts/auth-service.mjs`** (or the same process behind a route prefix — a separate
deployable is cleaner but not required at this scale).

| Route | Behaviour |
|---|---|
| `POST /auth/apple` | Receive the Sign in with Apple identity token → verify signature against Apple's JWKS → verify `aud`/`iss`/`exp` → derive `userId` from the **verified `sub`** → issue a PocketDJ session JWT (30 d, rotating) |
| `POST /auth/refresh` | Rotate |
| `GET /auth/me` | Return `{ userId }` for client debugging |

**The rule that matters:** `userId` comes from the verified `sub` claim **server-side, always**. A
client-supplied id is never trusted, because a client-supplied id reproduces the current situation with
extra steps. `verifyCaller()` in `media-auth.mjs` (MUST-1) is the single seam — it returns `'owner'`
today and a real `userId` after this item, so no call site changes shape.

**Client:** `AuthStore.swift` (new) wraps `ASAuthorizationAppleIDProvider`, stores the session in the
keychain, and injects the header in `RipsStore`, `BurnStore`, and `TransferCoordinator`.

#### On LATER-29's migration: say the honest thing

The earlier draft said the migration "re-attributes the existing 1,240 objects" — **to whom?** There is
one human. The vacuousness diagnosed in Decision E bites hardest at exactly this point, and the draft
left it undefined.

**The honest answer is that there is nothing to re-attribute.** The corpus belongs to one account. The
migration is therefore not a distribution problem, it is a **prefix move**:

1. After MUST-6, the remaining ~1,150 objects (846 My Digital + 304 analog) are all Levi's.
2. Migration = `aws s3 mv` from `rips/<id>` to `users/<levi-userId>/rips/<id>`, plus a manifest rewrite.
3. There is no ambiguity to resolve, no consent to collect, no ownership dispute.
4. **The real work is not the move — it is that every writer, reader, and dedup probe must stop being
   able to construct a key outside the caller's namespace.** That is LATER-29 and LATER-30, and it is
   where the two weeks go.

Stating this plainly matters because "migrate 1,240 objects to their owners" sounds like a hard
distributed-systems problem and is actually a rename. The hard part is structural, not data.

### Dependency graph and calendar

The earlier draft gave twelve MUST items, ~12–17 days, and no statement of what blocks what beyond
"MUST-6 after MUST-5."

```
TODAY ──┬── 0a arm auth ────────────────────────┐
        ├── 0b enable logging ──► (must precede MUST-1)
        ├── 0c snapshot inventory ──► (must precede MUST-4, MUST-6, MUST-8)
        └── 0d suspend TestFlight ──────────────┘

         ┌── 2 auth structural ──┐
0a ──────┤                       │
         └── 1 close bucket ─────┼──► 11 author documents ──► 13 rename
0b ──────────► 1                 │         ▲
                                 │         │
3 delete Discover ───────────────┤         │
4 delete cloud-rip ──(needs 0c)──┤         │
5 provenance gate ───┬── 5b delete capture ──┬──► 6 purge (needs 0c, 5)
                     └── 5c remove worktrees ┘
7 sourceName ────────────────────┤
8 unpublish lyrics ──(needs 0c)──┤
9 tighten web bucket ────────────┤
10 jukebox decision ─────────────┘

12 DMCA agent ── blocked on Blocker 3 (mailbox) ── independent, run anytime after
27 territory restriction ── independent, 15 min, do it early
```

**Hard blocks:**

| Blocks | Blocked | Why |
|---|---|---|
| 0b | MUST-1 | Logging enabled after the bucket closes records nothing |
| 0c | MUST-4, 6, 8 | Versioning is off — deletion and overwrite are irreversible |
| MUST-5 | MUST-6 | Purge before the gate and the capture paths re-create objects |
| MUST-5, 5b, 5c, 6 | MUST-13 | §6.1's concealment-sequencing rule |
| MUST-1…10 | MUST-11 | The copy must not describe a system that doesn't exist |
| Blocker 1, 2 | MUST-11 | Placeholders must not ship |
| Blocker 3 | MUST-12 | DMCA registration needs a deliverable address |
| SHOULD-26 | §6.5 footer on profile/Discover | Unaudited surfaces |

**Calendar, one engineer, sequential:**

| Window | Work |
|---|---|
| **Day 0 (today)** | MUST-0a…0d (~2.5 h) + SHOULD-27 territory (15 min) + resolve Blockers 1–3 (domain + mailboxes) |
| **Days 1–3** | MUST-3, 4, 5, 5b, 5c — the capture removal block |
| **Days 4–5** | MUST-6 purge, MUST-7 `sourceName`, MUST-8 lyrics, MUST-9 web bucket |
| **Days 6–10** | MUST-1 close the bucket + `media-auth.mjs` (the long pole), MUST-2 |
| **Day 11** | MUST-10 jukebox |
| **Days 12–15** | MUST-11 documents (incl. full EULA + privacy policy), MUST-12 DMCA |
| **Day 16** | MUST-13 rename |
| **Then** | SHOULD block (~6–8 d), then reassess LATER against whether there are actually users |

**~16 working days to the end of MUST**, with the exposure-reducing majority done in the first five and
the largest single exposure closed in the first thirty minutes.

---

## 8. Decisions for Levi

### A. Apple Music capture — what happens to it?

| Option | Consequence |
|---|---|
| **A1. Remove it entirely** ✅ **recommended** | Delete the capture worker path **and the capture skills** (MUST-5b); gate on `sourceName` (MUST-5); purge the 369 objects (MUST-6). Apple Music becomes **playback-only via MusicKit** — the licensed path already implemented. Costs: those 369 tracks stop being offline-available. Buys: the §106(1) exposure goes to zero **going forward**, the App Store story becomes clean, and **§6's copy becomes true**. |
| **A2. Keep it, private + per-user** | Does not help. Reproduction is independently actionable; *MP3.com* and *ReDigi* were decided purely on reproduction with no performance analysis needed. *ReDigi* is the cautionary note on cleverness: a system engineered so only one copy ever existed at any instant still made a reproduction. |
| **A3. Keep it, developer-only** | **Fails for the same reason A2 fails: §106(1) reproduction has already occurred, 369 times, and occurs again on every capture — regardless of who can reach the button.** "Only I use it" is not a defense to reproduction; it is at most a statement about scale. *Secondarily*, and this is the review/distribution point rather than the legal one: "developer-only" is not a property this codebase has — the capture code and the buttons ship in the App Store binary and the default server URL is baked in (`Config.swift:31`, `SettingsStore.swift:488`). |

**Recommendation: A1.** This is the single highest-value decision in the document. It is also the one that
makes every other section coherent — you cannot write §6.6's "does not copy from streaming services"
while A2 or A3 is live.

*Note on A3's rewrite:* the earlier draft rejected A3 **only** on the binary-contents ground, which
mixed registers — it offered a distribution fact as the reason a legal option fails. The legal reason is
reproduction, and it is the same reason A2 fails. The binary point is real but secondary, and it belongs
where it now sits.

**And note what A1 does not do.** It stops future reproduction. It does not undo the 369 completed
reproductions, it does not reach copies on tester devices (§4, "What deletion does not reach"), and —
because there are no access logs (§2) — it does not tell you how far the corpus already travelled.
Those are counsel questions (Q1–Q3), not engineering ones.

### B. Does the jukebox stream audio to remote guests, or is it request-only?

| Option | Assessment |
|---|---|
| **B1. Request-only** ✅ **recommended** | Delete ~60 lines. Guests scan, see now-playing / up-next / played, and type requests; music comes from your speakers. **In the United States**, nothing copyrightable is transmitted or reproduced to them — titles and artists aren't copyrightable (37 C.F.R. §202.1(a)) — and the room performance implicates only the musical work, which is the venue's blanket licence by industry design. **Outside the United States the room performance also implicates the sound recording** (§5.2), so the host needs two licences rather than one; the app's exposure is still nil, but the *host notice* must say so (§6.4). |
| **B2. LAN-only audio** | The strongest *legal* story for hosted audio: bind the origin to the LAN (mDNS, RFC1918 only), never S3, so the network boundary *is* the room boundary. But it breaks the whole S3/CloudFront architecture, cannot be enforced from a static page, and — critically — a LAN transmission is **still a "transmission"** under §101 ("received beyond the place from which they are sent"). The defense is "not to the public," never "not a transmission." Get that reasoning right or the design rests on a false premise. |
| **B3. Keep hear mode, harden it** | Short-TTL presigned URLs, a hard listener cap, room codes, host-approves-each-listener. Genuinely narrows "capable of receiving." But it stays **interactive** under §114(j)(7), so no statutory licence is available at any price, and *Zediva* already enjoined a *better* version of the one-copy-one-viewer argument (a dedicated physical disc per customer). Outside the U.S. it additionally engages the recording's own communication-to-the-public right. |

**Recommendation: B1.** Note the honest uncertainty: no court has squarely held that an internet
transmission to a genuinely closed private group is non-public. *Aereo*'s "family and its social circle"
sentence is the best hook but it is framing, not a holding, and the Court expressly reserved cloud
questions. That question is *interesting* — but the current implementation doesn't present it. A permanent
unauthenticated public URL, an uncapped audience, a published advance schedule, and prompt request
fulfilment fail under settled law without ever reaching the interesting issue. **Build the clean version
first; the unsettled question is only worth having if the design is otherwise defensible.**

*Correction from the earlier draft:* B1 was described as "legally free." That is a **U.S.** conclusion
and it rested on §114(a). The recommendation is unchanged and is in fact stronger internationally — but
the stated rationale was jurisdictionally overclaimed and has been narrowed.

### C. Does the public catalog keep artwork and lyrics?

- **Lyrics: no.** Remove (MUST-8). Separately copyrighted literary works reaching publishers, absent from
  the posture's own enumeration, ~16,200 files harvestable from two public URLs. Keep them device-local
  for the owner. **This covers Whisper transcripts too** — 2.5 explains why machine transcription does
  not launder the underlying lyric, and why the tempting "it's just observed facts" argument fails.
- **Artwork: keep the thumbnails, but do BOTH remediations, and stop calling it settled.** 2.6 replaces
  the earlier unargued fair-use gesture with an actual four-factor analysis. The short version: factor 3
  (amount — 254×256) is genuinely favourable and is what *Kelly* and *Perfect 10* turned on; factor 1 is
  weaker than those cases because a catalog browser is arguably not performing transformative *indexing*;
  and **the preference inversion in `mirror-art.sh` — mirroring *instead of* pointing at the source — is
  the worst fact and is one we created.** So:
  1. **Invert the preference back** so the compliant hotlink leads and `/art/*` is a client-side cache.
     This removes the worst fact and costs nothing.
  2. **Record `artLicense`/`artSource`/`artLicenseVersion` per image**, the way
     `upload-instrument-packs.sh:40` already does for GeneralUser GS.

  Do **both** (SHOULD-24), not either. Then three source-specific actions:
  - **Discogs (346)** — **read the actual terms** (SHOULD-23). This is contract, not fair use, and a
    fair-use finding does not defeat it (*ProCD*). The largest non-Apple share received one sentence in
    the earlier draft; that is the gap.
  - **Wikimedia (268)** — **CC-BY-SA's share-alike is the harder half**, not attribution. Record the
    license *version*, and check for non-free album art uploaded to en.wiki under a fair-use rationale,
    which cannot be relicensed at all (2.7(b)). Q12 now asks about SA specifically.
  - **Embedded art (2.7(c))** — ID3 frames inside the 1,519 mp3s and in every burn, plus
    `index-digital-files.mjs:250-266`, which actively extracts embedded art onto the **public** web
    bucket. Previously missed entirely; must be in MUST-6's purge scope and SHOULD-24's licensing field.

### D. Do "rip" and "burn" get renamed?

**Yes — but this is a [REVIEW] item, not a liability item, and it belongs last in the sequence.**

The word itself is not salvageable: rekordbox's EULA uses "rip" in scare quotes as its term for
prohibited conduct, so within this category the word is the industry's name for the infringing act.
"Burn" is weaker but appears in no competitor's copy and reads to a reviewer as *make an unauthorized
copy*.

**Credibility with whom — the question the earlier draft didn't answer.** With **App Review**. The
rename fixes that reader completely: the string is the problem, change the string, problem gone. It
does **nothing** for a rights-holder's counsel, who will prove conduct from infrastructure and repo
history and has no interest in your button labels (§6.1's two-reader table).

So the earlier draft's "cheapest credibility item on the entire list" was true but under-specified, and
it sat in a legal-posture decision list as though it reduced exposure. It does not. **It is a
submission-readiness item that should be tracked with the App Store checklist**, and it is listed here
only because it interacts with sequencing:

**Sequence it strictly after MUST-3/4/5/5b/6.** Renaming while the capture conduct is still in the repo
changes the label, not the act — and does so on a timeline permanently visible in git. The document's own
*Grokster* reasoning (internal docs and feature naming are evidence) cuts against a rename that
post-dates a written internal risk assessment: it can read as concealment. After the capability is gone
and the corpus is purged, the same commit reads as vocabulary catching up to the product. **Engineering
cost of the ordering: zero. Evidentiary difference: real.**

Rename the 17 user-visible strings (§6.1). Leave internal identifiers and accessibility ids alone.
**Effort: 1 day.**

### E. Multi-tenant now, or ship single-user?

**Ship single-user — and say so.** Recommended sequence:

1. **Today:** MUST-0. Arm auth, enable logging, snapshot the inventory, **suspend the TestFlight
   builds.**
2. **Then:** the MUST block. Lock the bucket, kill Tier-3 capture, ship the copy. The app is honestly
   a personal library for one person with their own library on their own infrastructure. Every §6 sentence
   is true of that product — **once §6.0.1's vacuous multi-user claims are rewritten**, which is why that
   rewrite is part of the copy rather than a note about it.
3. **Before any stranger installs it:** the LATER block.
4. **Only then:** multi-tenant. Doing it now costs 4–6 weeks and buys nothing until there are users.

**Step 3 was already false when the earlier draft wrote it, and left it as narrative.** What a TestFlight
tester receives is not their own copy — it is read access to your shared 1,519-song corpus over an
unauthenticated public URL. `OnboardingView.swift:277` currently tells testers *"Without it, songs still
play through the rip server,"* i.e. serving your corpus to subscription-less testers is the **designed
fallback**. There are live builds. That is not a future risk to avoid; **it is the multi-user
distribution fact the document warns about, already in effect.**

The earlier draft's closing line ("avoid expanding the beta before MUST-1 and MUST-2") addressed only
*future* testers. **The existing ones need an action, and it is now MUST-0d: suspend the builds, revoke
distribution, send the §6.9 notice with the delete request.** Every additional tester converts a
single-user architecture problem into a multi-user distribution fact — and every existing one already
has.

### F. Restrict the App Store territory to the United States? — NEW

**Yes — recommended, and it is 15 minutes (SHOULD-27).**

Everything in §§1–4 and §§6–9 is U.S. law. §5 shows that several conclusions reverse elsewhere: the
sound-recording performance right exists almost everywhere but here; the UK has no fair use and its
private-copying exception was quashed in 2015; the EU database right reaches compilations of
unprotectable facts; moral rights attach to stem separation; GDPR attaches to the guest data the jukebox
already collects.

Restricting availability to the U.S.:

- makes every sentence of §6's copy accurate for its actual audience (today, the PRO notice would tell a
  UK host to call ASCAP);
- converts §5.2–5.5 from live problems into pre-expansion problems;
- narrows GDPR scope materially;
- costs approximately nothing while the beta is a handful of people and the plan is to ship single-user.

Lift it when LATER-33 is done, not before.

---

## 9. What needs an actual lawyer

**None of the above is legal advice.** It is an engineering audit that reads cases. Below are the
questions where the answer changes what gets built, phrased so counsel can answer efficiently. Bring
this document, the §2 scorecard, §4, and the §5 territorial section.

**Ask Q19 first** — it governs how the rest of this conversation should be conducted and recorded.

**On the source (highest priority):**

1. We captured **369** commercial recordings from Apple Music playback to permanent MP3s and served them
   from a public S3 bucket. **§4 computes the statutory-damages range: $276,750 floor (369 × $750) to
   $55.35M (369 × $150,000 willful).** We are deleting them and removing the capability. What is our
   realistic exposure for conduct already completed, and does deletion plus documented remediation
   materially change it?
2. **Willfulness.** `stems-demucs-stemify-spec.md:815` is a contemporaneous internal document that
   identified the public-stem-corpus exposure, ranked mitigations, and said *"do not silently ship (3)"*
   — and (3) shipped with no recorded countervailing rationale. How much does that move the §504(c)(2)
   analysis, and does anything we do now mitigate it?
3. **We cannot answer "was any of it downloaded."** There is no S3 access logging, no CloudFront logging
   (the rips bucket isn't even behind CloudFront), and **no CloudTrail trail at all** (§2). Logging is
   being enabled today (MUST-0b) but answers nothing retrospectively. How does an unquantifiable
   distribution history affect exposure and settlement posture, and is there any other source of
   evidence we should be preserving?
4. **Preservation.** No claim is known. We are taking a full pre-deletion inventory snapshot (MUST-0c)
   and then deleting. Is that the right sequence, is the snapshot sufficient, and what should trigger a
   litigation hold that stops the deletion?
5. **Copies we cannot reach.** TestFlight testers have burned local files (`BurnStore.swift:982`); there
   is no expiry or remote invalidation. We are suspending the builds and asking testers to delete
   (§6.9). Is asking the right move, and does it create any admission problem?
6. Does §1201 attach to capturing decrypted output from Music.app on a licensed device (the analog-hole
   question), or is our exposure purely §106(1)? We found no controlling authority squarely on output
   capture.
7. For **My Digital** — files on the user's own disk with unverifiable provenance — is a recorded
   attestation at ingest sufficient diligence for a personal-library product, or do we need something
   stronger?

**On architecture:**

8. If we implement per-user identity, per-user keys, no cross-user dedup, and short-TTL signed URLs, does
   a **vinyl-only** locker (records the user physically owns, captured by the user, streamed only back to
   that user) present an acceptable risk? Specifically: how much weight does *Aereo*'s "owners or
   possessors" language (573 U.S. at 447–48) actually carry in the Ninth Circuit, which has never adopted
   *Cablevision*'s unique-copy rule?
9. Does **Demucs stem separation** of a lawfully-made personal copy create a §106(2) derivative-work
   problem distinct from the underlying reproduction, if the stems never leave the user's own storage?
10. We plan to serve audio only through short-TTL presigned URLs (300 s) after authentication. Is there a
    TTL or scoping practice you'd want to see, given that "capable of receiving" is the operative test?

**On the jukebox:**

11. If guests receive **only metadata** (titles, artists, queue, history) and hear the music from the
    host's speakers, do you agree the app itself has no performance exposure and the analysis reduces
    entirely to the host's venue licensing — **and does that conclusion hold outside the U.S., where the
    sound recording has its own performance right (§5.2)?**
12. Is our host notice (§6.4) adequately protective, and does the "you and/or your venue" framing create
    any problem given that the PROs generally licence the establishment rather than the DJ?

**On the public catalog:**

13. Tracklists, play histories, BPM/key/beat-grid analysis, and cue points published publicly, with audio
    resolved through the viewer's own subscription — is that the safe line we think it is? (Our model is
    1001Tracklists.) **And does it survive the EU/UK *sui generis* database right (§5.4), both as to our
    ingest of third-party catalogs and as to our own compilation?**
14. **Album art:** we re-host 254×256 thumbnails from Apple (546), Discogs (346), and Wikimedia (268),
    plus embedded ID3 art in the audio files themselves (2.7(c)). Our four-factor sketch is in 2.6.
    Three specific questions: **(a)** does the *Kelly*/*Perfect 10* thumbnail line reach a catalog
    browser that is not performing search-engine indexing, and how much damage does our preference
    inversion do? **(b)** For Discogs, is this governed by contract rather than copyright, and does a
    fair-use finding help us at all against a ToS claim? **(c)** For Wikimedia, does **share-alike**
    (not just attribution) attach when we thumbnail into a distributed catalog — does that create an
    adapted work, and does anything propagate to the index?
15. **Lyrics:** we are unpublishing ~16,200 files. They are two different things — **scraped publisher
    lyrics** and **Whisper transcripts of the vocal stem** (2.5). Are these the same legal object? Is a
    machine transcription a reproduction of the underlying literary work, a §106(2) derivative, or
    something else — and do the word-level *timings* stand differently from the *words*? Is device-local,
    owner-only display acceptable for either, or should the feature be removed?

**On territory (§5):**

16. We ship to the App Store, which is worldwide by default. We propose restricting to the **United
    States** initially (Decision F). Is that sufficient to make the U.S.-law analysis in this document
    the operative one, and what would we need before lifting it — particularly on the UK's absence of
    any private-copying exception since *BASCA* (2015), the EU database right, and moral rights in
    stem separation?
17. **GDPR/UK GDPR:** the jukebox collects guest-typed requests and IP addresses at an endpoint that is
    currently unauthenticated; CloudKit stores profiles and play history. We have drafted a privacy
    policy (§6.11) with placeholders for retention periods and an international-transfer mechanism.
    What do we need — lawful basis, retention, transfer mechanism, and is a controller/processor
    analysis with Apple required for CloudKit?

**On corporate posture and the terms:**

18. **Entity.** The EULA (§6.10) has `[LEGAL ENTITY NAME]`, `[STATE]`, and a liability cap as
    placeholders. Is there a corporate structure worth having before a beta expands beyond friends, and
    what should the governing-law/venue and dispute-resolution clauses say? §9 of the EULA (arbitration
    vs. courts) is explicitly left for you.
19. **This document.** It records in writing that 369 recordings were captured and publicly served, and
    that an internal design doc's "do not silently ship (3)" was not followed. We propose committing it
    to a private git repo (`git@levi.github.com:galxy25/pocketdj.git`) next to the code it audits, where
    history is effectively permanent and un-redactable. **Should it live there at all, should it be
    reframed as an attorney-directed assessment, and is there a privilege posture we should adopt before
    doing any more of this work in writing?** (§0.)
20. **§512:** we have no designated agent and no repeat-infringer policy. Given that we currently have no
    users to terminate, is registering an agent now worthwhile, or should it wait for multi-tenancy? Does
    §512 offer anything at all for a single-user product?
21. Does anything in our design documents or feature naming create **inducement** exposure under
    *Grokster*? Specific concerns: `docs/design/jukebox-hero.md:13` ("a radio station whose distribution
    is S3"), the "📻 On air" button, `BrowseDiscover.swift:144` ("added songs are ripped to the shared
    catalog"), and `stems-demucs-stemify-spec.md:815`. **Related sequencing question:** we plan to rename
    the "Rip" button, but only *after* removing the capture capability, on the theory that renaming first
    could read as concealment (§6.1, Decision D). Do you agree with that ordering?
22. Please review §6.10 (EULA) and §6.11 (privacy policy) for enforceability and completeness — including
    whether Apple's Schedule 1 minimum terms are correctly reproduced in §10 — and tell us whether EULA
    §4.2 as rewritten ("PocketDJ has no feature for distributing your copies to other people") is a
    promise we can safely make, and whether making it creates obligations we should scope more carefully.

---

## Appendix — verification method

Every code claim was checked at the cited line. Live infrastructure claims were re-verified from this
machine during the audit with **`env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY`** —
no credentials of any kind — to establish anonymous reachability rather than assume it. Account-state
claims (logging, versioning, CloudTrail, CloudFront) were verified **with** credentials and are recorded
with the exact command in §2.

**Findings that did not survive adversarial verification** are marked CORRECTED in §3 and stated in
their corrected form: the `RIP_AGENT` autonomy claim (1.8), the "comments misdescribe this as safe"
claim (3.7, **withdrawn**), and the `played` log's §114 status (3.5).

**Findings that verification made stronger:** the lyrics corpus exists in **prod** as well as dev (2.5),
the artwork sources are **mixed** rather than Apple-only (2.6), and the Discover capture surface spans
**two** catalogs rather than one (§4).

**Corrections made in this revision, against the previous draft:**

| # | What changed | Why |
|---|---|---|
| 1 | **Two contradictory verdict tables merged into one** (§1) | §1 graded Pillar 2 "Sound" while §2 graded it VIOLATES. A reader stopping at the first table came away believing two of three pillars passed. |
| 2 | **Pillar 2 downgraded to "under-scoped as written"** (§1, §3 preamble) | Three independent public-surface failures on three CDNs is a scoping defect in the posture, not a single implementation slip. |
| 3 | **3.8 lost two of five credits** | "Hear defaults off" and "the broker gates `streamUrl`" gate a payload field whose value the manifest publishes permanently anyway. They reduce no *capability*, and caveat (c) says capability is the test. Crediting them contradicted the document's own doctrine. |
| 4 | **3.6 re-upgraded `medium` → `high`** | The downgrade rested on a client-side invariant ("no shipped code path emits `hear:false` + https") asserted about a server reporting `"auth":false`. Anyone can mint a session, obtain a `hostKey`, and post arbitrary state. |
| 5 | **A3's rejection rewritten** (Decision A) | It failed A3 on a binary-contents fact (review/distribution) offered as a legal reason. A3 fails legally for the same reason A2 does: §106(1) reproduction already occurred. |
| 6 | **B1's "legally free" narrowed** | That conclusion rests on §114(a) and is U.S.-only. |
| 7 | **Artwork's fair-use call replaced with an actual four-factor analysis** (2.6) | It was the document's only optimistic fair-use call, unargued, with neither *Kelly* nor *Perfect 10* cited, in a document that refuses fair-use optimism everywhere else. |
| 8 | **`mirror-art.mjs` path corrected** (SHOULD-24) | There is no `scripts/mirror-art.mjs`. The file is `.claude/skills/analog-indexer/lib/mirror-art.mjs`; only `scripts/mirror-art.sh` exists at the cited location. |
| 9 | **MUST reordered; MUST-0 created** | A 2-hour fix removing the largest live exposure was listed after a 3–5 day rebuild. |
| 10 | **Capture-capability deletion promoted SHOULD → MUST-5b** | After all twelve original MUSTs the machine could still mass-capture Apple Music via `rip-one.mjs` and two skills. Gating a capability you have decided not to have is incoherent. |

**New verifications performed for this revision** (all reproduce):

| Claim | Method | Result |
|---|---|---|
| No access logging on the rips bucket | `aws s3api get-bucket-logging` | Empty response, exit 0 → **never configured** |
| No versioning on the rips bucket | `aws s3api get-bucket-versioning` | Empty response, exit 0 → **never enabled**; deletes are irreversible |
| No CloudFront logging | `get-distribution-config` ×2 | **`"Enabled": false`** on both |
| Rips bucket is not behind CloudFront | `list-distributions … Origins` | Origins are only the two web buckets + API Gateway |
| **No CloudTrail at all** | `aws cloudtrail describe-trails` | **`[]`** |
| 4 copies of the capture server | `find . -name rip-server.mjs -not -path '*/node_modules/*'` | `scripts/` + 3 worktrees; same for `rip-one.mjs`, `mirror-art.sh`, `mirror-art.mjs` |
| Capture skills remain invokable | `ls .claude/skills/{rip,backfill-rip}/` | Both present; `backfill-rip.mjs:217-218,349` mass-POSTs `/rip-collection` |
| Embedded art extracted to the public bucket | `index-digital-files.mjs:250-266` | ffmpeg `-map 0:v:0` → `/art/<albumId>.jpg` on the web bucket (`:19`, `:266`) |
| `.pdjcollection` carries no audio | `PocketZip.swift:94-105`, `PlaylistZip.swift:115-138` | `pocket.json` + `items.json` from `IndexSong`/`IndexAlbum` metadata structs only — **§6.3 row 11's claim is true** |
| `pocketdj.app` ownership | `host`, registrar WHOIS | Resolves to `216.150.1.1` (parking); **no registration record returned — assume not owned** |
| Git remote | `git remote -v` | `git@levi.github.com:galxy25/pocketdj.git` — **privacy not verifiable from the CLI; confirm on GitHub before committing this file** |

Where a claimed defect turned out to be a correctly-implemented restraint, it is recorded as such in 2.1,
2.8, and 3.8 — the metadata catalogs, the `.pdjcollection` export, the Mix broadcast's refusal to
transmit mixed output, and the `STUDIO_ID` fence. The last of these is the working proof that this
architecture can implement the posture: it is source-aware, enforced at two layers, and its own comment
reasons through precisely the failure mode that Pillar 1 is about.

**What this audit did not examine**, stated so the gaps are known rather than assumed closed:

- The CloudKit public surfaces — public profile, Discover, shared collections (SHOULD-26). §6.5 places a
  footer on them; their contents are unaudited.
- The actual Discogs API/ToS terms (SHOULD-23).
- Whether any third-party analytics or crash SDK is present (needed for §6.11 and the App Privacy label).
- The privacy status of the GitHub remote (Q19).
- Non-US law beyond the survey in §5, which is a structural map for counsel, not an opinion.
