state: implemented

# P2-REM-10 - Internet broker transport over the jukebox server (/remote long-poll routes)

- [x] scripts/jukebox-server.mjs: `/remote` relay (create, join, send, 25 s long-poll, leave), in-memory ring buffer (count + bytes), TTL sweep (silent participants, idle rooms), per-room participant cap, global room cap, per-IP sliding windows (create/join, and a looser one for send/poll, rightmost X-Forwarded-For). health.version 4 + `remote: true`.
- [x] scripts/test/jukebox-remote-routes.test.mjs: 18 node tests against the real server (spawned on a free port, dry-run, isolated home). `node --test` green.
- [x] BrokerRemoteTransport.kt: `BrokerApi` (OkHttp, suspend, cancellable) + `BrokerRemoteTransport` (poll loop with cursor/rev, ordered send loop, retry/backoff, session end on 401/404/410 or N poll failures).
- [x] BrokerRemoteStarter.kt: "Over the internet" `RemoteSessionStarter` (create + join as creator; join by 8-char code; mode comes back on join).
- [x] JukeboxUrls (touchpoint): remoteCreate / remoteRoom / remotePoll. RemoteScreen (touchpoint): "Over the internet" switch, hidden when jukeboxServerUrl is blank, with the Mix Together Wi-Fi note; broker sessions skip the Nearby permission gate. RemoteGraph: brokerServer + brokerStarter.
- [x] BrokerRemoteTransportTest (MockWebServer): 19 tests.

## Wire (so a future iOS BrokerTransport joins unchanged)
- POST /remote {mode?} (Bearer = JUKEBOX_TOKEN when set) -> {roomId, joinCode, hostSecret}. roomId is the lower-cased 8-char joinCode.
- POST /remote/{id}/join {participantId?, name?, joinCode} (or Bearer hostSecret) -> {participantId, secret, mode}
- POST /remote/{id}/send {to:"all"|id, reliable, env:{v,kind,payload}} (Bearer secret) -> {seq}. The server stamps `from`; never echoes to the sender.
- GET /remote/{id}/poll?since&rev (Bearer secret) -> {events:[{seq,from,to,reliable,env}], roster:[{id,name}], rev, cursor, dropped}; held up to 25 s, wakes on send / roster change.
- POST /remote/{id}/leave. Everything also works under the `/jukebox` funnel mount.

## Deviations / notes
- Files outside the owned list: di/RemoteGraph.kt (brokerServer, brokerStarter), JukeboxUrls.kt and RemoteScreen.kt (declared touchpoints). No manifest/gradle changes, so assembleRelease was not run.
- The invite on the internet path is the bare 8-char code; the QR carries `pocketdj://remote/join/<code>`, which the deep-link handler routes to whichever starter is selected. A scanned link on a device with the switch off tries Nearby. (Nearby tokens and broker codes share a shape, so they can't be told apart.)
- `dropped` polls are only logged; the controller's existing state re-request recovers the queue.
- maxStateBytes is 48 000 (server body cap is 64 KB).
- The keep-alive foreground service is started by the Nearby starter's session observer for any session, broker included (best effort, unchanged).
- Emulator step and a real two-client run were not performed (emulator not allowed); node tests cover the server, MockWebServer tests the client.
- Not deployed anywhere.

## Questions for Levi
- Deploy the jukebox-server /remote broker routes to jukebox.pocket-dj.com so Remote works over the internet (and later iOS<->Android)? Default taken: local build + tests only.
- Should scanning an invite QR auto-pick the internet path (e.g. a distinct URL host/prefix for broker codes)? Today the "Over the internet" switch decides.
