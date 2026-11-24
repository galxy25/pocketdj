state: in-progress

# P2-REM-9 - Nearby Connections transport + invite + permissions + keep-alive

- [x] NearbyInvite.kt, RemotePermissions.kt, NearbyRemoteTransport.kt (fakeable NearbyClient seam, frames, relay star, host migration)
- [x] NearbyRemoteStarter.kt (GmsNearbyClient, starter, RemoteKeepAliveService), installed by RemoteGraph.wire()
- [x] Manifest, libs.versions.toml, build.gradle.kts, ParityFlags.REMOTE = true, deep link pocketdj://remote/join/<token>, RemoteScreen permission gate
- [ ] tests green, assembleRelease
