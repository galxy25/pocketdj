state: implemented

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
