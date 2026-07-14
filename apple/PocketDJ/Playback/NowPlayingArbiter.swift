import Foundation

/// Single-owner arbiter for the system Now Playing card (`MPNowPlayingInfoCenter`) and the shared
/// remote-command center, used by BOTH playback subsystems:
///
///  - `PlayerEngine` — the standalone row / set-list AVPlayer (and the background-audio sequencer).
///  - `MixEngine` — the two-deck DJ engine.
///
/// They both write the one global lock-screen card and both register handlers on the one shared
/// `MPRemoteCommandCenter`. Without arbitration they'd stomp each other (last-writer-wins on the
/// card; double-firing remote commands). The rule here is simple and intuitive: **whoever last
/// STARTED audio owns the card + commands.** Each engine `claim()`s on play, and guards its card
/// writes / command handlers with `isActive(self)`, so exactly one engine drives the lock screen at
/// a time and the other yields. Ownership is held weakly; if the owner is gone, anyone may write.
@MainActor
final class NowPlayingArbiter {
    static let shared = NowPlayingArbiter()
    private init() {}

    private weak var owner: AnyObject?

    /// Become the active Now Playing owner (call when this engine STARTS audio).
    func claim(_ who: AnyObject) {
        if owner !== who {   // trace OWNERSHIP CHANGES only (claim is re-asserted on every play)
            NPLog.trace("arbiter claim → \(String(describing: type(of: who))) (was \(owner.map { String(describing: type(of: $0)) } ?? "nil"))")
        }
        owner = who
    }

    /// True if `who` may currently write the card / act on a remote command — i.e. it is the owner,
    /// or no one owns it yet (nothing has played, or the previous owner deallocated).
    func isActive(_ who: AnyObject) -> Bool { owner == nil || owner === who }

    /// Relinquish ownership if `who` holds it (lets the other engine reclaim the card immediately).
    func resign(_ who: AnyObject) {
        if owner === who {
            NPLog.trace("arbiter resign ← \(String(describing: type(of: who)))")
            owner = nil
        }
    }
}
