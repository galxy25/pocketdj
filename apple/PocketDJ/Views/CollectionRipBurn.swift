import SwiftUI
import Observation

/// Shared "Rip collection" + "Burn collection" actions (Feature 2) for the Playlist,
/// Setlist, Pocket, and source-playlist detail screens. One place owns the wiring so the
/// four views stay consistent and their `body` stays within the type-checker's reach.
///
///   • RIP  → `RipsStore.ripCollection` (server-side batch enqueue + S3 upload, reusing
///            the durable queue). Real-time + concurrency-1, so the summary says
///            "enqueued — completes over time" and offers a manifest Refresh.
///   • BURN → `BurnStore.burn` (app-side serial download of ALREADY-ripped songs +
///            sidecars into managed storage). Downloads only what's ripped; reports the
///            rest as "not yet ripped".
///
/// Both handle empty collections (disabled), partial success (counts in the summary),
/// and a no-server state (RIP gated on `hasServer`; BURN still burns cached songs).
///
/// USAGE: the two buttons sit inside a Menu (or a List Section); the result alert is
/// presented by `.collectionRipBurn(_:)` applied to the SCREEN (a Menu dismisses its
/// content before an alert attached there could present, so the alert must live outside).
struct CollectionRipBurnButtons: View {
    @Environment(RipsStore.self) private var rips
    @Environment(BurnStore.self) private var burns
    @Environment(CollectionsStore.self) private var collections
    let controller: CollectionRipBurnController

    /// Resolves the collection to its (deduped) song ids at action time — recomputed
    /// lazily so edits made after the screen appeared are picked up.
    let songIds: () -> [String]
    var noun: String = "collection"

    var body: some View {
        let ids = songIds()
        Button { controller.rip(ids, rips: rips, noun: noun) } label: {
            Label("Rip \(noun)", systemImage: "arrow.down.circle")
        }
        .disabled(ids.isEmpty || controller.working || !rips.hasServer)
        .accessibilityIdentifier("collection-rip")

        Button { controller.burn(ids, rips: rips, burns: burns, collections: collections) } label: {
            Label("Burn \(noun)", systemImage: "flame")
        }
        .disabled(ids.isEmpty || controller.working)
        .accessibilityIdentifier("collection-burn")

        // STOP (Feature 1) — shown only while a rip/burn is in flight. Idempotent + silent:
        // routes to the right cancel path (app-side burn Task vs. server `/rip-cancel`).
        if controller.working {
            Button(role: .destructive) {
                controller.stop(rips: rips, burns: burns)
            } label: {
                Label("Stop \(noun)", systemImage: "stop.circle")
            }
            .accessibilityIdentifier("collection-stop")
        }
    }
}

/// Holds the shared Rip/Burn task state + result summary, so the menu buttons and the
/// screen-level result alert (which must live OUTSIDE the menu to present) share it.
@MainActor
@Observable
final class CollectionRipBurnController {
    var working = false
    var summary: String?
    var showSummary = false
    var canRefresh = false

    /// Which long-running op is in flight (so a single STOP routes to the right cancel path).
    enum Op { case rip, burn }
    private(set) var inFlightOp: Op?
    /// The burn Task, stored so STOP can cancel it (mirrors OnlineSearchModel's stored Task).
    private var burnTask: Task<Void, Never>?
    /// The ids enqueued by the last rip — captured so STOP RIP can target exactly those
    /// (ripCollection is fire-and-forget and doesn't retain them).
    private var lastRipIds: [String] = []

    func rip(_ ids: [String], rips: RipsStore, noun: String) {
        working = true
        inFlightOp = .rip
        lastRipIds = ids
        Task {
            let r = await rips.ripCollection(ids)
            // Real-time, concurrency-1: "queued/inflight" means enqueued, not done. Don't
            // imply instant readiness; offer Refresh to reconcile the manifest later.
            let pending = r.queued + r.inflight
            var parts: [String] = []
            if r.ready > 0 { parts.append("\(r.ready) already ripped") }
            if pending > 0 { parts.append("\(pending) enqueued — completes over time") }
            if r.unknown > 0 { parts.append("\(r.unknown) unrippable") }
            if rips.ripFromCloud && pending > 0 { parts.append("cloud rips capture in real time, one at a time") }
            summary = parts.isEmpty ? "Nothing to rip." : parts.joined(separator: " · ")
            canRefresh = pending > 0 || r.ready > 0
            working = false
            inFlightOp = nil
            showSummary = true
        }
    }

    func burn(_ ids: [String], rips: RipsStore, burns: BurnStore, collections: CollectionsStore) {
        working = true
        inFlightOp = .burn
        burnTask = Task {
            // BURN downloads only already-ripped songs; optionally enqueue the rest so a
            // later Burn pass (after a manifest Refresh) can pick them up.
            let tuples = collections.burnTuples(ids)
            let r = await burns.burn(tuples)
            // Don't auto-enqueue rips when the user STOPped the burn.
            if !r.stopped && r.notRipped > 0 && rips.hasServer {
                let missing = tuples.map { $0.id }.filter { rips.cachedURL($0) == nil }
                if !missing.isEmpty { _ = await rips.ripCollection(missing) }
            }
            var parts: [String]
            if r.folderUnavailable {
                parts = ["Couldn’t write to the burnt-music folder — check Settings"]
            } else {
                parts = ["Burned \(r.burned) of \(r.total)"]
                if r.notRipped > 0 { parts.append("\(r.notRipped) not yet ripped") }
                if r.failed > 0 { parts.append("\(r.failed) failed") }
                if r.outOfSpace { parts.append("out of space — stopped early") }
                if r.stopped { parts.append("stopped") }
                if rips.ripFromCloud && !r.stopped && r.notRipped > 0 && rips.hasServer { parts.append("cloud rips capture in real time, one at a time") }
            }
            summary = parts.joined(separator: " · ")
            canRefresh = !r.stopped && !r.folderUnavailable && r.notRipped > 0
            working = false
            inFlightOp = nil
            showSummary = true
        }
    }

    /// STOP the in-flight op (Feature 1). BURN is app-side: signal the BurnStore loop to
    /// stop after the current item + cancel the Task. RIP needs the server: cancel the
    /// collection's queued/running jobs via `/rip-cancel`. Idempotent + silent (the result
    /// alert already covers the partial state). Clears `working` for the rip path immediately
    /// (the burn path clears it when its Task returns its partial result).
    func stop(rips: RipsStore, burns: BurnStore) {
        switch inFlightOp {
        case .burn:
            burns.requestStop()
            burnTask?.cancel()
        case .rip:
            let ids = lastRipIds
            inFlightOp = nil
            working = false
            Task { await rips.cancelCollection(ids) }
        case .none:
            break
        }
    }
}

extension View {
    /// Present the Rip/Burn result alert + a progress overlay for the BURN serial queue.
    /// Apply to the collection SCREEN (not inside the Menu, which dismisses its content).
    func collectionRipBurn(_ controller: CollectionRipBurnController) -> some View {
        modifier(CollectionRipBurnAlert(controller: controller))
    }
}

private struct CollectionRipBurnAlert: ViewModifier {
    @Environment(BurnStore.self) private var burns
    @Environment(RipsStore.self) private var rips
    @Bindable var controller: CollectionRipBurnController

    func body(content: Content) -> some View {
        content
            .alert("Done", isPresented: $controller.showSummary) {
                if controller.canRefresh {
                    Button("Refresh") { Task { await rips.refreshManifest() } }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.summary ?? "")
            }
            .overlay(alignment: .bottom) {
                if let p = burns.progress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Burning \(p.done + 1)/\(p.total): \(p.label)")
                            .font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("burn-progress")
                }
            }
    }
}
