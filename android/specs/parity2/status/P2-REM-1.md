state: merged

# P2-REM-1 Remote pure core

- [x] RemoteWire.kt: envelope (standard base64), kinds, bodies, session mode/role, RemotePlaybackState
- [x] RemoteCommandSerializer.kt: Swift synthesized-enum Codable (single-key, `_0`), unknown case/shape throws -> message dropped
- [x] RemoteQueueModel.kt: apply/state/adopting, window 20/200, MIN_WINDOW_AHEAD 10
- [x] SharedClock.kt: best-of-8 lowest RTT, reset, host offset 0, pong sender check
- [x] Tests + goldens (47 new JVM tests: 17 wire, 21 queue model, 9 clock; full suite 6212, 0 failures)
- [x] :app:testDebugUnitTest :app:assembleDebug green (no manifest/gradle/proguard touched, so no assembleRelease)

## Notes / deviations
- No existing file touched. SessionRow already had appleMusicId (P2-DATA-1).
- Goldens are hand-derived from RemoteWire.swift, not captured from a Swift run (noted in the JSON `_note`). Numbers compare by value: Swift prints 5.0 as `5`, Kotlin as `5.0`; both decode either.
- Kotlin side carries positionMs/seek ms as Long (iOS Int); JSON identical.
- RemoteSessionMode Kotlin enum is LISTEN_TOGETHER/BACKSEAT with wire names listenTogether/backseat.
- MIN_WINDOW_AHEAD lives in RemoteQueueModel companion (iOS keeps it on the controller).
- RemoteEnvelope payload is a base64 String (iOS Data); envelope.encode()/parse() helpers added.

## Questions for Levi
None.
