state: implemented

# P2-REM-2: RemoteTransport + RemoteSendQueue + LoopbackHub
- [x] RemoteTransport.kt (interface, RemoteRecipient, RemoteInbound)
- [x] RemoteSendQueue.kt (two lanes, one worker each, retries 250ms/1s, coalescing, caps 256/32, peer buffer 32x16)
- [x] LoopbackHub.kt (+ LoopbackTransport; latency/drop injection)
- [x] Tests: RemoteSendQueueTest (13), LoopbackHubTest (9) = 22 new, all green

## Notes / deviations
- `participants` is a StateFlow, so "finish" is expressed as an empty set; `inbound` completes on leave/end.
- RemoteSendQueue takes a CoroutineScope (Main in the app, TestScope in tests) and a `log` lambda instead of DiagLog.
- LoopbackHub latency needs a scope; latency is in seconds as on iOS.
- No files outside the owned set touched. Manifest/gradle untouched, so assembleRelease not required.

## Questions for Levi
None.
