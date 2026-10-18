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

    private(set) weak var owner: AnyObject?
    /// The engine a restore says should answer the NEXT remote command while nobody owns the card
    /// (a held set-list after relaunch). Without it a nil owner meant "everyone", so one steering-
    /// wheel ▶ fanned out to BOTH engines and a parked Mix woke up as a silent, end-of-file owner.
    private(set) weak var preferred: AnyObject?
    /// Fired when ownership actually changes hands (new owner, previous owner). The displaced
    /// engine uses it to drop resume latches that would otherwise steal the card back later.
    var onOwnerChanged: [(_ new: AnyObject, _ old: AnyObject?) -> Void] = []

    static func name(_ who: AnyObject?) -> String { who.map { String(describing: type(of: $0)) } ?? "nil" }

    /// Become the active Now Playing owner (call when this engine STARTS audio).
    func claim(_ who: AnyObject, reason: String = "") {
        let old = owner
        owner = who
        if old !== who {   // trace OWNERSHIP CHANGES only (claim is re-asserted on every play)
            NPLog.trace("arbiter claim → \(Self.name(who)) (was \(Self.name(old)))\(reason.isEmpty ? "" : " reason=\(reason)")")
            if preferred != nil, preferred !== who { preferred = nil }
            for cb in onOwnerChanged { cb(who, old) }
        }
    }

    /// Name the engine that should answer remote commands while nobody owns the card (nil clears).
    func prefer(_ who: AnyObject?) {
        if preferred !== who { NPLog.trace("arbiter prefer → \(Self.name(who))") }
        preferred = who
    }

    /// True if `who` may currently write the card / act on a remote command — i.e. it is the owner,
    /// or no one owns it and either no engine is preferred or `who` is the preferred one.
    func isActive(_ who: AnyObject) -> Bool {
        if let owner { return owner === who }
        return preferred == nil || preferred === who
    }

    /// Relinquish ownership if `who` holds it (lets the other engine reclaim the card immediately).
    func resign(_ who: AnyObject) {
        if owner === who {
            NPLog.trace("arbiter resign ← \(Self.name(who))")
            owner = nil
        }
    }

#if DEBUG
    func resetForTesting() { owner = nil; preferred = nil }
#endif
}
