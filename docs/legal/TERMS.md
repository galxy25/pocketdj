# PocketDJ — End User Licence Agreement and Terms of Use

> **DRAFT — NOT LEGAL ADVICE, AND NOT YET PUBLISHABLE.**
>
> This is a working draft for Levi to review and for counsel to finalise. It is written to describe
> PocketDJ **as it is intended to be at public launch**, not as it is today. Every statement that is
> not true of the shipped code and infrastructure right now carries a `#TOUPDATE` comment naming what
> must become true before the sentence may be published.
>
> **Three hard rules before this document goes anywhere near a user:**
> 1. **Resolve every `{{PLACEHOLDER}}`.** They are listed in full at the end. A placeholder that ships
>    is worse than silence — an unmonitored copyright address in particular is affirmative evidence
>    against the repeat-infringer policy §512(i) requires.
> 2. **Clear every `#TOUPDATE`.** Publishing a description of a system that has not been built converts
>    an architecture problem into an evidence problem. Grep for `#TOUPDATE` and confirm each one against
>    the code before submission.
> 3. **Clear them by claim, not by section.** The grep is only as good as the marker coverage, and the
>    prior draft's coverage had a systematic hole: a claim was marked where it first appeared and left
>    bare where it was restated. §6.4 was marked while the same claim sat unmarked in §6.3 and §8.2;
>    §6.7 was marked while §8.1 restated it bare; §7.1 was marked while §7.3 repeated it. **Before
>    clearing any marker, grep for the claim's own words across all four legal documents** — the
>    sentence usually lives in three places, and clearing one leaves the others in the text.
>
> **Two sections are submission blockers in their own right**, independent of anything above: §3.4
> (in-app profile deletion, Guideline 5.1.1(v)) and §8.6 (user-generated content controls, Guideline
> 1.2). Neither exists in the code. A third, §5's stem separation, is a licensing blocker rather than a
> review one — see Third-Party Notices §9.1.
>
> **This document must agree with its siblings.** The Privacy Policy, the Copyright and DMCA Policy,
> and the Third-Party Notices describe the same product to the same reader. Where they disagree, the
> disagreement is the finding. Counsel questions are listed at the end.

**Effective date:** {{EFFECTIVE_DATE}}

---

## The short version

PocketDJ is a personal music library and DJ app. It organises and plays music you already have —
records you have digitised, audio files you own, and your Apple Music library.

- **PocketDJ does not sell you music and does not license music to you.** You bring your own.
- **You must have the rights to everything you put into it.** That is the single most important thing
  in this agreement, and §6 spells it out.
- **Your music stays yours.** You give us only the narrow permission we need to store, process, and
  play it back to you. Nothing broader.
  <!-- #TOUPDATE: the licence grant is genuinely narrow, but "we need to store, process, and play it
       back to you" describes a system that keeps your copies to itself, and today the storage is a
       single shared bucket readable by anyone. Same preconditions as §6.4 and §6.5. A summary
       inherits the defects of what it summarises, and this is the line a user actually reads. -->
- **Apple Music is for listening.** PocketDJ plays it through your own subscription. It does not
  record it, capture it, or keep a copy.
  <!-- #TOUPDATE: true only after the server-side Apple Music capture path and the Discover add-then-capture flow are removed from both the backend and the shipped client, and the existing captured objects are deleted. Restated in §6.7 (marked) and §8.1 (was unmarked) — clear all three together. -->
- **A jukebox session is for a private event you are hosting.** If your event needs a
  public-performance licence, that is yours (or your venue's) to hold. PocketDJ cannot get one for you.
  If you switch on listen-along, your guests hear the track on their own phones — §7.5.
  <!-- #TOUPDATE: the listen-along clause is honest but describes a feature whose access controls do
       not exist (§7.1, §7.5). Delete the clause if the Jukebox tab is gated out of v1.0. -->

The short version is a summary, not a substitute. The full terms below govern.

---

## 1. This agreement

**1.1** These Terms are a legal agreement between you and {{LEGAL_ENTITY}} ("PocketDJ", "we", "us",
"our"), covering the PocketDJ application on iPhone, iPad, Mac, and Apple Vision Pro, together with
the PocketDJ cloud services the app uses (collectively, the "**App**").
<!-- #TOUPDATE: "cloud services" overstates the arrangement, and it is the phrase a plaintiff would use
     to argue these are our own acts rather than a vendor's. Object storage and content delivery are
     commercial vendors. The tier that performs capture, stem dispatch, search proxying, and jukebox
     brokering is a personal Mac on a residential connection, reached over a Tailscale Funnel hostname
     that is compiled into the shipped client. Before this phrase may be published unqualified: move
     that compute to hosted infrastructure, or describe the arrangement accurately here, in §5, in §6.3,
     and in the Privacy Policy. The same correction is owed to the Privacy Policy's use of the term. -->

**1.1a Who we are, for the law.** {{LEGAL_ENTITY}} of {{BUSINESS_ADDRESS}} is the licensor of the App,
the **data controller** for the personal data described in the Privacy Policy, and the **trader** for
the purposes of EU and UK consumer law. Contact details are in §20.
<!-- #TOUPDATE: this clause cannot be published until {{LEGAL_ENTITY}} and {{BUSINESS_ADDRESS}} resolve.
     EU trader identification and GDPR Art. 13 controller identification both require a real,
     deliverable address, and both make it public. See counsel questions 1 and 2. -->

**1.1b PocketDJ is built and operated by one person.** "We", "us", and "our" are drafting conventions
for {{LEGAL_ENTITY}}; they do not describe a company, a team, or a staff. Nothing in this agreement
should be read as a representation that any particular resourcing, staffing, or operational capacity
stands behind the App.

**1.2 This agreement is with us, not with Apple.** Apple Inc. is not a party to it. Apple is not
responsible for the App or its contents. See §19 for the complete set of Apple-required terms.

**1.3 Acceptance.** By downloading, installing, or using the App, you accept these Terms. If you do
not accept them, do not use the App. Where the App asks you to confirm a specific statement — for
example the rights attestation in §6.1 or the event-licensing acknowledgement in §7.2 — that
confirmation is part of this agreement.

**1.4 Related documents.** The following are incorporated into this agreement by reference:

- the [PocketDJ Privacy Policy]({{PRIVACY_POLICY_URL}}) — what data the App collects and why;
- the [PocketDJ Copyright and DMCA Policy]({{DMCA_POLICY_URL}}) — the full notice, counter-notice, and
  repeat-infringer procedure. §9 below is a summary of it. **Where §9 and the DMCA Policy differ, the
  DMCA Policy governs**, including its statement of what §512(c) does and does not cover;
- the [PocketDJ Third-Party Notices]({{NOTICES_URL}}) — the open-source and third-party licences that
  cover components of the App. Some of those licences impose conditions on you as an end user, and by
  using the App you agree to comply with them.

Apple's own terms — including the Apple Media Services Terms and Conditions that govern Apple Music
playback — apply to your use of Apple's services through the App, and are between you and Apple.

---

## 2. Eligibility and age

**2.1** You must be at least {{MINIMUM_AGE}} years old to use the App. If you are under the age of
majority where you live, you may use it only with the involvement of a parent or legal guardian, who
accepts these Terms on your behalf and is responsible for your use of the App.

**2.1a Higher local age thresholds apply where the law sets them.** PocketDJ is not directed to
children under 13 and we do not knowingly collect their personal information. In the European Union
and the United Kingdom, the age of consent for information-society services is between 13 and 16
depending on the country; **where the applicable age in your country is higher than {{MINIMUM_AGE}},
that higher age governs**, and we do not offer the App below it. This clause is drafted to track
[Privacy Policy]({{PRIVACY_POLICY_URL}}) §14; if the two ever diverge, the Privacy Policy's age
statement is the one to correct against.
<!-- #TOUPDATE: {{MINIMUM_AGE}} must be resolved together with the App Store age rating
     ({{AGE_RATING}} in the Privacy Policy) and with Privacy Policy §14, in one pass. A flat minimum
     here contradicts the Privacy Policy's country-variable floor the moment the placeholder resolves.
     There is also no age gate of any kind in the shipped app — nothing collects or checks an age. -->

**2.1b** Nothing in this section is enforced by the App today.
<!-- #TOUPDATE: there is no age gate, no date-of-birth collection, and no parental-consent flow in the
     shipped client. §2.1 and §2.1a are contractual statements with no technical enforcement behind
     them. Decide before submission whether an age gate ships or whether these clauses are honestly
     described as self-attestation. -->

**2.2** You must not use the App if you are barred from doing so under applicable law, or if we have
previously terminated your access under §11.

---

## 3. Your profile

**Vocabulary, fixed deliberately.** PocketDJ does not ask you to create an account with us. It creates
a **profile** — a randomly generated identifier and a display name you choose — so your library can
sync across your devices and so jukebox guests know whose session they are in. This document uses
"profile" throughout, matching [Privacy Policy]({{PRIVACY_POLICY_URL}}) §13. Where these Terms say
"account" without qualification, they mean your PocketDJ profile; your **Apple Account** is a separate
thing, held with Apple, and we never see its credentials.
<!-- #TOUPDATE: the noun matters legally, not just editorially. App Review Guideline 5.1.1(v) attaches
     to "account creation", and a durable synced identifier with a display name that is published to a
     public guest page is very likely to be read as account creation regardless of what we call it.
     Do not resolve this contradiction by renaming the thing — resolve it by shipping §3.4. -->

**3.1** Some features require a profile. You are responsible for the accuracy of what you give us and
for everything done through your profile.
<!-- #TOUPDATE: there is currently no user identity of any kind at the backend. The backend authenticates with a single shared token and no request carries a user identifier. This section is meaningless until per-user authentication (a server-derived identity, never client-supplied) ships and the client attaches it to storage and processing requests. -->

**3.2** Tell us promptly at {{SUPPORT_EMAIL}} if you believe your profile has been misused or your
device compromised.
<!-- #TOUPDATE: FORWARD-LOOKING. There is nothing to compromise and nothing we could do about it. A
     profile is a local identifier synced through the user's own private iCloud database; there is no
     server-side session, no credential, and no per-user record we could lock, revoke, or restore.
     This clause presumes the per-user authentication in §3.1. -->

**3.3** Do not share access to your device, your profile, or your synced library in order to give
another person access to the music stored under it. That is a distribution of your copies, and §8
prohibits it.
<!-- #TOUPDATE: this originally read "do not share your credentials". There are no credentials — no
     password, no token, no sign-in of any kind exists for a PocketDJ profile. Restore the credential
     wording only once §3.1's authentication ships; until then the prohibition is drafted against the
     conduct rather than against a mechanism that does not exist. -->

**3.4** You may delete your profile at any time, from **Settings ▸ Profile ▸ Delete Profile**. §11.4
explains what happens to your Content when you do.
<!-- #TOUPDATE: FORWARD-LOOKING AND REQUIRED FOR SUBMISSION. THIS FLOW DOES NOT EXIST — there is no
     Delete Profile action anywhere in the client. App Review Guideline 5.1.1(v) requires in-app
     account deletion for any app supporting account creation, and §3's own note explains why the
     profile is likely to be read as account creation. Privacy Policy §13 carries the matching marker
     and the dependency: the server-side half of deletion is impossible until per-user storage keys
     and per-user auth exist (§6.4), because nothing today identifies which stored objects belong to
     which user. Deletion must reach all four of: the CloudKit profile and session records, the
     server-side stored audio and derivatives, jukebox sessions, and local files. -->

**3.5** Until §3.4 ships, you can email {{CONTACT_EMAIL}} and ask us to delete everything we hold, and
we will. This is the interim path, not a substitute for the in-app one.

---

## 4. Licence to use the App

**4.1 Scope of licence.** We grant you a personal, limited, non-exclusive, non-transferable,
revocable licence to use the App on Apple-branded devices that you own or control, as permitted by
the Usage Rules in the Apple Media Services Terms and Conditions — including the Family Sharing and
volume-purchase provisions of those rules. This licence is for your own use. It grants you no rights
in the App's code, design, name, or logo.

**4.2 What you may not do with the App.** Except where applicable law expressly permits it despite
this restriction, you may not copy the App (other than as this licence allows), modify it, translate
it, reverse-engineer, decompile, or disassemble it, attempt to derive its source code, rent, lease,
lend, sell, redistribute, or sublicense it, or remove or obscure any proprietary notice in it.

**4.3 Updates.** We may issue updates, and some may be required for the App to keep working. Features
may change or be removed.

**4.4 No music licence.** This licence covers software. **It does not grant you any right in any
musical work or sound recording, and it does not license any use of music — including reproduction,
distribution, or public performance.** Those rights, where you need them, come from the rights holders
or their licensing organisations, not from us.

---

## 5. What the App does

Stated plainly, so the rest of this document has something concrete to attach to:

- It catalogues music you bring in from your own sources: recordings you make from your own records,
  audio files you own, and your Apple Music library.
- It processes that audio to make it useful — transcoding it for playback, measuring tempo, key, beat
  grid, and waveform, separating it into stems when you ask, and transcribing lyrics when you ask.
  Some of that processing happens on your device and some happens on PocketDJ cloud services; §6.8
  says which.
  <!-- #TOUPDATE (stems): stem separation is presented here and in §6.3(4) as a shipped, licensed
       capability. It is shipped; it is not established as licensed. The separator's pretrained
       weights are granted for scientific purposes only — not under the MIT licence that covers the
       surrounding source — and PocketDJ is a commercial App Store application. Third-Party Notices
       §9.1 rates this BLOCKING and lists the options; "ship anyway" is expressly not one of them.
       Before stem separation may be described in a published EULA: replace the weights with a
       commercially-clear model, obtain a licence, train our own, or cut the feature. Note the
       coupling — cloud lyric transcription runs over the vocals stem, so cutting stems cuts that too.
       See counsel question 16. -->
  <!-- #TOUPDATE (cloud services): see §1.1. The stem, analysis, lyric, and capture work is dispatched
       through a personal machine on a residential connection, not a contracted service provider. -->
- It plays music back to you, on your devices, including offline.
- It publishes a catalogue of **information about recordings** — never audio (§6.6).
- It runs a request line ("jukebox") for private events you host (§7).

---

## 6. Your music and your rights

**This section is the point of this agreement. Read it.**

### 6.1 You must have the rights to everything you put into PocketDJ

By importing, uploading, recording, digitising, or otherwise adding any audio, artwork, lyrics, or
other material to the App (your "**Content**"), **you represent and warrant that you own it or have
obtained all rights, licences, consents, and permissions necessary** for you to add it to the App and
for us to handle it as §6.3 describes, and that doing so does not and will not infringe or violate
anyone else's rights.

In practice, this means Content that comes from:

- **records, tapes, or discs you own**, recorded by you from your own copy;
- **audio files you bought or otherwise lawfully acquired**;
- **recordings, mixes, samples, and performances you made yourself**; or
- **material you have express permission from the rights holder to use**.

It does **not** include music obtained from a streaming subscription. A subscription licenses you to
*listen*. It does not license you to keep a copy, and PocketDJ will not import from one (§6.7).

**We cannot verify this for you, and we do not try.** You take sole responsibility for determining,
obtaining, and complying with any third-party terms that apply to your Content — including the terms
of any service, marketplace, or label it came from. To the fullest extent permitted by law, we exclude
all liability arising from Content that users bring into the App, including claims for infringement of
intellectual property rights. Your indemnity in §14 covers this.

*(A note on wording: this document says "import", "upload", "add", and "record". It deliberately does
not use "rip", which in DJ software is the industry's own term for the infringing act — rekordbox's
EULA lists it in scare quotes as prohibited conduct. The in-app vocabulary must be changed to match.)*
<!-- #TOUPDATE: FORWARD-LOOKING, AND THE RENAME HAS NOT STARTED. This sentence previously read "is
     being changed to match", a present-progressive claim about work that is not underway. The shipped
     build still exposes "Rip server URL", "Rip from cloud source", and "Rip server" in Settings, and
     "Rip"/"Burn" in the collection UI. Worse for §6.7 and §8.1 than for this note: the shipped
     Settings screen contains the user-visible string "songs that match your Apple Music library are
     captured from Apple Music (real-time, one at a time)", alongside the toggle that drives it. The
     product describes the capture in its own interface while this document denies it. A screenshot of
     that screen next to §6.7 is the whole case. Complete the rename AND remove the capture path before
     either sentence is published. -->

### 6.2 You keep ownership

**Your Content is yours.** Nothing in this agreement transfers ownership of it to us, and we claim no
ownership interest in it. As between you and us, you keep every right you had before you added it.

Stems, transcripts, analysis, waveforms, beat grids, edits, cue points, and mixes that the App
produces from your Content are treated the same way: yours, held under the same rights (and the same
limitations) as the material they were derived from.

### 6.3 The licence you give us — and its limits

To run the App for you, we need your permission to do certain specific things with your Content. You
grant us a **non-exclusive, worldwide, royalty-free licence to do only the following, and only for the
purpose of operating the App for you:**

1. **store** your Content in the storage assigned to your profile;
   <!-- #TOUPDATE: FORWARD-LOOKING AND MATERIALLY UNTRUE TODAY — the same defect as §6.4, restated
        here, and the §6.4 marker does not reach this line. There is no storage assigned to anyone.
        Keys are a pure function of a content id in one shared bucket with public read and no
        signing. Requires the per-profile storage namespaces named in the §6.4 marker. -->
2. **transcode and reformat** it into the formats the App plays and streams;
3. **analyse** it to produce tempo, musical key, beat grid, waveform, and similar measurements;
4. **separate it into stems**, when you ask for that;
   <!-- #TOUPDATE: this limb grants us permission we may not lawfully exercise. See the stems marker
        in §5 — the separator's pretrained weights are licensed for scientific purposes only and
        Third-Party Notices §9.1 rates commercial use BLOCKING. Your permission to us does not cure
        a defect in our own upstream licence. -->
5. **transcribe** its lyrics or speech, when you ask for that;
   <!-- #TOUPDATE: cloud transcription runs over the vocals stem and therefore inherits limb 4's
        licence problem. On-device transcription does not. -->
6. **make the technical copies** required for backup, caching, error correction, and delivery; and
7. **serve it back to you** on your devices.

**That is the entire list.** The licence is worldwide only because storage and delivery infrastructure
is; it is royalty-free only because neither of us pays the other for it. It lasts as long as you keep
the Content in PocketDJ and **ends when you delete it** (§11.4).

**What we do not get, and are not asking for:**

- No right to sell, license, sublicense, publish, distribute, publicly perform, or publicly display
  your Content.
- No right to use it in advertising, marketing, or promotion.
- No right to use it to train machine-learning models.
- No right to make it available to any other user.
  <!-- #TOUPDATE: FORWARD-LOOKING AND MATERIALLY UNTRUE TODAY. Two independent defects, either one
       fatal. (1) The audio storage bucket carries a policy allowing anonymous read on the audio
       prefix, all four public-access-block flags are off, and an unauthenticated request for the
       manifest succeeds and returns the complete key index for every audio file, stem, cut, and
       transcript. Content is therefore available to every other user, and to everyone else, right
       now. (2) The App ships listen-along: a host toggle streams a public audio URL to jukebox
       guests, which is a feature whose entire purpose is making Content available to other users.
       Privacy Policy §9.3 documents it as shipped. Before this limb may be published: the prefix
       must be private with authenticated delivery, and listen-along must either be removed or be
       carved out of this sentence and described honestly as a user-directed sharing feature. -->
- No right that survives your deletion of the Content, other than as §11.4 describes for backups
  already made.

We use vendors — object storage and content delivery — to do the things on the list above. They act on
our instructions and acquire no independent rights in your Content.
<!-- #TOUPDATE: this sentence previously said "service providers — cloud storage, compute, and content
     delivery". Storage and delivery are genuine commercial vendors. Compute is not: capture, stem
     dispatch, search proxying, and jukebox brokering run on a personal machine on a residential
     connection. Characterising that as a contracted service provider is an invented fact about the
     operating arrangement, and it is precisely the sentence a plaintiff would quote to argue that the
     acts are the operator's own rather than a vendor's. "Compute" has been removed pending either a
     real hosted tier or an accurate description. See §1.1. -->

*(Drafting note for counsel: this is deliberately narrower than the market. Serato's terms take a
"non-exclusive, royalty-free, worldwide and perpetual" licence including the right to perform and
publish; rekordbox takes a transferable, sublicensable grant. A personal music locker has no business
asking for either, and a broad grant would contradict §6.5. If counsel adds anything to the list, the
addition should be traceable to a feature that actually needs it.)*

### 6.4 Your copies are yours

Audio you add to PocketDJ is stored in storage assigned to your profile and is served back only to
devices signed in to that profile. **The App has no feature that gives another user access to your
copies without your direction, and no feature that publishes them.** Where two users happen to have the
same recording, each has their own copy in their own storage; we do not collapse them into a shared one.
<!-- #TOUPDATE: FORWARD-LOOKING AND MATERIALLY UNTRUE TODAY. Storage keys are a pure function of a content id in a single shared bucket with public read and no signing; a second user's import short-circuits to the first user's object; the stem worker dedupes on song id. Before this paragraph may be published: per-profile storage namespaces, per-profile authenticated delivery (no unsigned public object URLs), and removal of cross-user dedup for audio and derived artifacts. Note the added words "without your direction" — they carve out listen-along (§7.5), which must be described, not denied. -->

Sharing in PocketDJ is limited to **information about music** — tracklists, playlists, collections,
and listening history — **except for listen-along, which shares audio and is described in §7.5.**
Exported collections carry metadata only; whoever opens one plays the music from their own library or
their own subscription.
<!-- #TOUPDATE: this paragraph previously claimed sharing was limited to information about music, full
     stop, and the §6.4 marker above it covers only the storage paragraph by its own wording. That
     claim is false while listen-along ships: a host toggle streams audio to guests. The carve-out
     added here is the honest drafting, but it is only honest once §7.5 and its controls exist. If
     listen-along is cut for v1.0, delete the carve-out and §7.5 and restore the flat sentence. -->

### 6.5 We do not distribute your music

We will not make your Content available to other people **except where you direct us to** — today that
means listen-along (§7.5), and nothing else. We may disclose or produce Content only where the law
requires it, where you direct us to, or where it is necessary to respond to a valid legal claim.
<!-- #TOUPDATE: THE LARGEST UNMARKED GAP IN THE PRIOR DRAFT, AND THE PROMISE MOST LIKELY TO BE
     LITIGATED. This paragraph previously read "We will not make your Content available to other
     people, and we have no feature that does." Both halves were false, on independent grounds, and
     the section carried no marker at all while the narrower §6.4 above it carried one.
     (1) INFRASTRUCTURE: the audio bucket's policy allows anonymous read on the audio prefix, every
         public-access-block flag is off, and an unauthenticated GET of the manifest returns the
         complete key index — roughly 1.3 MB enumerating every audio file, stem, cut, and transcript.
         Your Content is available to other people at this moment, whatever this sentence says.
     (2) FEATURE: listen-along is exactly "a feature that does". The host toggle exists in the shipped
         client, the broker hands guests a public audio URL, and the guest page plays it in an <audio>
         element. Privacy Policy §9.3 documents it as shipped, which means these two documents
         contradicted each other in the reader's hand.
     Before this section may be published: make the prefix private, stop serving the manifest
     anonymously, put authenticated per-profile delivery in front of audio, and gate listen-along per
     §7.5. If listen-along is cut, restore the absolute wording — it is much the stronger promise, and
     it is worth having. -->

**Neither half of this promise is enforced by anything but this sentence today.** If you have added
Content to PocketDJ before the controls in §6.4 and §7.5 ship, assume it is reachable by anyone who
knows or can enumerate its location.
<!-- #TOUPDATE: delete this paragraph once §6.4 and §7.5 are true. It exists so that no reader can be
     misled during the interval, and so that the interval is uncomfortable enough to be closed. -->

### 6.6 The public catalogue is metadata only

PocketDJ publishes a browsable catalogue of **facts about recordings** — titles, artists, albums,
release information, tempo, musical key, beat grid, mood keywords, and similar analysis — so that
people can see how a collection is built and be inspired by it.

**The public catalogue never contains audio, and it never links to anyone's audio files.** If you see
something in it you want to hear, look it up on your own music service.
<!-- #TOUPDATE: true of the catalogue documents themselves, which carry no audio locations — but NOT of the infrastructure as a whole. A separate storage prefix currently serves audio, stems, and transcripts to anonymous requests, and a public manifest enumerates every key. Before this paragraph may be published: that prefix must be made private and the manifest must stop being publicly fetchable. -->

**What "the catalogue" actually publishes is broader than the list above.** Alongside the facts about
recordings, the public web buckets currently also serve **lyric and speech transcripts** (on the order
of sixteen thousand files) and **mirrored cover artwork** (on the order of eleven hundred images).
<!-- #TOUPDATE: FORWARD-LOOKING AS DRAFTED, AND THE OMISSION WAS THE PROBLEM. The enumeration in this
     section named only facts about recordings, and the marker above named only the audio prefix and
     the manifest — so a reader would conclude that lyrics and artwork are not published. They are.
     Lyrics are the copyrighted expression of the song, not a fact about it, and publishing a corpus
     of them is a distinct reproduction and distribution exposure from anything else in this document;
     mirrored artwork is a separate one. Conformance §2, Pillar 2, findings 2.4–2.7. Before this
     section may be published in any form: either take the transcript and artwork corpora off the
     public buckets, or state plainly what is published and under what claimed right. Do not resolve
     it by leaving them out of the enumeration. -->

Artwork shown in the catalogue is displayed under the terms of its source and remains the property of
its owners. Nothing in the catalogue is licensed for redistribution.

### 6.7 Apple Music is playback only

When you play a song from Apple Music in PocketDJ, it plays **through Apple Music, using your own
subscription**. PocketDJ does not record it, capture it, download it, transcode it, or store a copy of
it, and it provides no means for you to do so. Apple Music tracks cannot be added to your offline
library, because a subscription lets you listen — it does not let you keep a copy.
<!-- #TOUPDATE: FORWARD-LOOKING AND MATERIALLY UNTRUE TODAY. The backend contains a real-time Apple Music capture path, and the Discover "+ Add" flow adds a catalogue song to the user's library specifically so the backend can capture it. Before this paragraph may be published: both paths must be removed from the backend and the shipped client, capture must fail closed for Apple Music sources, and previously captured objects must be deleted. -->

At your direction, PocketDJ can make changes to your own Apple Music account — adding a song or album
to your library, adding songs to your playlists, or setting a favourite or rating. Those are changes
you asked for in your own account, made through Apple's own interfaces. They are not copies, and we do
not receive the music. Some of them, such as marking a song as a favourite in Apple Music, **cannot be
undone by an app** — Apple provides no way to reverse them — so treat them as permanent.

### 6.8 What leaves your device

We think you should be able to tell, **without reading the privacy policy, which of your audio stays
put and which does not.** This section is about audio only. It is not a summary of everything the App
collects — your search queries and our server logs, among other things, are covered by the
[Privacy Policy]({{PRIVACY_POLICY_URL}}) and by the App Store privacy label, and both are declared
there. Read them for the complete picture.
<!-- #TOUPDATE: the framing above over-promised against the privacy label, which declares Search
     History and Diagnostics ▸ Other (server logs) as collected while this section mentioned neither.
     The scope limiter added here is the minimum fix. The Privacy Policy's Appendix B rule — that the
     policy, the label, and the app's privacy manifests must all agree — should be extended to cover
     this document too, so that a change to any one of the four forces a check of the others. -->

**Stays on your device:** the audio of microphone recordings you make in Studio, the audio of mixes
you record, rendered instrumentals, and on-device lyric transcription. Apple's Speech framework is used
in on-device mode only; your audio is not sent to Apple for transcription.

**Stays on your device as audio, but syncs as a document:** your recorded mix *sessions*, your saved
playback session, your mix deck state, and your cue points. The audio takes do not leave your device.
The documents that describe them — what was loaded on each deck, where the cue points sit, what the
fader was doing — sync to your own private iCloud database, the same way your library organisation
does.
<!-- #TOUPDATE: cue points and recorded mixes were previously listed flatly under "stays on your
     device", which reads as "does not leave the device" and is wrong for the session documents. The
     app syncs mix-sessions, playback-session, and mix-decks documents to CloudKit. This is the user's
     own private database and we cannot read it — so the privacy exposure is small — but the sentence
     as drafted was false, and §6.8's whole promise is that a user can trust this list without reading
     further. Verify this split against the sync document list before publishing; if the set of synced
     documents changes, this paragraph changes with it. -->

**Goes to PocketDJ cloud services, because the feature requires it:** audio you import for your
library; audio you send for stem separation, tempo/key analysis, or cloud lyric transcription — **and
that includes your own microphone recordings and recorded mixes if you choose to run stem separation
on them.** If you do not want a recording to leave your device, do not send it for processing.
<!-- #TOUPDATE: the App does not currently tell the user, at the point of action, that a microphone recording or a recorded mix is being uploaded when they tap Stemify on it. This paragraph is honest about the behaviour, but the in-app disclosure and consent it implies has not been built. -->

**Goes to Apple, not to us:** song recognition sends a derived acoustic signature — not your
microphone audio — to Apple's Shazam service. Your library organisation, playlists, favourites, and
play history sync to **your own private iCloud database** under your Apple Account, which we cannot
read.

The [Privacy Policy]({{PRIVACY_POLICY_URL}}) has the complete picture, including retention.

---

## 7. Jukebox sessions and event licensing

### 7.1 What a jukebox session is for

A jukebox session is for a **private event you are hosting**. Your guests scan a code, see what is
playing, and send you requests. You decide what plays. The music comes out of your speakers — and, if
you switch on listen-along, out of your guests' phones as well (§7.5).
<!-- #TOUPDATE: "The music comes out of your speakers" was drafted as a complete description of where
     the audio goes, and listen-along makes it incomplete. Restore the flat sentence if listen-along
     is cut for v1.0. -->

Sessions are access-controlled by default, capped in the number of listeners they admit, and expire
automatically. They are not indexed, not enumerable, and not intended to be shared beyond the people
at your event.
<!-- #TOUPDATE: FORWARD-LOOKING. The guest-facing endpoints have no token at all today; the token that exists gates session creation only and is empty by default. There is no listener cap anywhere in the code. Expiry is real for ordinary sessions but "timeless" sessions never expire and never delete. Before this paragraph may be published: a guest token required by default on both the request endpoint and the state fetch, a real concurrent-listener cap, and a bounded lifetime for every session including timeless ones. -->

### 7.2 You are responsible for the licences your event needs

**PocketDJ does not license music to you and cannot obtain a licence on your behalf.** Playing music
where the public can hear it is a public performance, and it requires a licence — normally held by the
venue.

- In the **United States**, that means a licence covering the songwriting, from ASCAP, BMI, SESAC, or
  GMR.
- **Outside the United States you will usually need two licences** — one for the songwriting and a
  separate one for the sound recording. For example: PRS and PPL in the United Kingdom (sold together
  as TheMusicLicence), GEMA and GVL in Germany, SACEM and SCPP in France, APRA AMCOS and PPCA in
  Australia, SOCAN and Re:Sound in Canada.

A private party for your own friends and family generally does not need one. A bar, club, ticketed
event, corporate function, or paid DJ engagement generally does — **even if it is invitation-only**. If
you are being paid to DJ, confirm the venue's licence in writing before the gig.

**You take sole responsibility for determining, obtaining, and complying with every licence, consent,
and permission your event requires.** You and your venue may both be liable if it is unlicensed, and
the penalties can be substantial. A streaming subscription is not a performance licence.

### 7.3 No broadcasting

You may not use the App to broadcast, webcast, simulcast, or otherwise transmit music to people who
are not present at your event. The jukebox is a request line for a room you are in. If you want to
stream a DJ set to a remote audience, use a platform that runs a licensed DJ programme.
<!-- #TOUPDATE: FORWARD-LOOKING. This prohibition is aimed at conduct the App is currently built to
     perform. Listen-along transmits the host's audio to whoever holds the session URL, over an
     unauthenticated public address with no listener cap and, for "timeless" sessions, no expiry. A
     guest need not be present at the event, and nothing checks. §7.1's marker names the controls that
     must ship; until they do, this section prohibits the user from doing what the product does for
     them by default, which is not a defensible position to publish. -->

### 7.4 Your guests

If you host a session, you are responsible for how you run it. Guests submit requests through a web
page; what we collect from them, and for how long, is described in the
[Privacy Policy]({{PRIVACY_POLICY_URL}}), and the request form links to it. Do not use a session to
collect information from guests that the request line does not ask for.

### 7.5 Listen-along

A host can switch on **listen-along**, which lets guests in a session hear the current track on their
own phones. It is **off by default**, only the host can turn it on, and when it is on, guests stream
the host's own copy of the track for the duration of the session.

This is a **transmission of the recording**, not a metadata feature. Three consequences follow, and you
should read all three before switching it on:

- **It is your transmission.** You are directing us to make your Content available to those guests.
  §6.5's promise not to distribute your music is subject to this, and only to this.
- **It may need a licence your event does not have.** §7.2's performance-licensing analysis applies to
  listen-along at least as strongly as it applies to your speakers, and a transmission may engage
  rights that a room-only performance does not.
- **It is not a broadcast service.** It is for guests at your event. §7.3 still prohibits transmitting
  to people who are not there, and turning listen-along on does not license you to publish a session
  URL to a general audience.

<!-- #TOUPDATE: FORWARD-LOOKING ON EVERY LIMB, AND NEWLY WRITTEN BECAUSE THE FEATURE WAS ABSENT FROM
     THIS DOCUMENT ENTIRELY. The prior draft did not describe listen-along anywhere; it denied it in
     §6.5, in §7.1, in §7.3, and in §8.2, while the Privacy Policy §9.3 documented it as shipped. The
     denial-by-silence was the single largest disagreement between the two documents.
     Before this section may be published as drafted: "off by default" is true; "only the host can turn
     it on" is true; "guests in a session" is NOT true — the guest endpoints require no token, so the
     audience is anyone with the URL, the audio URL handed to guests is a public unauthenticated
     address that remains valid after the session ends, there is no listener cap, and timeless sessions
     never expire. All of that is the same control set §7.1 and Privacy Policy §9.3 already flag.
     The recommendation on the table is to gate the Jukebox tab out of v1.0. If that is taken, delete
     this section, delete the carve-outs added to §6.4, §6.5, §7.1, and §8.2, and restore the absolute
     wording in each — it is materially stronger drafting and it costs nothing once the feature is
     gone. Do not ship the carve-outs and the ungated feature together. -->

---

## 8. Acceptable use

You agree not to do any of the following, and not to help anyone else do them.

**8.1 Rights you do not have.**

- Add to the App any music, artwork, lyrics, or other material you do not own or have permission to
  use (§6.1).
- **Use the App, or attempt to use it, as a way to obtain music you do not have the rights to.** This
  includes trying to make the service fetch, capture, or produce a recording you did not supply, and
  trying to reach another user's stored copies.
  <!-- #TOUPDATE: FORWARD-LOOKING. Both limbs prohibit conduct that currently requires no effort at
       all. "Making the service fetch or capture a recording you did not supply" is a shipped feature
       path, not an attack (see the marker below). "Trying to reach another user's stored copies"
       describes fetching a public URL from a public manifest — there is nothing to circumvent, so
       there is nothing an ordinary reader would recognise as prohibited conduct. A prohibition
       against walking through an open door is not an access control, and it will not be read as one.
       Requires the §6.4 controls before it means anything. -->
- Record, capture, re-record, transcode, or otherwise retain audio from a streaming service, including
  Apple Music. PocketDJ provides no means of doing this, and you may not use it to attempt it.
  <!-- #TOUPDATE: FORWARD-LOOKING AND MATERIALLY UNTRUE TODAY — the same assertion §6.7 carries a
       marker for, restated here bare. "PocketDJ provides no means of doing this" is a statement of
       fact about our own product, made to rights holders and to App Review, and it is false: the
       Discover "+ Add" path in the shipped client adds a catalogue song to the user's Apple Music
       library and then requests a capture of it, end to end, with no user circumvention involved.
       The shipped Settings screen describes this in its own words to the user. Before this sentence
       may be published: the backend capture path and the client add-then-capture flow must both be
       removed, capture must fail closed for Apple Music sources, and previously captured objects must
       be deleted — identical preconditions to §6.7. Clearing §6.7's marker without clearing this one
       leaves the false claim in the document. -->
- Circumvent, disable, or interfere with any digital rights management, encryption, access control, or
  other technical protection measure — in the App or in any service it connects to.

**8.2 Distribution.**

- Distribute, publish, upload, broadcast, publicly perform, or make available to the public any music
  in your library, through the App or by using it.
- Share access to your profile, or share a session link outside your event, in order to give another
  person access to your stored music.
  <!-- #TOUPDATE: FORWARD-LOOKING, and reworded twice over. (1) "Account credentials" named a thing
       that does not exist — there are no credentials (§3.3). (2) A flat ban on sharing "any session
       link" prohibits the ordinary use of a feature we ship: listen-along works by the host sharing
       the session link, and §7.5 permits it for guests at the event. The "outside your event" limiter
       is what makes the prohibition survivable alongside the feature. It is also currently
       unenforceable — the link is unauthenticated, uncapped, and for timeless sessions permanent, so
       whether it stays inside the event is entirely up to the person holding it. §7.1's controls are
       the precondition. -->
- Use the App as a file-sharing service, a music locker for someone else, or a distribution point of
  any kind.

**8.3 The service itself.**

- Scrape, harvest, bulk-download, mirror, or systematically extract the catalogue or any other part of
  the service.
- Probe, scan, or test the security of the service; attempt to gain unauthorised access to any
  account, system, or data; or interfere with the service's operation.
- Use bots, scripts, or automated means to generate load, submit requests, or drive processing beyond
  ordinary personal use.
- Resell, sublicense, or commercially exploit the App or access to it.

**8.4 Everything else.** Do not use the App unlawfully, to infringe anyone's rights, to harass anyone,
or to submit content through the jukebox request line that is unlawful, abusive, or hateful.

**8.5 Enforcement.** We may investigate suspected violations and may suspend or terminate access under
§11. Except as §8.6 requires, we are not obligated to monitor use of the App, and choosing not to act
in one case does not waive our right to act in another.

### 8.6 Content submitted by other people, and how to deal with it

The jukebox request line accepts free text from members of the public. That makes it user-generated
content, and the following apply:

- **Filtering.** Submitted text is filtered for objectionable material before a host sees it.
- **Reporting.** Every request a host sees carries a **Report** action. Guests can report content
  shown on the guest page the same way. We act on reports within {{UGC_RESPONSE_SLA}}, and we remove
  material that breaches §8.4 and eject the guest who submitted it.
- **Blocking.** A host can block an abusive guest from their session, and blocked guests cannot rejoin
  it.
- **Contact.** {{SUPPORT_EMAIL}} reaches us about anything on this list, and it is published on the
  guest request page as well as here.

<!-- #TOUPDATE: FORWARD-LOOKING ON EVERY LIMB, AND REQUIRED FOR SUBMISSION. NONE OF THIS EXISTS. The
     request endpoint is open, accepts arbitrary free text from anyone who can reach the URL, and there
     is no filter, no report action, no block, and no ejection anywhere in the server or the client.
     App Review Guideline 1.2 requires all four for any app with user-generated content: a method for
     filtering objectionable material, a mechanism to report offensive content with a timely response,
     the ability to block abusive users, and published contact information. This is a common rejection
     cause and it is checked directly.
     Note the interaction with §8.5: a blanket "we are not obligated to monitor" cuts against 1.2 and
     reads badly next to it, which is why §8.5 is now expressly subject to this section. Note also that
     "eject the guest" and "block" both presuppose a guest identity the session can act on, which is
     part of the §7.1 token work.
     The alternative, and the one recommended elsewhere, is to gate the Jukebox tab out of v1.0 — which
     removes the UGC surface entirely and makes this whole section unnecessary. Decide that first;
     building 1.2 compliance for a feature that may not ship is wasted work. -->

<!-- #TOUPDATE: {{UGC_RESPONSE_SLA}} must be a number that one person can actually honour, every day,
     including while asleep and on holiday. Guideline 1.2 asks for a timely response and a published
     commitment here is enforceable against us. Do not write "24 hours" reflexively. -->

---

## 9. Copyright complaints and repeat infringers

**This section summarises the [PocketDJ Copyright and DMCA Policy]({{DMCA_POLICY_URL}}), which governs
if the two differ.** Read §9.0 before relying on any of it.

**9.0 What the safe harbour covers, and what it does not.** 17 U.S.C. §512(c) limits liability for
infringing material that resides on our system **and that was stored at the direction of a user**. That
is the whole of what it covers. It does **not** cover copies our own systems made without a user
directing them; it does **not** cover material we choose to publish ourselves; and it does **not** cover
public performance or transmission, which are separate acts under separate exclusive rights. Failing to
qualify for a safe harbour does not by itself prejudice any other defence, and qualifying for one does
not make otherwise-infringing conduct lawful. We state this plainly because a policy that gestures at
"DMCA compliance" and lets the reader infer blanket protection would misdescribe both the statute and
this product.
<!-- #TOUPDATE: this scoping paragraph was absent from the prior draft while the DMCA Policy §0 was
     explicit about all of it, making this document the looser of the two on exactly the point the
     DMCA Policy was careful about. It matters here more than there: the audio our infrastructure
     captures from Apple Music is a copy no user directed, the public catalogue and the transcript and
     artwork corpora are material we publish ourselves, and listen-along is a transmission. All three
     of the carve-outs above are load-bearing against features this product currently ships. -->

**9.1 Notices.** If you believe material stored or made available through PocketDJ infringes your
copyright, send a notice to our designated agent:

> **{{AGENT_NAME}}**, Designated Copyright Agent
> {{LEGAL_ENTITY}}
> {{AGENT_MAILING_ADDRESS}}
> Telephone: {{AGENT_PHONE}}
> Email: {{DMCA_EMAIL}}

<!-- #TOUPDATE: the telephone number was MISSING from this block and is not optional. 17 U.S.C.
     §512(c)(2) requires the designated agent's "name, address, phone number, and electronic mail
     address", and requires them to be available to the public on the service's website. If this page
     is the public-facing half of that obligation, it was facially non-compliant as drafted.
     Placeholder names in this block have also been changed to match the DMCA Policy exactly
     ({{AGENT_NAME}}, {{AGENT_MAILING_ADDRESS}}, {{AGENT_PHONE}}, {{DMCA_EMAIL}}) — three documents
     with three vocabularies feed one Copyright Office filing, and divergent placeholders are how the
     filing and the published page end up disagreeing. The DMCA Policy additionally carries
     {{APP_STORE_NAME}} and {{PRIMARY_DOMAIN}} for the alternate-names field of the designation; they
     are not needed in this document but must resolve consistently with it. -->

<!-- #TOUPDATE: no DMCA designated agent is registered with the U.S. Copyright Office, and no mailbox at any PocketDJ domain exists. The domain currently resolves to a parking address with no registration record. Registering the agent requires a real, deliverable address and a monitored mailbox, and it is not retroactive. Do not publish this section until the agent is registered and the mailbox is live and monitored. -->

Please include everything 17 U.S.C. §512(c)(3) requires: your signature (physical or electronic);
identification of the work you say is infringed; identification of the material you say is infringing,
with enough detail for us to find it; your contact details; a statement that you believe in good faith
the use is not authorised by the rights holder, its agent, or the law; and a statement, under penalty
of perjury, that the information in the notice is accurate and that you are the rights holder or
authorised to act for them.

**9.2 Counter-notices.** If we remove or disable material of yours and you believe that was a mistake
or a misidentification, you may send a counter-notice to the same address. 17 U.S.C. §512(g)(3)
requires it to contain all of the following:

1. **your physical or electronic signature;**
2. **identification of the material that was removed or disabled, and the location at which it
   appeared** before it was removed or access to it was disabled;
3. **a statement under penalty of perjury** that you have a good-faith belief the material was removed
   or disabled as a result of mistake or misidentification;
4. **your name, address, and telephone number**; and
5. **a statement that you consent to the jurisdiction of the Federal District Court** for the judicial
   district in which your address is located — or, if your address is outside the United States, for
   any judicial district in which we may be found — **and that you will accept service of process**
   from the person who submitted the original notice, or from that person's agent.

**What happens next, precisely.** On receiving a compliant counter-notice we will promptly send a copy
of it to the person who submitted the original notice, and tell them we will restore the material in 10
business days. We will then restore the material, or cease disabling access to it, **not less than 10
nor more than 14 business days** after we received your counter-notice — **unless** our designated agent
first receives notice that the complaining party has filed an action seeking a court order to restrain
you from infringing activity relating to that material on our system. We cannot shorten the 10 days.

**Your details go to the other side.** A counter-notice contains your name, address, and telephone
number, and we are required to forward it to the complaining party. It also consents to federal court
jurisdiction. Do not send one casually.

Sending either a notice or a counter-notice that materially misrepresents the position can make you
liable for damages under §512(f).

<!-- #TOUPDATE: the prior draft cited §512(g)(3) and stopped, while enumerating §512(c)(3)'s elements
     in full immediately above — an asymmetry that told a counter-notifier what the complainant had to
     do but not what they themselves had to do. The elements and the §512(g)(2)(B)/(C) put-back
     mechanics are now stated, matching DMCA Policy §§5.1–5.2. Keep the two in sync; if the put-back
     timing is ever described differently in the two documents, the one a user relied on is the one
     that will be quoted back. Note that none of this procedure exists operationally — see §9.3. -->

**9.3 Repeat infringers.** We keep records of the copyright complaints we receive and of the profiles
they concern. **In appropriate circumstances we will terminate the profiles of users who repeatedly
infringe copyright**, delete the Content stored under those profiles, and decline to reinstate them.
We may also terminate immediately for a single instance of clear and serious infringement. Adopting
and reasonably implementing such a policy is a **threshold condition** of the safe harbours in
17 U.S.C. §512(i) — it is not optional and it is not a courtesy.
<!-- #TOUPDATE: FORWARD-LOOKING ON EVERY LIMB. There are no profiles to terminate, no complaint
     intake, no record-keeping of complaints or strikes, and no per-user Content to delete. Before
     this may be published: per-user identity (§3.1), a complaint log, a documented strike-and-
     termination procedure, and a working deletion path (§3.4, §11.4).
     The final sentence previously read "...and we apply it." That is an affirmative representation
     that a procedure is in operation, and it was false — the DMCA Policy deliberately avoids making
     it, and this document should not be the looser of the two. It has been replaced with a statement
     of what the statute requires, which is true regardless. Do not restore the original wording until
     the policy is genuinely implemented, because a published claim to be applying a procedure that
     does not exist is worse evidence under §512(i) than saying nothing at all. -->

---

## 10. Maintenance and support

**We are solely responsible** for providing any maintenance and support for the App. **Apple has no
obligation whatsoever to furnish any maintenance or support services** for it.

**PocketDJ is built and supported by one person**, and support is best-effort. Reach us at
{{SUPPORT_EMAIL}} or {{SUPPORT_URL}}. We do not promise a response time, and we do not promise that any
particular feature will keep working.
<!-- #TOUPDATE: this previously read "by a small team". There is no team. It was the one place in the
     document where a fact was invented rather than left as a placeholder, and it is exactly the kind
     of copy the conformance doc's voice rule bars — multi-party phrasing about a one-person product.
     The correction interacts with §8.6: whatever {{UGC_RESPONSE_SLA}} resolves to must be achievable
     by that one person. -->

Nothing in this section commits us to a response time. Where §8.6 or applicable law does set one, that
commitment governs over this paragraph.

---

## 11. Term and termination

**11.1** This agreement takes effect when you first use the App and continues until terminated.

**11.2 By you.** Stop using the App and delete it. You may delete your profile at any time (§3.4).

**11.3 By us.** We may suspend or terminate your access, with or without notice, if you breach these
Terms — in particular §6.1 (rights in your Content), §8 (acceptable use), or §9.3 (repeat
infringement) — if we are required to by law, or if we discontinue the App. Where it is practical and
lawful to do so, we will give you notice and a chance to retrieve your Content first.

**11.4 What happens to your Content.** When you delete Content, or when you delete your profile, we
delete our copies within {{RETENTION_DELETION_SLA}}, and the licence in §6.3 ends with them. Copies in
routine backups age out on the backup system's own schedule. Content you have downloaded to your own
devices stays on your devices; deleting it there is up to you.
<!-- #TOUPDATE: there is no user-facing deletion path that reaches cloud storage, no retention or lifecycle rule on any stored object, and no profile-delete action (§3.4). The in-app storage manager deletes the device copy only. This paragraph requires a real delete API, a real retention policy, and a value for {{RETENTION_DELETION_SLA}} that the infrastructure actually honours. The deletion of server-side objects is additionally blocked on per-profile storage keys (§6.4) — nothing today identifies which stored objects belong to which user, so "we delete our copies" has no addressable target. -->
<!-- #TOUPDATE: the placeholder here was {{DELETION_WINDOW_DAYS}} while the Privacy Policy states the
     same obligation as {{RETENTION_DELETION_SLA}}, with no cross-reference between them — two names
     for one promise, which is how a document ends up publishing two different numbers for the same
     duty. Unified to the Privacy Policy's name. Resolve it once, in one place, and check both
     documents render the same value. Note the unit changed with the name: a "window in days" and an
     "SLA" are not the same shape, so whatever is chosen must read correctly in both sentences. -->

**11.5 Survival.** §§3.3, 4.4, 6.1, 6.2, 6.5, 8, 9, 11.4, 12, 13, 14, 15, 16, 18, and 19 survive
termination.
<!-- #TOUPDATE: the prior list omitted §6.5 (the no-distribution promise — the single provision most
     likely to be litigated, and worthless if it evaporates on termination), all of §9 (copyright
     complaints and the repeat-infringer policy, which must outlive the profile it terminated or
     §512(i) cannot function), §3.3, and §11.4 itself — the post-deletion backup tail that §6.3
     expressly defers to, which by construction operates only after termination. Confirm this list
     with counsel; a survival clause that omits the obligations running past termination is a drafting
     error rather than a policy choice, but which of §§12–16 should survive is a real choice. -->

---

## 12. Disclaimer of warranties

**The App is provided "as is" and "as available", without warranty of any kind.** To the fullest
extent permitted by law, we disclaim all warranties, express, implied, or statutory, including implied
warranties of merchantability, fitness for a particular purpose, title, and non-infringement, and any
warranty arising from course of dealing or usage of trade.

We do not warrant that the App will be uninterrupted, secure, or error-free; that defects will be
corrected; that analysis results (tempo, key, beat grid, stems, transcripts) will be accurate; or that
your Content will be preserved. **Keep your own backups of anything you cannot afford to lose.**

Nothing in the App is legal advice. In particular, the descriptions of performance licensing in §7 are
general information, not advice about your event.

**Nothing in this section excludes or limits any warranty, guarantee, or right you have as a consumer
that cannot be excluded or limited under the law of your country.** If you are a consumer in a
jurisdiction that grants non-excludable statutory guarantees, those guarantees apply and this section
is read subject to them.

---

## 13. Limitation of liability

To the fullest extent permitted by law:

**13.1** We will not be liable for any indirect, incidental, special, consequential, exemplary, or
punitive damages, or for lost profits, lost revenue, lost goodwill, loss of data, or loss of a music
library, however caused and on any theory of liability, even if we have been advised that such damages
are possible.

**13.2** Our total aggregate liability for all claims relating to the App will not exceed the greater
of (a) the amount you paid us for the App in the twelve months before the event giving rise to the
claim, or (b) {{LIABILITY_CAP}}.

**13.3** These limits apply even if a remedy fails of its essential purpose.

**13.4** **Nothing in this section limits liability for death or personal injury caused by negligence,
for fraud or fraudulent misrepresentation, or for anything else that cannot lawfully be limited** —
including any non-excludable rights you have as a consumer.

---

## 14. Indemnity

You will indemnify, defend, and hold harmless {{LEGAL_ENTITY}} and its officers, employees, and
contractors from and against any claim, demand, loss, liability, damage, cost, or expense (including
reasonable legal fees) arising out of or relating to:

1. **your Content**, including any claim that it infringes or misappropriates someone's intellectual
   property or other rights;
2. **your use of the App**, including any public performance of music you make with it and any
   event you host through it;
3. **your breach of these Terms**, including the rights attestation in §6.1 and the acceptable-use
   rules in §8; or
4. **your violation of any law or of anyone else's rights.**

We will notify you of any claim we seek indemnity for, and you may control its defence with counsel
reasonably acceptable to us — provided you may not settle it in a way that imposes any obligation or
admission on us without our written consent. This section does not apply where the law does not permit
it, and it does not apply to a consumer to the extent applicable consumer law says otherwise.

---

## 15. Governing law and venue

**15.1** These Terms are governed by the laws of {{GOVERNING_LAW_STATE}}, excluding its
conflict-of-laws rules and the United Nations Convention on Contracts for the International Sale of
Goods.

**15.2** Subject to §16, the state and federal courts located in {{VENUE_COUNTY_STATE}} have exclusive
jurisdiction over any dispute, and you consent to their jurisdiction and venue.

**15.3 Consumers.** If you are a consumer resident in the European Union, the United Kingdom, or
another jurisdiction whose law gives you the right to bring proceedings in your local courts or to the
protection of local mandatory consumer law, **nothing in this section deprives you of that right or
that protection.**

---

## 16. Disputes

**16.1 Talk to us first.** Before starting formal proceedings, contact us at {{SUPPORT_EMAIL}} and
give us 30 days to try to resolve the problem. Most disputes are cheaper to fix by email.

**16.2 {{DISPUTE_MECHANISM}}**

> **COUNSEL DECISION — do not ship as drafted.** Two options:
>
> **(a) Courts only**, per §15. Simplest; no enforceability risk; no separate acknowledgement needed.
>
> **(b) Informal resolution, then binding individual arbitration**, with a class-action waiver, a
> small-claims carve-out, and an opt-out window. This is standard for U.S. consumer apps, but it is
> likely **unenforceable against EU and UK consumers**, and several U.S. states impose their own
> requirements on how it is presented.
>
> If PocketDJ launches in the United States only, (b) is available. If it launches worldwide, (a) is
> the safer default. **Whichever is chosen, it must be conspicuous and separately acknowledged at
> first run, not buried here.**

---

## 17. Changes to these Terms

**17.1** We may change these Terms. When we do, we will post the updated version at {{TERMS_URL}} and
change the effective date at the top.

**17.2** For material changes — anything that reduces your rights, expands the licence in §6.3, or
changes §16 — we will give you reasonable advance notice, in the App or by email, before the change
takes effect.
<!-- #TOUPDATE: "or by email" promises a channel we do not have. We hold no email address for any user
     and a profile does not carry one (§18.7). In-App notice is the only channel that works today, and
     nothing in the client currently presents a terms-change notice at all. Either build the in-App
     notice surface and drop "or by email", or collect an address and say so in the Privacy Policy. -->

**17.3** Continuing to use the App after a change takes effect means you accept the updated Terms. If
you do not accept them, stop using the App and delete your profile (§3.4); §11.4 governs what happens
to your Content.

**17.4** We will not apply a change retroactively to a dispute that arose before it took effect.

---

## 18. General

**18.1 Entire agreement.** These Terms, together with the documents incorporated by §1.4 — the Privacy
Policy, the Copyright and DMCA Policy, and the Third-Party Notices — and any in-app confirmation you
give under §6.1 or §7.2, are the entire agreement between you and us about the App, and supersede any
prior understanding on the subject.
<!-- #TOUPDATE: as drafted this clause named only the Privacy Policy, which affirmatively EXCLUDED the
     DMCA Policy that §9 summarises and the Third-Party Notices whose licences bind the end user. An
     entire-agreement clause that excludes the document a section is a summary of is worse than an
     inconsistency — it is an argument that the summary displaces the policy. Confirm with counsel
     that incorporating the Notices is the right mechanism for the end-user-facing open-source
     conditions, or whether those belong in a separate acknowledgement. -->

**18.2 Severability.** If any provision is held unenforceable, it will be limited or severed to the
minimum extent necessary, and the rest stays in force.

**18.3 No waiver.** If we do not enforce a provision, that is not a waiver of it.

**18.4 Assignment.** You may not assign or transfer these Terms. We may assign them to a successor in
connection with a merger, acquisition, or sale of assets, on notice to you.

**18.5 No third-party rights, except Apple.** No one other than you and us has any right to enforce
these Terms — except Apple and its subsidiaries, under §19.10.

**18.6 Force majeure.** Neither party is liable for a failure to perform caused by something outside
its reasonable control.

**18.7 Notices.** We may give you notice in the App, at any email address you have given us, or at
{{TERMS_URL}}. Send notices to us at {{SUPPORT_EMAIL}} and, for legal notices, to {{LEGAL_ENTITY}} at
{{BUSINESS_ADDRESS}}.
<!-- #TOUPDATE: "the email address on your account" named something that does not exist — a profile has
     a display name and an identifier, not an email address, and we hold no contact details for any
     user. Notice in the App and at {{TERMS_URL}} are the only channels that currently work. Revisit
     once §3.1 ships and decide whether an email address is collected at all; if it is not, the §17.2
     promise of advance notice "in the App or by email" reduces to in-App only, and §17.2 should say
     so. -->

**18.8 Language.** These Terms are written in English. Any translation is for convenience; the English
version governs.

---

## 19. Apple's required terms

The following are the minimum terms Apple requires in a custom end-user licence agreement for an
application distributed on Apple platforms. Where they overlap with earlier sections, they are
restated here in full so the required set appears in one place.

**19.1 Acknowledgement.** You and we acknowledge that **this agreement is concluded between you and us
only, and not with Apple.** We, not Apple, are solely responsible for the App and its content. This
agreement does not provide for usage rules for the App that conflict with the Apple Media Services
Terms and Conditions as of the date you accept it, and we acknowledge we have had the opportunity to
review those usage rules.

**19.2 Scope of licence.** The licence granted to you in §4.1 is a **non-transferable licence to use
the App on any Apple-branded products that you own or control**, and only as permitted by the Usage
Rules in the Apple Media Services Terms and Conditions — except that the App may be accessed and used
by other accounts associated with you via Family Sharing or volume purchasing.

**19.3 Maintenance and support.** **We are solely responsible** for providing any maintenance and
support services for the App, as specified in §10 or as required under applicable law. **You and we
acknowledge that Apple has no obligation whatsoever to furnish any maintenance and support services**
for the App.

**19.4 Warranty.** **We are solely responsible for any product warranties**, whether express or
implied by law, to the extent not effectively disclaimed in §12. **In the event of any failure of the
App to conform to any applicable warranty, you may notify Apple, and Apple will refund the purchase
price of the App to you.** To the maximum extent permitted by applicable law, **Apple will have no
other warranty obligation whatsoever with respect to the App**, and any other claims, losses,
liabilities, damages, costs, or expenses attributable to a failure to conform to any warranty are our
sole responsibility.

**19.5 Product claims.** **You and we acknowledge that we, not Apple, are responsible for addressing
any claims** by you or any third party relating to the App or your possession and use of it,
including: (i) product liability claims; (ii) any claim that the App fails to conform to any
applicable legal or regulatory requirement; and (iii) claims arising under consumer protection,
privacy, or similar legislation, including in connection with the App's use of any framework that
processes health or similar data. This agreement does not limit our liability to you beyond what
applicable law permits.

**19.6 Intellectual property rights.** **You and we acknowledge that, in the event of any third-party
claim that the App or your possession and use of it infringes that third party's intellectual property
rights, we, not Apple, will be solely responsible for the investigation, defence, settlement, and
discharge of that claim.**

**19.7 Legal compliance.** You represent and warrant that (i) you are not located in a country subject
to a U.S. Government embargo, or that has been designated by the U.S. Government as a "terrorist
supporting" country; and (ii) you are not listed on any U.S. Government list of prohibited or
restricted parties.

**19.8 Developer name and address.** Questions, complaints, or claims about the App should be directed
to:

> **{{LEGAL_ENTITY}}**
> {{BUSINESS_ADDRESS}}
> {{SUPPORT_EMAIL}}

**19.9 Third-party terms of agreement.** **You must comply with applicable third-party terms of
agreement when using the App** — including, for Apple Music playback, the Apple Media Services Terms
and Conditions.

**19.10 Third-party beneficiary.** **You and we acknowledge and agree that Apple, and Apple's
subsidiaries, are third-party beneficiaries of this agreement, and that, upon your acceptance of this
agreement, Apple will have the right (and will be deemed to have accepted the right) to enforce this
agreement against you as a third-party beneficiary of it.**

**19.11 Export.** You may not use or otherwise export or re-export the App except as authorised by
United States law and the laws of the jurisdiction in which the App was obtained. In particular, the
App may not be exported or re-exported into any U.S.-embargoed country or to anyone on the U.S.
Treasury Department's Specially Designated Nationals list or the U.S. Department of Commerce's Denied
Persons or Entity Lists.

**19.12 U.S. Government end users.** The App and related documentation are "Commercial Items" as
defined at 48 C.F.R. §2.101, consisting of "Commercial Computer Software" and "Commercial Computer
Software Documentation" as those terms are used in 48 C.F.R. §12.212 or 48 C.F.R. §227.7202. They are
licensed to U.S. Government end users only as Commercial Items and with only those rights granted to
all other end users.

---

## 20. Contact

> **{{LEGAL_ENTITY}}**
> {{BUSINESS_ADDRESS}}
>
> General and support — {{SUPPORT_EMAIL}} · {{SUPPORT_URL}}
> Privacy — {{CONTACT_EMAIL}}
> Copyright notices — {{DMCA_EMAIL}} · {{AGENT_PHONE}} (see §9.1)

<!-- #TOUPDATE: contact placeholders unified with the sibling documents. This document previously used
     {{PRIVACY_EMAIL}} and {{COPYRIGHT_AGENT_EMAIL}} while the Privacy Policy used {{CONTACT_EMAIL}}
     and the DMCA Policy used {{DMCA_EMAIL}} — three documents, five names, for two mailboxes. Divergent
     placeholder names are how one document ends up published with an address the others do not use and
     nobody monitors. Resolve each mailbox once and confirm all three documents render the same string.
     All of them remain blocked on domain ownership; see Appendix A. -->

---
---

# Before this ships

Everything below is internal. It does not form part of the agreement and must be removed before
publication.

## A. Placeholders to resolve

| Placeholder | What it needs | Notes |
|---|---|---|
| `{{LEGAL_ENTITY}}` | The publisher's exact legal name | Natural person or an entity? This determines the licensor, the DMCA registrant, and the data controller. Not derivable from the code. |
| `{{BUSINESS_ADDRESS}}` | A real, deliverable street address | Required for Apple's minimum term 19.8, for DMCA registration, and for the EU trader page. It becomes **public**. A home address may be exposed; a registered-agent service takes 3–10 business days to procure. |
| `{{EFFECTIVE_DATE}}` | Date these Terms take effect | |
| `{{MINIMUM_AGE}}` | Minimum age to use the App | Must be reconciled with the final App Store age rating, which is currently unanswered (analysis expects 13+ or 16+). |
| `{{SUPPORT_EMAIL}}` | Monitored support mailbox | **The domain `pocketdj.app` resolves to a parking address with no registration record — assume it is not owned.** No mailbox at that domain exists. Register a domain you control, then create the mailbox. |
| `{{SUPPORT_URL}}` | Support page URL | Mandatory in App Store Connect. Does not exist. |
| `{{CONTACT_EMAIL}}` | Monitored privacy mailbox | Same domain prerequisite. **Renamed from `{{PRIVACY_EMAIL}}` to match the Privacy Policy.** Used in §3.5 and §20. |
| `{{PRIVACY_POLICY_URL}}` | Hosted privacy policy | Mandatory in App Store Connect and in-app under Guideline 5.1.1(i). Nothing is hosted anywhere. |
| `{{TERMS_URL}}` | Where this document is published | |
| `{{DMCA_POLICY_URL}}` | Where the Copyright and DMCA Policy is published | **New.** §1.4 incorporates it and §9 is a summary of it; without a URL the incorporation by reference fails. |
| `{{NOTICES_URL}}` | Where the Third-Party Notices are published | **New.** §1.4 incorporates them because some third-party licences bind the end user. |
| `{{DMCA_EMAIL}}` | Monitored copyright mailbox | Same domain prerequisite. Must exist **before** the DMCA registration is filed. **Renamed from `{{COPYRIGHT_AGENT_EMAIL}}` to match the DMCA Policy.** |
| `{{AGENT_NAME}}` | Named designated agent | **Renamed from `{{DMCA_AGENT_NAME}}` to match the DMCA Policy.** |
| `{{AGENT_MAILING_ADDRESS}}` | Agent's street address | P.O. boxes are effectively unavailable for DMCA registration. **Renamed from `{{DMCA_AGENT_ADDRESS}}`.** |
| `{{AGENT_PHONE}}` | Agent's telephone number | **New, and not optional — 17 U.S.C. §512(c)(2) requires it and this document omitted it.** Must be reachable. |
| `{{GOVERNING_LAW_STATE}}` | Governing law | |
| `{{VENUE_COUNTY_STATE}}` | Exclusive venue | |
| `{{LIABILITY_CAP}}` | Floor on the liability cap in §13.2 | A free app makes limb (a) zero, so limb (b) is doing all the work. |
| `{{RETENTION_DELETION_SLA}}` | Deletion SLA in §11.4 | **Renamed from `{{DELETION_WINDOW_DAYS}}` to match the Privacy Policy** — one obligation had two placeholder names and could have published two different numbers. Must be a value the infrastructure actually honours; no lifecycle or retention rule exists today. |
| `{{UGC_RESPONSE_SLA}}` | Response time for jukebox content reports (§8.6) | **New.** Guideline 1.2 expects a timely response to reports. Must be honourable by one person; the enforcement mechanism it presupposes does not exist. |
| `{{DISPUTE_MECHANISM}}` | Courts, or arbitration + class waiver | See §16.2. Depends on the territory decision. |

**Placeholders that must resolve identically across documents.** The same obligation must not carry two
names. Check these as a set, not one document at a time:

| This document | Privacy Policy | DMCA Policy |
|---|---|---|
| `{{LEGAL_ENTITY}}` | `{{LEGAL_ENTITY}}` | `{{LEGAL_ENTITY}}` |
| `{{BUSINESS_ADDRESS}}` | `{{POSTAL_ADDRESS}}` | `{{AGENT_MAILING_ADDRESS}}` |
| `{{CONTACT_EMAIL}}` | `{{CONTACT_EMAIL}}` | `{{CONTACT_EMAIL}}` |
| `{{SUPPORT_EMAIL}}` | `{{SUPPORT_EMAIL}}` | — |
| `{{DMCA_EMAIL}}` | — | `{{DMCA_EMAIL}}` |
| `{{AGENT_NAME}}` / `{{AGENT_MAILING_ADDRESS}}` / `{{AGENT_PHONE}}` | — | same three |
| `{{RETENTION_DELETION_SLA}}` | `{{RETENTION_DELETION_SLA}}` | — |
| `{{EFFECTIVE_DATE}}` | `{{EFFECTIVE_DATE}}` | `{{EFFECTIVE_DATE}}` |
| `{{MINIMUM_AGE}}` | `{{AGE_RATING}}` (related, not identical) | — |

`{{BUSINESS_ADDRESS}}` and `{{POSTAL_ADDRESS}}` are still two names for one address; they are left as
they are because renaming across documents is a separate pass, but **they must resolve to the same
string**. The DMCA Policy additionally holds `{{APP_STORE_NAME}}` and `{{PRIMARY_DOMAIN}}` for the
Copyright Office designation's alternate-names field; this document does not use them, but the domain
it names in §20 must be the one registered there.

**Unmet prerequisite, called out separately because everything else waits on it:** the domain. Until a
domain is registered and mailboxes are created and monitored, every address in this document is
fictional, the privacy policy cannot be hosted, and the DMCA agent cannot be registered.

## B. `#TOUPDATE` index

Grep `#TOUPDATE` in the source. Each entry names what must be true before the adjacent sentence may be
published. **The grep is the gate**, so the index below must stay complete: a claim with no marker is
invisible to it, and an unmarked false claim is exactly what the gate exists to stop.

**A note on how the prior draft failed, because the failure had a shape.** Markers were placed on the
first statement of a claim and not on its restatements. §6.4 was marked, then the same claim reappeared
unmarked in §6.3 and §8.2; §6.7 was marked, then restated bare in §8.1; §7.1 was marked, then restated
in §7.3. Twelve claims were unmarked in total. **When clearing a marker, grep for the claim, not for the
section number** — the same sentence usually lives in three places, and clearing one leaves the others
in the document.

| § | Claim | What must become true |
|---|---|---|
| Short version | Apple Music is not recorded or captured | Same as §6.7 below |
| 1.1 | "PocketDJ cloud services" and vendor characterisation | The capture / stem-dispatch / search / jukebox compute moves to hosted infrastructure, or both this document and the Privacy Policy describe the arrangement accurately. Today that tier is a personal machine on a residential connection, reached at a hostname compiled into the shipped client. |
| 1.1a | Controller and EU trader identification | `{{LEGAL_ENTITY}}` and `{{BUSINESS_ADDRESS}}` resolve. Required for GDPR Art. 13, Apple minimum term 19.8, and the EU trader page. |
| 1.4 | The DMCA Policy and Notices are incorporated | `{{DMCA_POLICY_URL}}` and `{{NOTICES_URL}}` resolve and both documents are actually hosted. Incorporation by reference to nothing is not incorporation. |
| 2.1a | Age floor tracks the Privacy Policy's country-variable rule | `{{MINIMUM_AGE}}`, `{{AGE_RATING}}`, and Privacy Policy §14 resolved together in one pass. |
| 2.1b | Age is enforced | An age gate exists. Today nothing collects or checks an age. |
| 3 | "Profile", not "account" | Vocabulary now matches the Privacy Policy. The underlying question — whether a durable synced identifier published to a public guest page triggers Guideline 5.1.1(v) — is not resolved by naming, and should be treated as triggered. |
| 3.1 | Per-user identity exists and you are responsible for yours | Per-user authentication ships; a server-derived user identity reaches storage and processing requests. Today the backend has one shared token and no user identifier of any kind. |
| 3.2 | A profile can be compromised, and we can act | Presupposes §3.1. There is no credential, no server-side session, and no per-user record to lock or restore. |
| 3.3 | Sharing credentials is prohibited | Reworded to prohibit the conduct rather than a mechanism that does not exist. Restore credential wording once §3.1 ships. |
| **3.4** | **In-app profile deletion exists** | **REQUIRED FOR SUBMISSION under Guideline 5.1.1(v). THE FLOW DOES NOT EXIST.** Deletion must reach the CloudKit profile and session records, server-side audio and derivatives, jukebox sessions, and local files. The server-side half is blocked on §6.4 — nothing identifies which stored objects belong to which user. Privacy Policy §13 carries the matching marker. |
| 5, 6.3(4), 6.3(5) | Stem separation is a licensed capability | The separator's pretrained weights are granted for scientific purposes only, not under the MIT licence covering the surrounding code, and this is a commercial app. Third-Party Notices §9.1 rates it **BLOCKING** and lists the options; "ship anyway" is expressly not one. Cloud lyric transcription runs over the vocals stem and falls with it. |
| 6.1 | The in-app vocabulary rename | **The rename has not started.** The shipped build still exposes "Rip server URL", "Rip from cloud source", "Rip server", "Rip", and "Burn". The prior wording ("is being changed") claimed work in progress that is not in progress. |
| 6.3(1) | Content is stored in storage assigned to your profile | Same defect as §6.4, restated — and the §6.4 marker did not reach it. |
| 6.3 | "No right to make it available to any other user" | Same preconditions as §6.5. False today on both the infrastructure ground and the listen-along ground. |
| 6.3 | Vendors act on our instructions | "Compute" removed from the vendor list pending a real hosted tier. See §1.1. |
| 6.4 | Per-user copies; no cross-user access; no shared masters | Per-profile storage namespaces, authenticated (non-public, signed) delivery, and removal of cross-user dedup for audio, stems, analysis, and transcripts. Today keys are content-addressed in one shared bucket with public read, a second user's import redirects to the first user's object, and the stem worker dedupes by song id. |
| 6.4 | Sharing is limited to information about music | False while listen-along ships; the §6.4 marker covered only the storage paragraph by its own wording. Carve-out added, pointing at §7.5. |
| **6.5** | **"We do not distribute your music"** | **THE LARGEST GAP, AND IT WAS ENTIRELY UNMARKED.** Two independent defects: the audio bucket allows anonymous read with every public-access-block flag off and an anonymously fetchable manifest enumerating every key; and listen-along is a shipped feature whose purpose is making Content available to others, documented in Privacy Policy §9.3. Requires the §6.4 controls **and** the §7.5 gating. This is the promise most likely to be litigated. |
| 6.6 | The public catalogue never links to anyone's audio | The audio storage prefix becomes private and the public manifest stops being anonymously fetchable. The catalogue documents themselves are already metadata-only — the claim fails on the adjacent infrastructure. |
| 6.6 | What the catalogue publishes | The enumeration omitted the published transcript corpus (~16,200 files) and mirrored artwork (~1,160 images), so a reader concluded lyrics are not published. Take them off the public buckets, or state what is published and under what claimed right. |
| 6.7 | Apple Music is playback only | The real-time capture path is removed from the backend, the Discover add-then-capture flow is removed from the client, capture fails closed for Apple Music sources, and previously captured objects are deleted. |
| 6.8 | Users are told when a recording is uploaded for processing | An in-app disclosure and consent step at the point a microphone recording or recorded mix is sent for stem separation. The paragraph is honest about the behaviour; the consent it implies is not built. |
| 6.8 | Scope of the "what leaves your device" promise | The section promised the user need not read the privacy policy, while the privacy label declares Search History and server logs. Scope limiter added. Extend the Privacy Policy Appendix B agreement rule to cover this document. |
| 6.8 | Cue points and recorded mixes "stay on your device" | The audio takes stay local; the `mix-sessions`, `playback-session`, and `mix-decks` documents sync to CloudKit. Split into two bullets. Re-verify if the synced document set changes. |
| 7.1 | Sessions are token-gated by default, capped, and expire | A guest token required by default on the request endpoint **and** the state fetch; a real concurrent-listener cap (none exists); a bounded lifetime for every session, including "timeless" ones. |
| 7.1 | "The music comes out of your speakers" | Incomplete while listen-along ships. |
| 7.3 | No broadcasting | Prohibits what the product is built to do. Requires §7.1's controls. |
| **7.5** | **Listen-along is described at all** | **NEWLY WRITTEN — the feature was absent from this document and denied in four places.** "Off by default" and "host-only" are true; "guests in a session" is not — no guest token, a public audio URL that outlives the session, no listener cap, timeless sessions never expire. If the Jukebox tab is gated out of v1.0, delete this section and restore the absolute wording in §6.4, §6.5, §7.1, §7.3, and §8.2. |
| 8.1 | "Trying to reach another user's stored copies" | Prohibits conduct that today requires no effort — fetching a public URL listed in a public manifest. Requires §6.4. |
| 8.1 | "PocketDJ provides no means of doing this" | **Same claim as §6.7, restated bare.** Identical preconditions. Clearing §6.7 without clearing this one leaves the false statement in the document. |
| 8.2 | Sharing credentials or any session link | Reworded twice: there are no credentials, and a flat ban on session links prohibits the ordinary use of listen-along. Requires §7.1. |
| **8.6** | **UGC filtering, reporting, blocking, contact** | **REQUIRED FOR SUBMISSION under Guideline 1.2. NONE OF IT EXISTS.** The request endpoint is open and accepts arbitrary free text from the public; there is no filter, no report action, no block, no ejection. Note §8.5's "we are not obligated to monitor" now yields to this section. Gating the Jukebox tab out of v1.0 removes the UGC surface entirely — decide that before building. |
| 9.0 | Safe-harbour scoping | Newly added to match DMCA Policy §0, which this document previously omitted. All three carve-outs bite on shipped behaviour: captured copies no user directed, corpora we publish ourselves, and listen-along transmission. |
| 9.1 | A designated copyright agent exists at a real address | Register the agent with the U.S. Copyright Office ($6, by card). Requires the domain and mailbox first. Registration is **not retroactive**. |
| 9.1 | Agent telephone number | **`{{AGENT_PHONE}}` was missing and §512(c)(2) requires it.** As drafted this page was facially non-compliant if it is the public-facing half of the designation. |
| 9.2 | §512(g)(3) elements and put-back mechanics | Now enumerated, matching DMCA Policy §§5.1–5.2. The procedure does not exist operationally. |
| 9.3 | Repeat-infringer policy is applied | Per-user identity (§3.1), a complaint intake and log, a documented strike-and-termination procedure, and a working deletion path. Every limb absent. **"And we apply it" was removed** — claiming to operate a procedure that does not exist is worse §512(i) evidence than silence. |
| 10 | "A small team" | **Corrected to one person.** It was the only invented fact in the document rather than a placeholder. |
| 11.4 | Content is deleted within a stated window | A user-facing delete path that reaches cloud storage, a retention/lifecycle rule, and a real value for `{{RETENTION_DELETION_SLA}}`. Blocked on §6.4 for the server-side half. The in-app storage manager deletes the device copy only. |
| 11.5 | Survival list | Was under-inclusive: omitted §6.5, all of §9, §3.3, and §11.4. Confirm the corrected list with counsel. |
| 18.1 | Entire agreement | Previously excluded the DMCA Policy and the Notices while §9 summarised the former. Requires §1.4's URLs. |
| 18.7 | Notice by email | We hold no email address for any user. Revisit with §3.1; if no address is ever collected, §17.2's "or by email" reduces to in-App only. |
| 20 | Contact placeholders | Unified with the sibling documents. Three documents used five names for two mailboxes. |

## C. Questions for counsel

1. **Licensor identity.** Natural person or entity, and which entity? This sets the licensor in §1.1,
   the indemnified party in §14, the DMCA registrant, and the data controller.
2. **Address exposure.** Apple's minimum term 19.8, the DMCA registration, and the EU trader page all
   publish a street address. Is a registered-agent service worth the 3–10 day delay, or do we file
   with a home address and amend later?
3. **Governing law and venue** — and whether the choice survives a consumer-protection challenge in
   the jurisdictions we sell into.
4. **§16.2: arbitration or courts?** Arbitration with a class waiver is standard for U.S. consumer
   apps and likely unenforceable against EU/UK consumers. This turns on question 5.
5. **Territory.** Is the first release United States only? It is a reversible checkbox, and it decides
   §16.2, the enforceability of §§12–13, and whether GDPR/UK GDPR obligations are live at launch.
6. **Is the §6.3 licence grant sufficient?** It is deliberately narrower than Serato's or rekordbox's.
   Does it cover everything the App actually does — including creating derivative artifacts (stems,
   transcripts) and caching at a CDN — without granting anything it does not need?
7. **§6.1 attestation.** Is the representation-and-warranty framing strong enough to shift the risk,
   and should the first-run confirmation be a separate signed acknowledgement rather than a checkbox?
8. **§13.2 liability cap.** For a free app, limb (a) is zero. Is limb (b) enforceable at the figure we
   pick, and in which states is a cap this low at risk?
9. **§14 indemnity against consumers.** Enforceable? Several jurisdictions restrict consumer
   indemnities; should it be narrowed to the Content and public-performance limbs only?
10. **§7.2 performance-licensing language.** It tells users the venue normally holds the licence while
    also saying they may be liable. That is accurate but uncomfortable. Is the balance right, and is
    naming specific PROs and foreign societies a liability if the list goes stale?
11. **§9.3 repeat-infringer policy.** Is "repeatedly" specific enough for §512(i), or does the policy
    need a defined strike count and a published appeals path?
12. **§6.7's Apple Music paragraph.** Once the capture paths are removed, does the disclosure about
    irreversible favourite/rating writes to the user's Apple Music account need to be more prominent —
    in-app consent rather than a line in the Terms?
13. **Consumer carve-outs.** §§12, 13, and 15 each carry one. Are they drafted correctly for the UK
    and EU, and do any U.S. states require different language?
14. **Age.** Does `{{MINIMUM_AGE}}` need to match the App Store age rating exactly, and does a 13+
    threshold pull in COPPA-adjacent obligations we have not analysed?
15. **Should this document and the Privacy Policy be one document or two?** Apple requires a privacy
    policy URL; it does not require a separate terms URL. Two is cleaner but doubles the maintenance.
16. **§5 / §6.3(4): stem separation.** The separator's pretrained weights are granted for scientific
    purposes only and this is a commercial app; Third-Party Notices §9.1 rates it blocking. Does
    server-side use of research-only weights to generate output for a commercial app's users infringe,
    and does it matter that the weights are never distributed? This decides whether Stemify, the stem
    decks, per-stem Performance, the Demuxer, and cloud lyric transcription ship at all. It is the
    largest product question in this document and it is not a drafting question.
17. **§7.5: does listen-along ship?** Everything in §6.4, §6.5, §7.1, §7.3, and §8.2 is drafted twice
    over — once with carve-outs for the feature and once absolutely — and the absolute drafting is
    materially stronger. The recommendation on the table is to gate the Jukebox tab out of v1.0, which
    also removes the Guideline 1.2 obligations in §8.6 and the guest-data questions in §7.4. Decide
    this before counsel spends time on the carve-outs.
18. **§8.6 and Guideline 1.2.** If the jukebox does ship, is the four-part scheme (filter, report,
    block, contact) sufficient as drafted, and what is a defensible `{{UGC_RESPONSE_SLA}}` for a
    single operator? A published commitment is enforceable against us.
19. **§9 versus the DMCA Policy.** §9 is now a summary that yields to the fuller document. Is a summary
    plus a governing-document clause the right structure, or should §9 simply point at the DMCA Policy
    and stop? Duplicated legal text drifts, and the two documents had already diverged on scope, on
    the counter-notice elements, and on whether we claim to be applying the repeat-infringer policy.
20. **§3: does the profile trigger Guideline 5.1.1(v)?** We have assumed yes and drafted §3.4 on that
    basis. If it does not, the deletion obligation is a courtesy rather than a submission blocker, and
    the sequencing changes. This is worth a firm answer because §3.4 depends on §6.4, which is the
    longest piece of work in the whole list.
21. **§1.1: the compute tier.** Operating the processing backend from a residence, on a personal
    machine, on a residential connection, is a fact about the service that this document previously
    described as a service-provider arrangement. Does it need affirmative disclosure — to users, in
    the Privacy Policy's international-transfer section, or to Apple — or is it sufficient to stop
    mischaracterising it?

## D. Sources consulted for the mandatory terms

- Apple, *Instructions for Minimum Terms of Developer's End-User License Agreement* —
  https://www.apple.com/legal/internet-services/itunes/dev/minterms/ and
  https://www.apple.com/legal/macapps/minterms/ (§19 tracks all ten required items)
- Apple Developer Program License Agreement, Schedule 1 —
  https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- rekordbox End User Licence Agreement — https://rekordbox.com/en/license-agreement/ (§2.2(f)
  prohibited "rip"; §2.4 third-party terms triad; §3.5 user rights warranty; §5.1(c) liability
  allocation for user-imported content; §6 indemnity)
- Serato Terms of Use — https://serato.com/legal/website-terms-and-conditions (the broad user-content
  grant this document deliberately does **not** follow)
- Algoriddim (djay) EULA — https://www.algoriddim.com/eula (external-services compliance framing)
- `docs/legal/legal-posture-conformance.md` §§6.1–6.12 — the drafted acceptable-use copy, the
  vocabulary rename table, the vacuous-claim rule (§6.0.1), and the four publication blockers (§6.0)
