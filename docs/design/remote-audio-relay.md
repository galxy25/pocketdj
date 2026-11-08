# Remote audio relay — host device as the audio source (PARKED)

Status: **parked 2026-11-08**. Levi: "On doing SharePlay what I saw streaming of audio until later,
just parked at design and plan for us to circle back to." Nothing here is built.

## The ask

For Backseat and Listen Together, the device that starts the session should be the primary
device, and its audio is broadcast to the other devices. Today (1.0.5) every device plays the
shared queue from its OWN access: its library, its rips and downloads, or its listener's own Apple
Music. Songs a device can't play are skipped there.

## What SharePlay gives us (and doesn't)

- SharePlay (GroupActivities) is a session and coordination layer, not a network you choose. All
  participants join one `GroupSession`. Messages go to everyone or to chosen participants, routed
  through Apple's servers. There is no peer-to-peer or star topology to pick, and no audio
  transport.
- Sessions start from a FaceTime call, Messages or the share sheet, or by bringing iPhones together
  (nearby sharing, iOS 17). How nearby sessions route their data isn't documented.
- Data channels:
  - `GroupSessionMessenger`: small messages, either `.reliable` (ordered) or `.unreliable` (low
    latency). Apple doesn't publish the per-message limit; third-party guides put it around 256 KB.
  - `GroupSessionJournal` (iOS 17+): file attachments of up to 100 MB each, kept while anyone is
    still in the session, so late joiners get them too.
- Apple's model assumes each participant plays the content locally with their own access. That is
  what 1.0.5 does.

## Proposed design

**Control plane: unchanged.** SharePlay keeps the invite, roles (host/participant,
speaker/controller), commands, queue state and the shared clock (`SharedClock`).

**Data plane, nearby (new): a direct link.** Network.framework `NWListener` on the host plus an
`NWBrowser`/`NWConnection` on each joiner, with `includePeerToPeer = true`. That uses
infrastructure-free Wi-Fi, so two phones in a car with no router and no cell coverage still connect.
- The host advertises a Bonjour service. Its name and a per-session token travel over the
  SharePlay messenger.
- Joiners connect and authenticate with the token. Use TLS with a PSK derived from the session
  token.

**Data plane, remote (fallback).** `GroupSessionJournal` attachments (≤100 MB per file) carry
whole files. A live mix stream over `.unreliable` messages is possible but untested.

### Two content modes

**1. File relay (Listen Together, Backseat).**
- The host pushes each upcoming song's file (the burn/cut, or the shared album file plus the
  segment) a few songs ahead.
- Speakers play their local copy on the existing anchored clock sync.
- Survives link drops, plays gapless, and the speaker needs no library of its own.
- Backpressure: at most N songs or M MB ahead; evict after play. The 48 h expiry rule from Mix
  buffering applies.

**2. Live stream (Mix Together).**
- Only the host renders the decks. It taps the master bus (`houseSum` → limiter), encodes it as
  AAC-ELD or Opus at 20 ms frames and 96–128 kbps, and streams it.
- Participants are deck controllers plus listeners. Their gestures go to the host as they do
  today; only the host applies them to an engine.
- This replaces most of `MixSync`'s render-sync work (anchored starts, drift correction,
  per-device loads).
- Latency: about 50–150 ms nearby, 300 ms or more over FaceTime relay. That's fine to listen to and
  a little sluggish on faders. A jitter buffer on the receiver absorbs network variation.

## Constraints

- **Apple Music can't be relayed.** It's DRM-protected and the app can't capture its output. Those
  songs still play from each listener's own subscription. If they can't, the song is skipped there,
  as in 1.0.5.
- **Rights.** Relaying rips or downloads to other people's devices is distribution. That's fine for
  your own devices and passengers. **OPEN QUESTION for Levi:** relay to anyone in the session, or
  only to devices signed into the owner's account (CloudKit user record id match)?
- **Local network permission:** every device gets a one-time prompt. Needs
  `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_pocketdj-relay._tcp`).
- **macOS:** the sandbox needs `com.apple.security.network.server` to accept connections. Today it
  only has `network.client`.
- **tvOS** can receive (be a speaker). Hosting from tvOS isn't planned.
- **Battery:** a host pushing files plus a peer-to-peer radio. Keep the push window small.

## Plan, when unparked

1. Build `RelayTransport` (NWListener/NWConnection, peer-to-peer, PSK TLS). Bootstrap it over the
   SharePlay messenger.
2. File relay for Listen Together and Backseat: a host push queue, a speaker cache and resolver
   lane ("relayed" source ahead of "unavailable"), plus eviction.
3. Journal fallback when the peer-to-peer link can't connect.
4. Live master-bus stream for Mix Together: an encoder tap, a jitter-buffer player, and a
   controller-only participant mode.
5. Decide the rights scope above, then add settings and UI ("Playing from Levi's iPhone").
6. Test on devices: two phones in a car with no Wi-Fi, FaceTime remote, Mac + iPhone.

Version: Levi to decide between 1.0.6 and folding it into a later release. The 4-deck jam refactor
is also its own later release.
