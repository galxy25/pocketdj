# PocketDJ — Copyright and DMCA Policy

**Effective date:** {{EFFECTIVE_DATE}}
**Applies to:** the PocketDJ apps (iOS, iPadOS, macOS, visionOS) and PocketDJ cloud services.
**Status:** DRAFT. Not legal advice. See "Questions for counsel" at the end.

<!-- #TOUPDATE: This document is written to the INTENDED architecture, not the one running today.
     Every forward-looking claim below carries its own #TOUPDATE comment. Grep for "#TOUPDATE"
     and confirm each one is true of shipped code and live infrastructure BEFORE publishing this
     policy anywhere a user or a rights holder can read it. Publishing a policy that describes a
     system that does not exist is worse than publishing nothing. -->

---

## 0. Read this part first: what this policy does and does not cover

PocketDJ takes copyright seriously, and this policy sets out how to tell us about infringing
material and what we do about it.

It is also important to be precise about scope, because the law here is narrower than most
copyright policies imply.

**Section 512(c) of the U.S. Copyright Act (17 U.S.C. § 512(c)) is a limitation on liability for
infringing material that "resides on a system or network controlled or operated by or for the
service provider" and that was stored **at the direction of a user**.** That is the whole of what
it covers. It is not a general shield against copyright liability, and this policy does not claim
that it is. In particular:

- **It does not cover copies our own systems made.** If PocketDJ's infrastructure produces a copy
  that no user directed, § 512(c) has nothing to say about that copy. Registering a designated
  agent does not change this, and no notice-and-takedown process cures it.
- **It does not cover material we choose to publish ourselves.** Anything PocketDJ publishes on
  its own initiative is our own act, not user-directed storage.
- **It does not cover public performance or transmission.** § 512(c) is about *storage*. A
  transmission we make is a separate act under a separate exclusive right, and it is outside this
  safe harbor.
- **It is not the only thing standing between us and a copyright claim.** Under § 512(l), failing
  to qualify for a safe harbor does not, on its own, prejudice any other defense. Conversely,
  qualifying for one does not make otherwise-infringing conduct lawful.
- **It is conditioned on more than notice-and-takedown.** § 512(c)(1) has three conditions, not one.
  Besides responding to notices, a provider must lack **actual knowledge**, and must not be **aware
  of facts or circumstances from which infringing activity is apparent** — the "red flag" standard
  of § 512(c)(1)(A)(ii) — and must **not receive a financial benefit directly attributable to
  infringing activity in a case in which it has the right and ability to control that activity**
  (§ 512(c)(1)(B)). Neither condition is satisfied by handling notices well.
  <!-- #TOUPDATE: Both conditions are live exposure on the current facts and must be reviewed by
       counsel before publication, not merely recited. PocketDJ's corpus was hand-curated by a
       single operator, that operator's own server performs the copying, and every stored object
       sits in one bucket under that operator's sole control. That is the fact pattern in which
       "right and ability to control" is argued against a provider, and in which a hand-picked
       corpus is argued to be red-flag apparent. See counsel Q3. -->
- **It says nothing about § 1201.** § 512 is Title II of the DMCA. Title I — the anti-circumvention
  rules at 17 U.S.C. § 1201 — is a separate statute with separate liability and no notice-and-
  takedown cure, and this policy does not address it.
  <!-- #TOUPDATE: This bullet exists because the shipped product captures audio delivered under
       DRM through Apple Music (see the capture #TOUPDATE below). While that path exists, § 1201 is
       an open exposure that no § 512 filing touches. Counsel Q11 asks whether this document should
       address Title I at all, or whether the capture path's removal moots the question. Do not
       publish a document titled "Copyright and DMCA Policy" that silently covers only half the
       Act. -->

**Which safe harbors this policy claims.** § 512 contains four limitations, and a single agent
designation supports § 512(b), (c), and (d) alike. This policy asserts **§ 512(c)** (user-directed
storage). It does not assert § 512(b) (system caching) or § 512(d) (information location tools).
<!-- #TOUPDATE: Decide this with counsel before publishing; do not publish this paragraph as
     drafted without confirming it. The product runs a public metadata catalog with full-text
     search and a search proxy that forwards queries to a third-party catalog API, which is
     § 512(d) territory, and it serves lyrics and mirrored artwork through a CDN with long
     cache lifetimes, which is § 512(b) territory. The choice is between (a) disclaiming (b)/(d)
     because we host no links to infringing material — in which case say that affirmatively and
     make sure it is true — and (b) claiming them, which pulls their own conditions in. Silence is
     the one option that is not available: one designation covers all three, so a rights holder
     will read the filing as claiming all three regardless of what this page says. -->

We say this plainly because the alternative — a policy that gestures at "DMCA compliance" and lets
the reader infer blanket protection — would misdescribe both the statute and our product.

**How PocketDJ is designed, so the scope above is meaningful:**

- Audio in PocketDJ comes from the user: files they own and upload, recordings they make from
  their own analog sources (records, tapes, line-in), and audio they import into their own
  collection.
  <!-- #TOUPDATE: THIS SENTENCE IS AN EXHAUSTIVE CLAIM ABOUT PROVENANCE AND IT IS FALSE TODAY. It
       is the load-bearing premise of the entire § 512(c) "storage at the direction of a user"
       theory, so it carries its own gate rather than borrowing the ones below it. Two other
       sources of audio exist right now:
       (1) SERVER-SIDE CAPTURE. The rip server's POST /rip drives real-time capture of Apple Music
           playback, and the shipped app triggers it. This is the same code the Apple Music bullet
           below denies; both must go at the same time.
       (2) SERVER-GENERATED DERIVATIVES THE USER NEVER SUPPLIED. Separated stems, transcoded
           renditions, per-song cut exports, and machine transcripts are copies our own systems
           made. Per the scope statement above, § 512(c) does not reach them at all — so the
           sentence must not be published in a form that implies it does.
       Must be true before publishing: capture removed per the Apple Music gate below, AND either
       this sentence is narrowed to describe only user-supplied originals with derivatives
       disclosed separately, or the derivative pipelines are gone. -->
- Each user's copies are their own, and each user accesses only their own.
  <!-- #TOUPDATE: Requires per-user storage keys and per-user access control. Today storage keys
       are content-keyed with no user namespace, and one user's object is served to any later
       requester. Must be true before publishing: user-namespaced keys, authenticated per-user
       access, no cross-user dedup of user-supplied audio. -->
- **Apple Music is playback only.** PocketDJ plays Apple Music through Apple's own frameworks
  using the user's own subscription. PocketDJ does not record, capture, download, or otherwise
  retain audio from Apple Music, and provides no means of doing so.
  <!-- #TOUPDATE: Must be true before publishing: every Apple Music capture path removed from the
       target at compile time (not feature-flagged), and the server-side capture path deleted.
       This sentence is a representation to rights holders and to App Review; it must not ship
       ahead of the code.
       "Removed at compile time" is unverifiable unless the list is explicit, so here is what has
       to go. Confirm each is GONE, not disabled:
         - the rip server's Audio Hijack driver script (the one that drives Music.app playback and
           records its output);
         - the rip server's recording-directory constant and the capture branch of its POST /rip
           handler;
         - the app-side flag and every call site that asks the server to rip from the cloud
           (settings surface + the rips store's ripFromCloud call sites).
       Verification at review is: grep the shipped target for the flag name and for the capture
       endpoint and get zero hits, and confirm the server has no Audio Hijack dependency at all.
       A feature flag defaulted off does not satisfy this sentence. -->
  <!-- #TOUPDATE: Deliberately NO file paths or line numbers here. This document is published to
       rights holders; internal source locations do not belong on a public page. Keep the
       description functional and resolve it against the tree at review time. -->
- **The public catalog is metadata only** — titles, artists, albums, tempo, key, and similar facts
  about recordings. It exists so people can see what someone played and be inspired by it. It is
  never a route to audio, and it carries no audio locations.
  <!-- #TOUPDATE: Requires that every public surface be metadata-only. Must be true before
       publishing: no public download index, no publicly served lyrics corpus, no publicly served
       mirrored artwork, and no anonymously fetchable audio objects. -->
- **Sessions are private performances hosted by the user.** Jukebox sessions are token-gated by
  default, capped in listeners, and expire. They are intended for private events the host runs,
  and the host is responsible for any performance licensing their venue or event requires.
  PocketDJ does not license music and cannot obtain performance licences on a host's behalf.
  <!-- #TOUPDATE: MECHANICS AND CHARACTERIZATION ARE TWO SEPARATE GATES. Both must clear.
       (a) Mechanics: requires token gating on by default, an enforced listener cap, and enforced
           session expiry, all server-authoritative. Must be true before publishing: no
           unauthenticated session minting, no sessions exempt from expiry, and no publicly
           reachable audio URL in any session payload.
       (b) Characterization — THIS IS THE HARDER ONE AND NO MECHANIC FIXES IT. Calling these
           "private performances" is a legal conclusion this project's own posture review rejects:
           it finds that jukebox guests are the Aereo audience exactly, "unrelated and unknown to
           each other," which is the description of a PUBLIC performance under the transmit clause.
           A QR-code request line at a public event is not made private by a token. Satisfying
           every item in (a) would still leave this sentence wrong. Do not publish this
           characterization on counsel's silence; it needs an affirmative sign-off, and if counsel
           does not give one the sentence must be rewritten to describe the mechanics only and
           drop the "private performance" conclusion. Reconcile with the posture review rather
           than contradicting it — two internal documents taking opposite positions on the same
           facts is itself discoverable. -->
- **Users must hold the rights to any audio they upload, import, or record into PocketDJ.** This is
  the core attestation, it is presented at first run, and it is a condition of using the service.
  <!-- #TOUPDATE: Requires the first-run rights attestation gate to exist in the app. There is no
       attestation of any kind today. -->

---

## 1. Designated agent

<!-- #TOUPDATE: NOTHING IN THIS SECTION IS TRUE YET. No agent has been designated with the U.S.
     Copyright Office, no mailbox exists, and the domain is not registered. See §1.1 — the
     registration is a PREREQUISITE, and it cannot be applied retroactively. -->

PocketDJ's designated agent to receive notifications of claimed infringement under
17 U.S.C. § 512(c)(2) is:

| Field | Value |
|---|---|
| **Service provider** | {{LEGAL_ENTITY}} |
| **Also known as** | PocketDJ, {{APP_STORE_NAME}}, {{PRIMARY_DOMAIN}} |
| **Designated agent** | {{AGENT_NAME}} |
| **Mailing address** | {{AGENT_MAILING_ADDRESS}} |
| **Telephone** | {{AGENT_PHONE}} |
| **Email** | {{DMCA_EMAIL}} |

<!-- #TOUPDATE: {{DMCA_EMAIL}} must be a real, deliverable, actively monitored mailbox before this
     table is published. A published address that bounces or goes unread is affirmative evidence
     that the § 512 process is not implemented — worse than publishing no address. -->

<!-- #TOUPDATE: PLACEHOLDER-TOKEN COLLISION ACROSS THE LEGAL SET — FIX BEFORE ANY SUBSTITUTION PASS.
     Three documents state the same § 512(c)(2) agent facts using three different token sets:
       - this document: {{AGENT_NAME}} / {{AGENT_MAILING_ADDRESS}} / {{AGENT_PHONE}} / {{DMCA_EMAIL}}
       - TERMS.md §9.1: {{DMCA_AGENT_NAME}} / {{DMCA_AGENT_ADDRESS}} / {{COPYRIGHT_AGENT_EMAIL}}
       - PRIVACY.md: no agent block at all; its placeholder table points at {{LEGAL_ENTITY}} and
         {{POSTAL_ADDRESS}} and notes those feed a DMCA agent registration.
     § 512(c)(2) requires the SAME contact information in the Copyright Office registration and on
     the public site. A substitution pass keyed on one token set will leave the others
     unsubstituted or, worse, silently divergent — and divergent published agent details are a
     defect in the designation itself, not a typo.
     Worse still: {{AGENT_PHONE}} exists ONLY in this document. TERMS.md and PRIVACY.md have no
     phone placeholder at all, so their agent blocks omit a datum § 512(c)(2) requires.
     Required before substitution: unify on ONE token set across DMCA.md, TERMS.md, and PRIVACY.md;
     add a phone token wherever an agent block appears; then verify by grepping all three documents
     for the unified tokens and confirming identical substituted values. -->

<!-- #TOUPDATE: {{PRIMARY_DOMAIN}} — pocketdj.app is NOT REGISTERED TO US. Verified: DNS resolves,
     which means the name IS registered — to a third party or a parking service, not to us. State
     it that way and not as "there is no registration record," which is false on its face for any
     name that resolves and will read as sloppy to a lawyer who runs the same lookup. Do not print
     dmca@pocketdj.app, abuse@pocketdj.app, or any pocketdj.app URL in this or any other document
     until we actually control the domain, or until a domain we do own is chosen instead. -->

### 1.1 Registration with the Copyright Office is a prerequisite, and it is not retroactive

This is a process note for us, not for the reader of the policy, and it is the single most
schedule-relevant fact in this document.

- **Designation must be filed electronically** with the U.S. Copyright Office at
  **https://dmca.copyright.gov/dmca/login.html**. The Office no longer accepts paper designations.
- **The fee is $6** per designation, amendment, or resubmission.
- **A designation expires three years after registration** and becomes invalid unless renewed —
  either by amending it (to correct or update information) or by resubmitting it unchanged. Either
  action starts a new three-year clock. Letting it lapse risks losing § 512 protection.
- **§ 512(c)(2) makes designation an express condition of the safe harbor**, and courts have read
  that condition literally: a service provider cannot retroactively qualify for § 512(c) for
  infringements that occurred before it designated an agent. *Oppenheimer v. Allvoices*
  (N.D. Cal. 2014) called designation a "predicate, express condition"; *BWP Media USA Inc. v.
  Hollywood Fan Sites, LLC*, 69 F. Supp. 3d 342 (S.D.N.Y. 2014), followed it. **Filing later does
  not cover earlier conduct.** The clock starts on the day we file and not one day sooner.
  <!-- #TOUPDATE: VERIFY THE BWP CITATION BEFORE PUBLISHING. This previously read "(S.D.N.Y. 2015)"
       and that is believed wrong: the opinion holding agent designation a precondition to
       § 512(c) is 69 F. Supp. 3d 342, decided Sept. 30, 2014. The 2015 opinion in the same
       litigation (115 F. Supp. 3d 397) addresses different issues and is not the one this
       paragraph relies on. Confirm the reporter cite and the year against the actual opinions.
       This is the single paragraph carrying the whole schedule argument — a mis-cited year here
       is the first thing counsel will catch and it discredits everything around it. -->
  <!-- #TOUPDATE: Neither case has been read in full for this draft; both are cited from summary.
       Have counsel confirm each holding actually says what this bullet attributes to it before
       the bullet is relied on to justify filing timing. -->
- **The Copyright Office registration is only half of it.** § 512(c)(2) also requires the same
  contact information to be made available to the public **on our own website**, in a location
  accessible to the public. Both halves are required; either one alone is insufficient. This
  policy's canonical public location is **{{DMCA_POLICY_URL}}**, and that is the URL given to the
  Copyright Office as the location of our agent information.
  <!-- #TOUPDATE: Requires a live, public, login-free page carrying the agent contact block above.
       No such page exists. It must be published at an explicit object key that actually serves
       this content — verify the response body is this policy and not a single-page-app shell.
       The registration and the posting have to point at each other, so {{DMCA_POLICY_URL}} must
       be decided BEFORE filing and must be the exact string entered on the designation. If the
       URL later changes, the designation must be amended (which also resets the three-year
       clock) — so pick a location that will not move. Verify after publishing by fetching
       {{DMCA_POLICY_URL}} unauthenticated, from outside any cache, and confirming the agent
       table is in the response body. -->
- **The service provider address must be a physical street address.** P.O. boxes are not accepted
  for the service provider except by prior written approval from the Copyright Office's Office of
  General Counsel, granted only in exceptional circumstances such as a demonstrable threat to
  personal safety. (No waiver is needed for a *designated agent's* P.O. box.) Whatever address is
  filed becomes **public** in the Copyright Office's searchable directory.
  <!-- #TOUPDATE: The address in {{AGENT_MAILING_ADDRESS}} becomes permanently public. Decide
       between a home address and a commercial/registered-agent address BEFORE filing. Procuring a
       commercial address takes days; the registration is amendable afterward, so a delay to
       obtain one trades against the fact that safe harbor does not accrue until the filing date. -->
- **List alternate names.** The Office asks for every name the public would plausibly search under
  — business names, app names, and URLs. Our app name and domain both belong there.
- **Pay by card.** Card payment clears through Pay.gov in minutes and the designation publishes
  promptly; ACH takes materially longer.

**What the $6 actually buys.** The **mandatory precondition** for asserting § 512 at all, and a
start date that cannot be backdated. That is the whole of it today. **It does not buy protection
for copies our own systems made** — those are our acts — and, on the current architecture, it does
not yet buy a functioning safe harbor for anything else either. File it because it is cheap, because
the clock cannot start retroactively, and because it is correct hygiene for the user-storage surface
we intend to have. Do not file it believing it resolves present exposure.
<!-- #TOUPDATE: This paragraph previously claimed the $6 buys "a functioning § 512(c) safe harbor
     for the genuinely user-stored surface." That was wrong on this document's own reasoning and
     has been corrected — do not restore it. § 512(i)(1) is a THRESHOLD condition on ALL § 512
     limitations (§ 6 says exactly that), and the § 6 gate records that § 512(i)(1)(A) is
     architecturally impossible to implement as written while there are no accounts. A provider
     that fails § 512(i)(1) gets no § 512(c) safe harbor, functioning or otherwise, no matter how
     well it handles notices. So filing today buys the precondition and nothing more.
     This paragraph may be restored to claiming a functioning safe harbor only when the § 6
     prerequisites (1)-(5) are all satisfied — and see counsel Q2, which asks whether filing
     before accounts exist is worthwhile at all given that it starts the three-year clock and
     creates a public commitment we cannot yet honor. -->

---

## 2. How to submit a notice of claimed infringement

If you own a copyright, or are authorized to act for someone who does, and you believe material on
PocketDJ infringes it, send a written notice to the designated agent above.

**Preferred:** email to **{{DMCA_EMAIL}}** with the subject line `DMCA Notice`.
**Also accepted:** mail to the designated agent at **{{AGENT_MAILING_ADDRESS}}**.

Email is faster and we ask you to use it. Postal notices are honored, but the clock necessarily
starts on delivery.

**Please help us find the material.** PocketDJ stores each user's own copies separately, so the
single most useful thing a notice can contain is enough detail to identify a specific item —
a link or URL if you have one, and otherwise the exact track title, artist, and album, plus
anything that identifies where you encountered it (a session link, a shared tracklist, a profile
page). "Artist X's catalog" without more does not let us locate anything.
<!-- #TOUPDATE: The claim that each user's copies are stored separately depends on per-user storage
     keys, which do not exist today. -->

**If you are not the copyright owner**, you must be authorized to act on the owner's behalf. Say
who you represent.

**Nothing here waives anything.** Sending a notice, and our acting on it, does not admit
infringement, waive any defense either of us has, or resolve anything on the merits.

---

## 3. What a valid notice must contain (17 U.S.C. § 512(c)(3)(A))

For a notice to be effective under the statute, it must be a **written communication** provided to
the designated agent that includes **substantially all** of the following six elements. These are
the statutory elements; we are listing them, not adding to them.

1. **A physical or electronic signature** of a person authorized to act on behalf of the owner of
   an exclusive right that is allegedly infringed. § 512(c)(3)(A)(i).
2. **Identification of the copyrighted work** claimed to have been infringed — or, if a single
   notification covers multiple copyrighted works at a single online site, **a representative list**
   of those works. § 512(c)(3)(A)(ii).
3. **Identification of the material** claimed to be infringing or to be the subject of infringing
   activity, and that is to be removed or access to which is to be disabled, **and information
   reasonably sufficient to permit us to locate the material**. § 512(c)(3)(A)(iii).
4. **Information reasonably sufficient to permit us to contact you** — for example an address,
   telephone number, and, if available, an email address. § 512(c)(3)(A)(iv).
5. **A statement that you have a good faith belief** that use of the material in the manner
   complained of is not authorized by the copyright owner, its agent, or the law.
   § 512(c)(3)(A)(v).
6. **A statement that the information in the notification is accurate, and — under penalty of
   perjury — that you are authorized to act** on behalf of the owner of an exclusive right that is
   allegedly infringed. § 512(c)(3)(A)(vi).

**Substantial compliance.** § 512(c)(3)(B) sets out what happens when a notice falls short. A
notification that fails to comply substantially with all of § 512(c)(3)(A) is not considered in
determining whether we have actual knowledge or awareness of infringing activity. But if it
substantially complies with elements **2, 3, and 4** above (clauses (ii), (iii), and (iv)), we will
promptly attempt to contact you, or take other reasonable steps to assist in the receipt of a
notification that does substantially comply. In plain terms: if your notice identifies the work,
identifies the material, and tells us how to reach you, we will not simply discard it — we will
come back to you for whatever is missing.

**A note on § 512(f).** Under § 512(f), a person who **knowingly materially misrepresents** that
material is infringing is liable for damages, including costs and attorneys' fees, incurred by the
alleged infringer, by any copyright owner or authorized licensee, or by the service provider,
as a result of our relying on the misrepresentation. The same liability applies to a knowing
material misrepresentation in a counter notification (§ 5 below). Please be sure of your claim
before you send it.

---

## 4. What we do when we receive a notice

1. **We review it** against the elements in § 3.
2. **If it is complete, we act expeditiously** to remove the identified material or disable access
   to it.
   <!-- #TOUPDATE: "Remove or disable access" is not satisfied by deleting the origin object today.
        Audio is served from a public-read storage prefix, and catalog surfaces (including lyrics
        text and mirrored artwork) are fronted by a CDN with long cache lifetimes — one year and
        immutable for artwork, one day for lyrics. A cached copy keeps serving after the origin
        object is gone, so on today's infrastructure deletion alone leaves the material publicly
        reachable for as long as the cache lifetime. No cache-invalidation step appears anywhere in
        this process. Required before publishing: a CDN invalidation as a mandatory step of the
        takedown runbook, verified by fetching the URL from outside the cache after a test
        takedown and getting a 404 — plus a decision on whether "expeditiously" is compatible with
        the immutable one-year artwork policy at all. -->
3. **We take reasonable steps to promptly notify the affected user** that their material has been
   removed or disabled, and we forward them a copy of the notice so they can respond.
   § 512(g)(2)(A).
   <!-- #TOUPDATE: Requires user accounts with a contact channel. There is no per-user identity in
        the service today and therefore no one to notify. See §6. -->
4. **We record it.** Each notice, our response, the date, and the material affected go into a
   retained log, which is also how the repeat-infringer policy in § 6 is administered.
   <!-- #TOUPDATE: Requires a notice log and retained access records. No such log exists, and no
        request-level access logging is configured on the storage that serves user audio. Enable
        logging BEFORE this claim is published. -->
   <!-- #TOUPDATE: THIS LOG IS AN UNDECLARED PERSONAL-DATA COLLECTION. It binds a complainant's
        identity (name, address, phone, email, from the notice) to a user's identity and to
        specific works, and retains that binding. PRIVACY.md does not cover it: its Appendix B maps
        server logs to Diagnostics ▸ Other, which does not describe a retained identity-to-identity
        register, and its retention table has no row for it. Before this sentence is published,
        PRIVACY.md needs (a) a collection entry describing the notice log and its lawful basis,
        (b) a retention period in the retention table, and (c) the App Store nutrition label
        updated to match. Adding a retention log to a policy without adding it to the privacy
        policy is how the two documents end up contradicting each other in public. -->
5. **If it is incomplete**, we handle it per the substantial-compliance rule in § 3.

**We do not monitor.** Consistent with § 512(m), nothing in this policy commits us to affirmatively
monitor our service or to seek out infringing activity. We act on notices, on our own knowledge,
and on the standard technical measures described in § 6.

---

## 5. Counter notification

If your material was removed or disabled and you believe that happened by mistake or
misidentification, you may send a counter notification to the designated agent in § 1.

### 5.1 What a counter notification must contain (17 U.S.C. § 512(g)(3))

1. **Your physical or electronic signature.** § 512(g)(3)(A).
2. **Identification of the material that was removed or disabled, and the location at which it
   appeared before it was removed or access to it was disabled.** § 512(g)(3)(B).
3. **A statement under penalty of perjury that you have a good faith belief that the material was
   removed or disabled as a result of mistake or misidentification** of the material.
   § 512(g)(3)(C).
4. **Your name, address, and telephone number**, and a statement that **you consent to the
   jurisdiction of the Federal District Court** for the judicial district in which your address is
   located — or, if your address is outside the United States, for any judicial district in which
   we may be found — **and that you will accept service of process** from the person who submitted
   the original notification, or from that person's agent. § 512(g)(3)(D).
   <!-- #TOUPDATE: THIS COLLECTION IS UNDECLARED IN ALL THREE PRIVACY ARTIFACTS. Running the
        counter-notice process means collecting a user's real name, PHYSICAL ADDRESS, and
        TELEPHONE NUMBER, and forwarding all of it to the complaining party (§ 5.2). Today:
          - PRIVACY.md Appendix B declares Contact Info ▸ NAME ONLY. No Physical Address, no Phone
            Number.
          - PRIVACY.md has no section covering counter-notices at all — the word does not appear
            in it.
          - The .xcprivacy manifests do not exist in either target, so the collection is
            undeclared there too.
        PRIVACY.md itself warns that App Review rejects under Guideline 5.1.1 when the nutrition
        label and the policy disagree, and this is exactly that disagreement. Required before
        publishing: add Physical Address and Phone Number to the label and to Appendix B, add a
        counter-notice collection-and-disclosure section to PRIVACY.md (including the mandatory
        forwarding, which is a DISCLOSURE TO A THIRD PARTY and must be declared as one), and ship
        the privacy manifests. See counsel Q5, which covers the GDPR angle; this gate is the
        separate label/manifest angle. -->

### 5.2 The statutory waiting period

This is the part people are most often surprised by, so here it is precisely.

On receiving a counter notification that complies with § 512(g)(3), we will:

1. **Promptly provide the person who sent the original notice with a copy of your counter
   notification**, and inform them that we will replace the removed material or cease disabling
   access to it in **10 business days**. § 512(g)(2)(B).
2. **Replace the material, or cease disabling access to it, not less than 10 nor more than 14
   business days following our receipt of the counter notification** — **unless** our designated
   agent first receives notice from the original complaining party that they have **filed an action
   seeking a court order** to restrain you from engaging in infringing activity relating to that
   material on our system or network. § 512(g)(2)(C).

So: **10 business days minimum, 14 business days maximum, and a filed lawsuit stops the clock.**
We cannot shorten the 10 days, and we do not intend to exceed the 14.

**Your details go to the other side.** A counter notification contains your name, address, and
telephone number, and we are required to forward a copy of it to the person who submitted the
original notice. It also consents to federal court jurisdiction. Do not send one casually.

**Good-faith takedowns.** § 512(g)(1) protects us from liability to you for removing or disabling
material in good faith on the basis of a notice or apparent infringing activity, whether or not the
material is ultimately determined to be infringing. Where the material resides on our system at a
subscriber's direction, that protection additionally depends on our following the notification and
put-back steps in § 512(g)(2) — which we do.
<!-- #TOUPDATE: Corrected; do not revert. This previously conditioned § 512(g)(1) on "provided we
     follow the notification and put-back steps above," which is not what the statute says.
     § 512(g)(1) states the general good-faith protection without those conditions; it is
     § 512(g)(2) that attaches them, and only for material residing on the system at a
     subscriber's direction. The old wording erred conservatively (it promised more process than
     the statute requires, so the risk was low) but a document that quotes the statute precisely
     everywhere else should not paraphrase it loosely here. Have counsel confirm the corrected
     split before publishing. -->

---

## 6. Repeat infringer policy (17 U.S.C. § 512(i))

**This is not optional and it is not a courtesy.** § 512(i)(1) makes the following a **threshold
condition** on *all* of the § 512 safe harbors — not just § 512(c). A service provider that has not
satisfied it does not get any of them, no matter how well it handles individual notices.

§ 512(i)(1) requires that a service provider:

- **(A) adopt and reasonably implement, and inform subscribers and account holders of, a policy
  that provides for the termination in appropriate circumstances of subscribers and account holders
  of the service who are repeat infringers**; and
- **(B) accommodate and not interfere with standard technical measures** used by copyright owners
  to identify or protect copyrighted works.

**Our policy.**

<!-- #TOUPDATE: EVERY sentence in this subsection is forward-looking. PocketDJ has no user accounts
     today. The app mints a local profile identifier and display name, but the backend has no
     per-user identity: it authenticates with a single shared token and cannot tell one user from
     another. There is therefore nobody to terminate, which makes § 512(i)(1)(A) not merely
     unimplemented but architecturally impossible to implement as written. Required before this
     section is published: (1) real per-user accounts; (2) per-user storage and access scoping so a
     single user's material can be identified and removed; (3) a strike record attached to an
     account; (4) an enforceable termination mechanism, including preventing a terminated user from
     simply re-registering; (5) this policy actually shown to users at sign-up. Until those exist,
     this section describes an intention, not a practice — and publishing it as a practice would be
     a misrepresentation. -->

1. **We terminate repeat infringers.** If a user's material is repeatedly the subject of valid
   notices of claimed infringement, we will terminate that user's account and their access to
   PocketDJ cloud services in appropriate circumstances.
2. **How we count.** We record each valid notice against the account whose material it concerns.
   Notices withdrawn by the complaining party, and notices successfully answered by a counter
   notification that results in the material being restored, are not counted. We do not publish a
   fixed strike number, because "appropriate circumstances" is a judgment about the pattern —
   volume, whether the same work recurs, whether the user responded, and whether the conduct
   continued after warning — and a fixed number invites gaming in both directions. In practice,
   repeated valid notices after a warning will result in termination. **We may also terminate
   immediately, without a prior warning and on a single notice, for a clear and serious instance
   of infringement.**
   <!-- #TOUPDATE: TERMINATION TRIGGER MUST BE RECONCILED WITH TERMS.md §9.3 BEFORE PUBLICATION.
        TERMS.md §9.3 states: "We may also terminate immediately for a single instance of clear and
        serious infringement." This section previously told the user only that REPEATED notices
        after a warning lead to termination — a narrower and more generous rule than the one
        TERMS.md publishes. The single-instance sentence has been added here to match, but the
        reconciliation is not complete:
          - the counter-notice carve-out below ("are not counted") appears ONLY in this document;
            TERMS.md contains no such carve-out, so the two still describe different counting
            rules;
          - decide which document is authoritative on termination and make the other cite it
            rather than restate it. Two published documents stating different termination rules is
            the defect; duplicating prose is what caused it.
        Until reconciled, do not publish either § 6.2 or TERMS.md §9.3. -->
3. **What termination means.** The account is closed, the user's stored material is removed from
   PocketDJ cloud services, and re-registering to evade termination is itself a violation.
4. **We tell users about this policy** at sign-up and in the app's legal section, which is what
   § 512(i)(1)(A) requires — adopting a policy is not enough; users must be informed of it.
   <!-- #TOUPDATE: THE "INFORM SUBSCRIBERS" LIMB HAS NO DELIVERY MECHANISM. This sentence names two
        channels and NEITHER EXISTS: there is no sign-up (there are no accounts), and there is no
        in-app legal section — nothing in the app links to this document, TERMS.md, or PRIVACY.md
        at all. The § 6 gate above lists accounts as prerequisite (5) "shown to users at sign-up,"
        but an in-app legal section is a SEPARATE prerequisite that list omits, and so does the
        Prerequisites section at the end of this document (whose item 5 says "link it from the
        app's legal section" as though one already existed). Required before publishing: an in-app
        legal section that actually links all four legal documents, reachable without an account,
        plus the sign-up presentation once accounts exist. § 512(i)(1)(A) is a threshold condition
        on every safe harbor and "informed" is one of its limbs — a policy nobody can reach has not
        informed anyone. -->
5. **Standard technical measures.** We accommodate and do not interfere with standard technical
   measures as defined in § 512(i)(2) — measures developed through an open, broad, consensus-based
   process, available on reasonable non-discriminatory terms, and not imposing substantial costs or
   burdens on our systems.

**One honest caveat, stated because it is load-bearing.** A repeat-infringer policy is only
effective if it is *reasonably implemented*, and reasonable implementation requires the ability to
identify a user, attribute material to them, keep a record across time, and actually terminate
them. A policy written on a service that cannot do those things is a document, not a policy, and
courts have said so. This is why the #TOUPDATE above gates the whole section on real accounts.

---

## 7. For users: what happens if content you uploaded is subject to a notice

Plain language, no legalese.

**What you'll see.** If someone sends us a valid copyright notice about something you put in
PocketDJ, we'll take that item down and email you. We'll tell you what came down and send you a
copy of the notice, including who sent it and what they say they own.
<!-- #TOUPDATE: WE CANNOT EMAIL YOU. No email address is collected anywhere in the product — the
     stored profile is a bare identifier and a display name, nothing more. There is no contact
     channel of any kind, so this promise cannot be kept today. §4.3 carries a gate on the
     identical commitment; this restatement needs its own, because this is the section users
     actually read and a reader will never see §4.3's comment. Requires: accounts with a verified
     contact address (see §6). Do not publish this paragraph before that exists. -->

**What comes down.** Only the specific item identified in the notice. Your other music, your
playlists, your sets, your mixes, and your device-local files aren't affected. If you have that
track downloaded on your device, that copy is on your device — taking down the cloud copy doesn't
reach it.
<!-- #TOUPDATE: THIS IS THE MOST DANGEROUS CLAIM IN THE DOCUMENT. IT IS FALSE TODAY IN BOTH
     DIRECTIONS, AND IT MISLEADS BOTH AUDIENCES AT ONCE.
     Stored audio objects are keyed by SONG, not by user, and they live in ONE SHARED BUCKET. The
     server serves the first requester's stored object to every later requester of the same song.
     Consequences:
       - TO THE USER, this paragraph promises an isolation that does not exist. Deleting the
         identified object removes that song for EVERY user who has it, not just the user named in
         the notice. "Your other music isn't affected" is true only of the notified user's OTHER
         songs; it is false as to every other user's copy of THIS song.
       - TO THE RIGHTS HOLDER, it implies a surgical, per-user removal capability we do not have.
         Representing a takedown precision we cannot deliver is a misrepresentation to the party
         most likely to test it.
     Requires: per-user storage keys and per-user access control — the same prerequisite as §0's
     "each user's copies are their own" gate and §2's locate-the-material gate. All three are the
     same architectural change; none of them can be published before it lands.
     NOTE the device-local sentence is accurate and should survive the rewrite — see counsel Q7. -->

**Why this happens even if you did nothing wrong.** We are required to act expeditiously on a
valid notice. We are not in a position to adjudicate who owns what, and we don't try to. Notices
are sometimes mistaken. That's exactly what the counter-notification process exists for.

**If you think it's a mistake.** Send us a counter notification (§ 5). It has to include your real
name, address, and phone number, a statement under penalty of perjury that you believe the removal
was a mistake or misidentification, and your agreement that a federal court can hear the dispute.
**We are required to forward a copy of it, with your contact details, to the person who complained.**
That is not a choice we make — it is what the statute requires.
<!-- #TOUPDATE: Same undeclared-collection gate as §5.1.4, restated here because this is the
     user-facing version. Asking a user for a home address and phone number, and disclosing both to
     a third party, is a collection and a disclosure that PRIVACY.md, the App Store nutrition label,
     and the (nonexistent) privacy manifests all fail to declare. Fix those before this paragraph
     is published. -->

**Then you wait.** By law we can't put the material back sooner than **10 business days** after we
receive your counter notification, and we'll put it back by **14 business days** — unless the person
who complained tells us they've gone to court to stop you. If that happens, the material stays down
while the court sorts it out.

**Be careful what you sign.** Lying in a counter notification is not a small thing: § 512(f) makes
a knowing material misrepresentation actionable, and the counter notification is made under penalty
of perjury. If you're not sure whether you have the rights to something, the honest move is to
leave it down.

**If it keeps happening.** Repeated valid notices about your material will get your account
terminated, and a single clear and serious instance of infringement can too. We have to do this —
it's a condition of the legal protections that let a service like this exist at all. It isn't
discretionary and we can't make exceptions.
<!-- #TOUPDATE: Requires user accounts. See §6. -->
<!-- #TOUPDATE: The single-instance clause was added to match §6.2 and TERMS.md §9.3, which both
     allow immediate termination without a warning. This paragraph previously described only the
     repeated-notice path, which understated the rule to the user in the one place the user
     actually reads it. Re-check this sentence whenever §6.2 or TERMS.md §9.3 changes — all three
     have to say the same thing. -->

**What we can't do.** We can't give you legal advice, we can't tell you whether your use is fair
use, and we can't take sides in a dispute between you and a rights holder. If a notice matters to
you, talk to a lawyer.

**The thing that prevents all of this.** PocketDJ only works if you have the rights to the music
you put in it — records you own, files you bought, recordings you made. That's what you confirmed
when you set the app up, and it's the whole basis of the design.
<!-- #TOUPDATE: YOU CONFIRMED NO SUCH THING. First-run onboarding has three stages — profile,
     Apple Music, sources — and NONE of them is a rights attestation. There is no attestation of
     any kind in the product. §0's closing bullet gates this exact claim; this restatement needs
     its own gate, because it is the version a user actually reads and it is stated as settled
     fact about something they supposedly did.
     Second defect in the same sentence: the enumeration "records you own, files you bought,
     recordings you made" omits audio captured from Apple Music, which the shipped app still
     performs. Telling a user this list is the whole basis of the design, while the app is doing
     something not on the list, is the misrepresentation this document exists to prevent.
     Requires: the first-run rights attestation gate to exist AND the capture path to be gone (see
     the §0 capture gate). Both, not either. -->

---

## 8. Other rights, other complaints

- **Trademark, publicity, defamation, or other non-copyright complaints** are not handled by this
  policy or by the designated agent. Send those to {{CONTACT_EMAIL}}.
  <!-- #TOUPDATE: {{CONTACT_EMAIL}} must be a real, monitored mailbox before publication. -->
- **Requests to remove metadata** — a title, an artist name, a tracklist entry — are handled by
  the same address. We will look at them, but note that titles, artists, tempos, and keys are facts
  about recordings rather than the recordings themselves. **This does not extend to lyrics or
  album artwork.** Song lyrics are copyrighted literary works and cover art is a copyrighted
  pictorial work; neither is a fact about a recording, and requests concerning them are handled as
  copyright notices under this policy, not as metadata requests.
  <!-- #TOUPDATE: THIS CARVE-OUT MUST NOT BE PUBLISHED WITHOUT THE LYRICS/ARTWORK EXCLUSION ABOVE,
       which was added because the unqualified version contradicted §0's own gate. §0's
       metadata-only bullet already names both: the public catalog today serves a full LYRICS
       CORPUS as plain text and MIRRORED ALBUM ARTWORK, both publicly fetchable through the CDN.
       A rights holder reading the unqualified sentence was being told their lyrics are "facts
       about recordings." They are not, and stating otherwise in a published policy is the kind of
       affirmative position that gets quoted back.
       This exclusion narrows the exposure but does not remove it: the underlying problem is that
       we publish the corpora at all, and §0's gate requires "no publicly served lyrics corpus, no
       publicly served mirrored artwork" before that bullet may be published. Both gates have to
       clear together. See counsel Q8, and note the takedown-cache gate in §4 — long CDN lifetimes
       apply to exactly these two corpora. -->
- **This policy addresses U.S. law.** § 512 is a United States statute. Notice-and-takedown regimes
  elsewhere differ, sometimes materially. We will act on well-founded complaints from anywhere;
  the specific statutory mechanics above are U.S. ones.

---

## 9. Changes

We may update this policy. If the designated agent's details change, we will update both this page
and the Copyright Office registration — the registration must be amended (which also resets the
three-year renewal clock), and an out-of-date registration risks the safe harbor.

---

## Placeholders in this document

Every one of these must be replaced with a real, verified value before publication. None of them
has an assumed value; do not guess.

| Placeholder | What it is | Notes |
|---|---|---|
| `{{EFFECTIVE_DATE}}` | Date this policy takes effect | Should be on or after the date the Copyright Office designation is filed |
| `{{LEGAL_ENTITY}}` | The service provider's legal name | Sole proprietor vs. an entity is an open question — see counsel Q1 |
| `{{APP_STORE_NAME}}` | The app's App Store name | List as an alternate name on the Copyright Office designation |
| `{{PRIMARY_DOMAIN}}` | The domain the policy is hosted on | **Unmet prerequisite:** `pocketdj.app` is NOT registered **to us** — it resolves, so it is registered to someone (third party or parking service). Acquire it, or choose a domain we own |
| `{{DMCA_POLICY_URL}}` | Canonical public URL of this policy | Must be decided **before** filing — the designation names it and this page names the designation. Changing it later requires amending the registration (which resets the three-year clock) |
| `{{AGENT_NAME}}` | The designated agent, a named person or role | **Token collision:** TERMS.md calls this `{{DMCA_AGENT_NAME}}`. Unify before substituting |
| `{{AGENT_MAILING_ADDRESS}}` | Physical street address | **Becomes public** in the Copyright Office directory. P.O. box not permitted for the service provider without a waiver. **Token collision:** TERMS.md uses `{{DMCA_AGENT_ADDRESS}}`; PRIVACY.md uses `{{POSTAL_ADDRESS}}` |
| `{{AGENT_PHONE}}` | Telephone number for the agent | Required by § 512(c)(2). **Exists only in this document** — TERMS.md and PRIVACY.md have no phone placeholder, so their agent blocks omit a required datum. Add one to each |
| `{{DMCA_EMAIL}}` | Mailbox for copyright notices | Must exist and be monitored **before** publication and before filing. **Token collision:** TERMS.md uses `{{COPYRIGHT_AGENT_EMAIL}}` |
| `{{CONTACT_EMAIL}}` | General abuse/support contact | Same requirement |
| `{{GOVERNING_LAW_STATE}}` | Governing-law state, if this policy is referenced from the EULA | Not used in the body above; listed because the EULA cross-references it |

<!-- #TOUPDATE: DO NOT RUN A SUBSTITUTION PASS UNTIL THE TOKEN SETS ARE UNIFIED ACROSS DMCA.md,
     TERMS.md, and PRIVACY.md. § 512(c)(2) requires identical agent contact information in the
     Copyright Office registration and on the public site; three token sets for the same three
     facts is how they end up different. See the collision note in §1. After unifying, verify by
     grepping all three documents for each token and confirming the substituted values match
     character for character. -->
<!-- #TOUPDATE: KEEP THIS DOCUMENT FREE OF INTERNAL SOURCE LOCATIONS. This file has been checked
     and carries no hostnames, ports, bucket identifiers, account ids, or repo paths — keep it that
     way. Note that PRIVACY.md embeds source-file paths and line numbers in its own #TOUPDATE
     comments; that is fine internally but must be stripped before that document is published,
     since HTML comments ship to the reader. -->
<!-- #TOUPDATE: Verify {{DMCA_POLICY_URL}} was added to the token-unification pass too — it is new
     in this revision and has no counterpart in TERMS.md or PRIVACY.md yet, though both should
     link to it. -->

---

## Prerequisites this document depends on

Ordered. Each blocks the one after it.

1. **Register a domain we actually own.** `pocketdj.app` is unregistered by us. Every URL and email
   address in this policy depends on this.
2. **Create and monitor `{{DMCA_EMAIL}}` and `{{CONTACT_EMAIL}}`.** A bounced notice is affirmative
   evidence that § 512 is not implemented.
3. **Decide the service provider legal entity and the public address** (§ 1.1). The address is
   permanently public. A commercial address takes days to procure; safe harbor accrues only from
   the filing date, so this is a real trade.
4. **Unify the placeholder tokens** across DMCA.md, TERMS.md, and PRIVACY.md, and add a phone
   placeholder to the two that lack one. § 512(c)(2) requires the same agent details everywhere;
   three token sets guarantee they diverge.
5. **Decide `{{DMCA_POLICY_URL}}`** before filing. The designation names the posting location and
   the posting carries the designation; changing the URL later means amending the registration.
6. **File the designation** at dmca.copyright.gov, $6, by card. Diary the three-year renewal.
7. **Build an in-app legal section.** There is none today — nothing in the app links to this
   policy, the terms, or the privacy policy. § 512(i)(1)(A) requires that users be *informed* of
   the repeat-infringer policy, and a document nobody can reach from the app has informed nobody.
   This is a separate prerequisite from accounts and it is not satisfied by publishing on the web.
8. **Publish this policy** at a public, login-free URL that actually serves this content, and link
   it from the in-app legal section built in step 7. § 512(c)(2) requires both the Copyright Office
   registration and the public posting.
9. **Build the account system** that § 6 depends on. Until users exist, the repeat-infringer policy
   cannot be reasonably implemented, and § 512(i) gates *every* safe harbor.
10. **Land per-user storage keys and per-user access control.** Four separate claims in this
    document depend on this one change — §0's "each user's copies are their own," §2's "enough
    detail to identify a specific item," §7's "only the specific item comes down," and §6's
    per-user removal on termination. Objects are song-keyed in one shared bucket today, so a
    takedown for one user removes the song for all of them.
11. **Remove the Apple Music capture path** (see the §0 capture gate) and reconcile the derivative
    pipelines with §0's provenance sentence. This blocks publication outright: the policy denies a
    capability the product currently has.

---

## Questions for counsel

These are the specific questions this document could not resolve. It was written by an engineer for
review by a lawyer; it is not legal advice and should not be published without that review.

1. **Entity and address.** Should the § 512 designation be filed in a personal name or an entity?
   The service provider's street address becomes permanently public in the Copyright Office
   directory. Is a registered-agent or commercial address worth the delay to procure, given that
   the safe harbor does not accrue until the filing date and the registration is amendable
   afterward?
2. **Is filing worthwhile now, before there are accounts?** § 512(i) conditions all safe harbors on
   a *reasonably implemented* repeat-infringer policy, and with no user accounts there is nobody to
   terminate. Does § 512 offer anything at all before multi-tenancy exists — or does filing early
   simply start the three-year clock and create a public commitment we cannot yet honor?
3. **The scope statement in § 0, and the two § 512(c)(1) conditions that are not about notices.**
   Is the characterization of § 512(c) as covering only user-directed storage — and specifically
   not copies our own systems made, material we publish ourselves, or transmissions we make —
   stated correctly, and stated *conservatively enough* that nothing in this policy could be read
   as a broader representation than the statute supports? Separately and more urgently: how exposed
   are we on **§ 512(c)(1)(B)** (direct financial benefit plus the right and ability to control)
   and on **§ 512(c)(1)(A)(ii)** (red-flag awareness)? The facts cut badly in both directions — a
   single operator hand-curated the corpus, that operator's own server performs the copying, and
   every object sits in one bucket under sole control. Does the "right and ability to control"
   analysis change if per-user scoping lands? And for a hand-picked corpus of commercially
   released music, is red-flag awareness realistically defensible at all?
4. **Repeat-infringer thresholds.** We deliberately do not publish a fixed strike count, on the
   theory that "appropriate circumstances" is a pattern judgment. Is a published, mechanical
   threshold (e.g. three strikes) safer in practice, given the case law on reasonable
   implementation?
5. **Counter-notice forwarding, privacy, and disclosure.** § 512(g)(2)(B) requires forwarding the
   counter notification, which contains the user's home address and phone number, to the
   complaining party. Does this create any obligation or exposure under state privacy law, GDPR, or
   UK GDPR for non-U.S. users, and should the § 7 warning be stronger? Note the separate and more
   immediate compliance problem: this collection and this third-party disclosure are declared
   **nowhere** — not in PRIVACY.md, not in the App Store nutrition label (which declares name
   only), and not in the privacy manifests (which do not exist). Is running the counter-notice
   process at all conditional on fixing those first?
6. **Non-U.S. users and non-U.S. notices.** Should we operate a single § 512-shaped process
   worldwide, or a separate path for jurisdictions with different notice-and-takedown regimes? This
   interacts with the open question about restricting App Store territories.
7. **Device-local copies.** § 7 tells users honestly that a takedown of the cloud copy does not
   reach a copy already downloaded to their device. Is that the right thing to say, and does
   saying it create any obligation to build remote invalidation?
8. **The metadata carve-out in § 8.** Is declining to remove titles, artists, and tempos on the
   ground that they are facts about recordings a position we should state in a published policy, or
   should the policy stay silent and handle those case by case?
9. **Standard technical measures.** § 512(i)(1)(B) requires accommodating them. Are there any
   measures in the music industry today that we would be expected to accommodate, and does
   anything in the current design interfere with one?
10. **Sequencing against App Review.** Publishing this policy is a representation about how the
    product behaves. Which of the #TOUPDATE items in this document are hard blockers on publishing
    it at all, versus items that can follow?
11. **§ 1201 and Title I.** This document addresses only Title II (§ 512). The shipped product
    captures audio delivered under DRM through Apple Music, which is § 1201 anti-circumvention
    territory — a separate statute with no notice-and-takedown cure and no safe harbor that a
    designation buys. Two questions: does a document titled "Copyright and DMCA Policy" need to
    address Title I to be complete on its own terms, and does the § 1201 exposure survive removing
    the capture path (i.e. is there residual liability for captures already made and stored)?
12. **Which safe harbors to claim.** One designation supports § 512(b), (c), and (d). The draft
    § 0 asserts only (c) and expressly declines (b) and (d), but the product runs a public
    metadata catalog with full-text search plus a query proxy to a third-party catalog API
    (§ 512(d) territory) and CDN-cached lyrics and artwork (§ 512(b) territory). Is disclaiming
    (b) and (d) the right posture, or does asserting them cost nothing? If we disclaim them,
    should the policy say so affirmatively, given that the filing itself will read as claiming all
    three?
13. **"Private performances."** § 0 characterizes jukebox sessions as private performances hosted
    by the user. This project's own posture review reaches the opposite conclusion — that jukebox
    guests are the *Aereo* audience, "unrelated and unknown to each other," which describes a
    public performance under the transmit clause. Token gating, listener caps, and expiry are
    mechanical; none of them converts a QR-code request line at a public event into a private
    performance. Which characterization is right, and if it is the posture review's, what has to
    change in the product rather than in the policy?
