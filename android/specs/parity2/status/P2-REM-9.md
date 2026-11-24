state: reviewed

# P2-REM-9 - Nearby Connections transport (offline) + QR/code invite + permissions + background keep-alive

- [x] NearbyInvite.kt: 8-char token, SHA-256 hash (only the hash goes on the air), endpoint name `device|hash|mode`, pocketdj://remote/join/<token>, accept rule
- [x] NearbyRemoteTransport.kt: `NearbyClient` seam (fakeable), frames (hi / roster / m), P2P_STAR relay host, per-session UUID handshake as the first frame, never echoes to sender, host stamps the sender, token-hash check in the connection request, auth digits callback, 30 KB state cap, host migration (lowest remaining id advertises, the rest rediscover by hash, 15 s timeout)
- [x] NearbyRemoteStarter.kt: GmsNearbyClient (ConnectionsClient), starter (start/joinWithCode/joinHost/discovery), RemoteKeepAliveService (connectedDevice FGS), installed by RemoteGraph.wire()
- [x] RemotePermissions.kt + RemoteScreen rationale dialog before start/join; auth digits under the invite QR
- [x] Manifest permissions + service, play-services-nearby 19.3.0, ParityFlags.REMOTE = true, deep link `pocketdj://remote/join/<token>` (parser, dispatcher pending slot, Remote screen consumes it)
- [x] Tests: NearbyFramingTest (17), NearbyInviteTest (5), RemotePermissionsTest (4), DeepLinkRemoteJoinTest (3), ManifestPermissionsTest (+1). Full suite 7486 tests, 0 failures/errors. assembleDebug + assembleRelease OK.

## Summary
Remote now runs over Google Nearby Connections with no server. The host advertises (service id com.levi.pocketdj.remote, P2P_STAR), joiners discover by the invite token's hash (or pick a host from the Nearby list), and the host relays participant->participant. Participant ids are per-session UUIDs from the first frame. The Remote half is enabled (ParityFlags.REMOTE = true).

## Deviations / files outside the owned list (all minimal, additive)
- New files: remote/NearbyRemoteStarter.kt (starter + GmsNearbyClient + keep-alive service), test files NearbyInviteTest / RemotePermissionsTest / DeepLinkRemoteJoinTest.
- di/RemoteGraph.kt (nearbyStarter + install in wire()), shell/DeepLinkDispatcher.kt + PendingOpenStore.kt (RemoteJoin link), RemoteScreen.kt (permission gate), manifest/gradle/libs/ParityFlags/DeepLinkParser/ManifestPermissionsTest (touchpoints).
- Keep-alive is a dedicated connectedDevice foreground service, not PlaybackService (media service FGS-type juggling is fragile; PlaybackService untouched).
- Host leaving: instead of a mesh, the star re-forms (migration above). Brief roster dip while peers reconnect.
- No unreliable lane on Nearby (all bytes payloads are reliable); `reliable=false` is ignored.
- Joining from the Nearby list has no token: it sends hash "-" and the host accepts it only while open joins are allowed (default true for the original host, false after migration). The auth digits are shown under the QR.
- Ran gradle WITHOUT --no-quiesce-fin: one-at-a-time.sh refuses to start with LM Studio models resident when that flag is set.
- Not run: emulator steps and the two-phone device checks (not allowed / need hardware).

## Questions for Levi
- Open join from the "Nearby" list (no token, auth digits only, host accepts automatically): OK, or should the host get an explicit Accept prompt?
- Device-verify: the connectedDevice keep-alive with the screen off for 10+ minutes; host hand-over timing.

## Review
Findings from the adversarial review, all addressed (fixes applied):
- MAJOR open join / hash echo authenticates nobody -> fixed. Open ("-") joins are held UNACCEPTED until the host approves them in a dialog (name + auth digits; 30 s expiry; PendingJoin / approveJoin / denyJoin; JoinApprovals in RemoteScreen). A matching token HASH (public, advertised) only gets a link: the joiner must send a proof (`NearbyInvite.proof`, a different digest of the token, inside the first frame) or, after a host migration, be a member of the previous roster. Tests: anOpenJoinWaitsForTheHostsExplicitApproval..., denyingAnOpenJoinRejectsIt, anUnansweredOpenJoinExpires, echoingTheAdvertisedHashWithoutTheTokenIsNotAdmitted, proof test.
- MAJOR discovery started outside the permission guard -> fixed. RemoteContent takes `canScan`; discovery starts only once scan permissions are held (re-keyed on grant), otherwise a "Find nearby sessions" button runs the guard.
- MINOR deep link only parks -> fixed. New `DeepLinkSeams.showRemote` seam (hub sets it to flip to the Remote half; called on a parked invite), parked token expires after 120 s. Tests added (DeepLinkRemoteJoinTest). The hub itself is outside this package, so the seam is the hand-off; end-to-end link-to-join needs the hub (P2-REM-8) to assign it.
- MINOR no retry after a failed outgoing connection -> fixed (up to 3 retries with backoff while finding, incl. migration). Test aFailedOutgoingConnectionIsRetried.
- MINOR leave() kills list discovery -> fixed. Starter remembers discoveryWanted and restarts the list scan after any transport teardown / session end.
- MINOR keep-alive FGS race -> fixed. The service always calls startForeground first, then stops itself if the session no longer wants it (KeepAliveWant flag). Still DEVICE-VERIFY with screen off.
- Also fixed a latent ordering bug the new tests exposed: the host now sends its `hi` before the first roster whichever side's connected callback fires first.

fixes applied
