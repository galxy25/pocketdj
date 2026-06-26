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

        // STEMIFY → server-side Demucs stem separation of every song (ripping/cutting any
        // not-yet-ready ones first). Like RIP it enqueues fast but completes over minutes/
        // hours, so the progress pill + manifest poll track it. Needs a server.
        Button { controller.stemify(ids, rips: rips, noun: noun) } label: {
            Label("Stemify \(noun)", systemImage: "line.3.horizontal")
        }
        .disabled(ids.isEmpty || controller.working || !rips.hasServer)
        .accessibilityIdentifier("collection-stemify")

        // STOP (Feature 1) — shown while a rip/burn is in flight. A burn keeps `working`
        // true for its whole Task; a collection RIP enqueues in ~1-2s but completes
        // server-side over minutes/hours, so we also keep the button while `ripInProgress`
        // (driven by the manifest poll). Idempotent + silent: routes to the right cancel
        // path (app-side burn Task vs. server `/rip-cancel`).
        if controller.working || controller.ripInProgress || controller.stemInProgress {
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

    /// A collection RIP enqueues in ~1-2s (that's all `working` covers) but the actual
    /// capture is server-side, real-time, concurrency-1 — minutes to hours. While the
    /// enqueued songs are still being ripped this stays true so the STOP button + a live
    /// progress indicator remain visible. Driven by the manifest poll below.
    private(set) var ripInProgress = false
    /// Live progress string for the in-flight collection RIP (e.g. "ripping — 3 of 12 done").
    private(set) var ripProgress: String?

    /// Which long-running op is in flight (so a single STOP routes to the right cancel path).
    enum Op { case rip, burn, stem }
    private(set) var inFlightOp: Op?

    /// A collection STEMIFY mirrors RIP: enqueues fast, completes server-side over time. While
    /// the enqueued songs are still being stemmed this stays true so the STOP button + a live
    /// progress indicator remain visible. Driven by a separate manifest poll (so a simultaneous
    /// Rip and Stemify don't fight one poll).
    private(set) var stemInProgress = false
    private(set) var stemProgress: String?
    private var stemPollTask: Task<Void, Never>?
    private var lastStemIds: [String] = []
    /// Over-cap confirmation (the server's `needsConfirm` envelope): the UI shows an
    /// "N songs — long job, proceed?" alert; Proceed re-calls with `confirmLarge`.
    var showStemConfirm = false
    private(set) var stemConfirmCount = 0
    private(set) var stemConfirmCap = 0
    private var pendingStemIds: [String] = []
    private var pendingStemNoun = "collection"
    /// The burn Task, stored so STOP can cancel it (mirrors OnlineSearchModel's stored Task).
    private var burnTask: Task<Void, Never>?
    /// The manifest-poll Task that tracks how many enqueued rips have completed, stored so
    /// STOP / done / teardown can cancel it (so it never leaks or polls forever).
    private var ripPollTask: Task<Void, Never>?
    /// The ids enqueued by the last rip — captured so STOP RIP can target exactly those
    /// (ripCollection is fire-and-forget and doesn't retain them).
    private var lastRipIds: [String] = []

    /// How often the rip poll reconciles the manifest, and a generous safety cap so the
    /// poll never runs forever (a concurrency-1, real-time rip can take a long time, but
    /// a leaked Task is worse than stopping the *indicator* early).
    static var ripPollIntervalMs = 4500
    static var ripPollMaxTicks = 1600   // ~2h at 4.5s/tick

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
            // Keep the rip "in progress" (visible STOP + live progress) until the server
            // finishes the enqueued songs. Only poll when there's something still pending.
            if pending > 0 {
                startRipPoll(lastRipIds, rips: rips)
            }
        }
    }

    /// Poll the public S3 manifest periodically and count how many of `ids` are now ripped
    /// (`rips.cachedURL(id) != nil`). Drives `ripInProgress` + `ripProgress` and the result
    /// summary as songs complete. Stops when pending hits 0 (done), on `stop()`, or after a
    /// generous safety cap — never polls forever, never leaks (the Task is cancellable and
    /// re-checks cancellation each tick).
    private func startRipPoll(_ ids: [String], rips: RipsStore) {
        ripPollTask?.cancel()
        let total = ids.count
        guard total > 0 else { return }
        ripInProgress = true
        updateRipProgress(ids, rips: rips, total: total)

        ripPollTask = Task { [weak self] in
            for _ in 0..<Self.ripPollMaxTicks {
                if Task.isCancelled { return }
                try? await RipsStore.sleep(ms: Self.ripPollIntervalMs)
                if Task.isCancelled { return }
                guard let self else { return }
                await rips.refreshManifest()
                if Task.isCancelled { return }
                let pending = self.updateRipProgress(ids, rips: rips, total: total)
                if pending == 0 {
                    self.finishRipPoll(total: total)
                    return
                }
            }
            // Safety cap reached — stop the indicator (the rips may still finish server-side;
            // a manual Refresh reconciles), don't poll forever.
            self?.clearRipProgress()
        }
    }

    /// Recompute the ripped/pending counts off the current manifest, update the live progress
    /// string + the result summary, and return how many of `ids` are still pending.
    @discardableResult
    private func updateRipProgress(_ ids: [String], rips: RipsStore, total: Int) -> Int {
        let done = ids.reduce(into: 0) { acc, id in if rips.cachedURL(id) != nil { acc += 1 } }
        let pending = max(0, total - done)
        if pending > 0 {
            ripProgress = "ripping — \(done) of \(total) done"
            summary = "Ripping \(done) of \(total) — completes over time"
        } else {
            ripProgress = nil
            summary = "Ripped \(total) of \(total)"
        }
        return pending
    }

    private func finishRipPoll(total: Int) {
        ripPollTask = nil
        ripInProgress = false
        ripProgress = nil
        summary = "Ripped \(total) of \(total)"
        canRefresh = true
    }

    /// Tear down the poll + clear the in-progress indicator without rewriting the summary
    /// (used by STOP and the safety cap).
    private func clearRipProgress() {
        ripPollTask?.cancel()
        ripPollTask = nil
        ripInProgress = false
        ripProgress = nil
    }

    // MARK: Stemify (mirrors the RIP path; completion predicate is `rips.isStemmed`)

    /// Kick a collection Stemify. The server rips/cuts any not-yet-ready songs first, then
    /// separates. Over the server's cap it returns `needsConfirm` → we surface the confirm
    /// alert instead of committing. Otherwise the manifest poll tracks completion.
    func stemify(_ ids: [String], rips: RipsStore, noun: String) {
        runStemify(ids, rips: rips, noun: noun, confirmLarge: false)
    }

    /// Proceed with an over-cap Stemify the user confirmed.
    func confirmStemify(rips: RipsStore) {
        runStemify(pendingStemIds, rips: rips, noun: pendingStemNoun, confirmLarge: true)
        pendingStemIds = []
    }

    private func runStemify(_ ids: [String], rips: RipsStore, noun: String, confirmLarge: Bool) {
        working = true
        inFlightOp = .stem
        lastStemIds = ids
        Task {
            let r = await rips.stemifyCollection(ids, confirmLarge: confirmLarge)
            // Over-cap gate: don't start; ask the user to confirm the long job.
            if r.needsConfirm {
                working = false
                inFlightOp = nil
                pendingStemIds = ids
                pendingStemNoun = noun
                stemConfirmCount = r.count
                stemConfirmCap = r.cap
                showStemConfirm = true
                return
            }
            let pending = r.queued + r.inflight + r.ripping + r.needsCut
            var parts: [String] = []
            if r.ready > 0 { parts.append("\(r.ready) already stemmed") }
            if r.ripping > 0 { parts.append("\(r.ripping) ripping first") }
            if pending - r.ripping > 0 { parts.append("\(pending - r.ripping) stemming — completes over time") }
            if r.ineligible > 0 { parts.append("\(r.ineligible) can’t be stemmed") }
            if r.unknown > 0 { parts.append("\(r.unknown) unknown") }
            summary = parts.isEmpty ? "Nothing to stemify." : parts.joined(separator: " · ")
            canRefresh = pending > 0 || r.ready > 0
            working = false
            inFlightOp = nil
            showSummary = true
            if pending > 0 { startStemPoll(lastStemIds, rips: rips) }
        }
    }

    /// Poll the manifest and count how many of `ids` are now stemmed (`rips.isStemmed`).
    /// Drives `stemInProgress` + `stemProgress`. Stem runs are minutes/song, so the cap is
    /// generous; never polls forever, never leaks (cancellable, re-checks each tick).
    private func startStemPoll(_ ids: [String], rips: RipsStore) {
        stemPollTask?.cancel()
        let total = ids.count
        guard total > 0 else { return }
        stemInProgress = true
        updateStemProgress(ids, rips: rips, total: total)

        stemPollTask = Task { [weak self] in
            for _ in 0..<Self.stemPollMaxTicks {
                if Task.isCancelled { return }
                try? await RipsStore.sleep(ms: Self.stemPollIntervalMs)
                if Task.isCancelled { return }
                guard let self else { return }
                await rips.refreshManifest()
                if Task.isCancelled { return }
                let pending = self.updateStemProgress(ids, rips: rips, total: total)
                if pending == 0 { self.finishStemPoll(total: total); return }
            }
            self?.clearStemProgress()
        }
    }

    @discardableResult
    private func updateStemProgress(_ ids: [String], rips: RipsStore, total: Int) -> Int {
        let done = ids.reduce(into: 0) { acc, id in if rips.isStemmed(id) { acc += 1 } }
        let pending = max(0, total - done)
        if pending > 0 {
            stemProgress = "stemming — \(done) of \(total) done"
            summary = "Stemming \(done) of \(total) — completes over time"
        } else {
            stemProgress = nil
            summary = "Stemmed \(total) of \(total)"
        }
        return pending
    }

    private func finishStemPoll(total: Int) {
        stemPollTask = nil
        stemInProgress = false
        stemProgress = nil
        summary = "Stemmed \(total) of \(total)"
        canRefresh = true
    }

    private func clearStemProgress() {
        stemPollTask?.cancel()
        stemPollTask = nil
        stemInProgress = false
        stemProgress = nil
    }

    /// Poll cadence for the stem reconcile (a Demucs run is minutes/song; the cap is generous).
    static var stemPollIntervalMs = 5000
    static var stemPollMaxTicks = 2880   // ~4h at 5s/tick

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

    /// STOP a burn from the progress PILL. Unlike `stop(rips:burns:)` (which routes on
    /// `inFlightOp`), this works in BOTH burn shapes: the macOS in-process loop (the burn Task is
    /// still running, `inFlightOp == .burn`) AND the iOS background path (the Task already returned
    /// after enqueue, `inFlightOp == nil`, downloads still in flight). Signal the BurnStore (halts
    /// the in-process loop at the next item + cancels in-flight background download tasks) and
    /// cancel the stored Task. We deliberately DON'T clear `working`/`inFlightOp` here: the
    /// in-process burn Task clears them itself when it returns its partial result (so the Burn
    /// button isn't re-enabled while the loop is still finishing the current item); on the
    /// background path they're already clear. Idempotent.
    func stopBurn(burns: BurnStore) {
        burns.requestStop()
        burnTask?.cancel()
    }

    /// STOP the in-flight op (Feature 1). BURN is app-side: signal the BurnStore loop to
    /// stop after the current item + cancel the Task. RIP needs the server: cancel the
    /// collection's queued/running jobs via `/rip-cancel`, and stop the manifest poll +
    /// clear the in-progress indicator. Idempotent + silent (the result alert already covers
    /// the partial state). Clears `working`/`ripInProgress` immediately (the burn path clears
    /// `working` when its Task returns its partial result).
    ///
    /// A collection RIP only holds `inFlightOp == .rip` during the ~1-2s enqueue; once it's
    /// enqueued the poll drives `ripInProgress` with `inFlightOp == nil`. So STOP routes on
    /// `inFlightOp` for the burn, but ALSO cancels a running rip whenever `ripInProgress` is
    /// set (the common case the user actually sees).
    func stop(rips: RipsStore, burns: BurnStore) {
        if inFlightOp == .burn {
            burns.requestStop()
            burnTask?.cancel()
            return
        }
        // Stemify (still enqueuing, or enqueued + polling). /stemify-cancel tears down BOTH the
        // chained rips and the queued stems server-side, so the client calls only cancelStemCollection.
        if inFlightOp == .stem || stemInProgress {
            let ids = lastStemIds
            inFlightOp = nil
            working = false
            clearStemProgress()
            lastStemIds = []
            if !ids.isEmpty { Task { await rips.cancelStemCollection(ids) } }
            return
        }
        // Rip (either still enqueuing, or enqueued + polling). Cancel server-side jobs,
        // stop the poll, and clear the in-progress UI. Idempotent: a second STOP after the
        // ids are cleared cancels nothing and is a harmless no-op.
        if inFlightOp == .rip || ripInProgress {
            let ids = lastRipIds
            inFlightOp = nil
            working = false
            clearRipProgress()
            lastRipIds = []
            if !ids.isEmpty { Task { await rips.cancelCollection(ids) } }
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

    /// ONE unified burn-progress string ("Burning X of N") regardless of path — the user just
    /// wants "how many songs are left", not whether we're downloading albums or making cuts.
    ///   • IN-PROCESS path (macOS / tests): driven by `burns.progress` (a single counter; the cut
    ///     export runs inline, so there's no separate "making cuts" phase).
    ///   • BACKGROUND path (iOS): driven by the `@Observable` mirror of the coordinator's run-scoped
    ///     counters (updated on the main actor as each download finishes — NOT the coordinator's
    ///     `progressSnapshot`, a plain NSObject SwiftUI can't track).
    private var burnProgressText: String? {
        if let p = burns.progress, p.total > 0 {
            return "Burning \(min(p.done + 1, p.total)) of \(p.total)"
        }
        if burns.transfers != nil {
            let (total, done) = burns.backgroundProgress
            if total > 0, done < total { return "Burning \(done + 1) of \(total)" }
        }
        return nil
    }

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
                if let text = burnProgressText {
                    // Single progress pill with an inline STOP (the burn equivalent of the rip
                    // pill's Stop). STOP works whether the burn Task is still running (macOS
                    // in-process) or already returned after enqueue (iOS background downloads
                    // still in flight) — see `stopBurn`.
                    pill(text, stopId: "collection-burn-stop") { controller.stopBurn(burns: burns) }
                        .accessibilityIdentifier("burn-progress")
                } else if controller.stemInProgress {
                    // The collection STEMIFY enqueues fast but completes server-side over time —
                    // keep a live "stemming X of N" indicator + a reachable STOP outside the Menu.
                    pill(controller.stemProgress ?? "stemming…", stopId: "collection-stem-stop") {
                        controller.stop(rips: rips, burns: burns)
                    }
                    .accessibilityIdentifier("stem-progress")
                } else if controller.ripInProgress {
                    // The collection RIP enqueues fast but completes server-side over time —
                    // keep a live "ripping X of N" indicator + a reachable STOP OUTSIDE the
                    // Menu (a Menu dismisses on selection, so the persistent STOP/progress
                    // lives here, mirroring the burn-progress overlay above).
                    pill(controller.ripProgress ?? "ripping…", stopId: "collection-rip-stop") {
                        controller.stop(rips: rips, burns: burns)
                    }
                    .accessibilityIdentifier("rip-progress")
                }
            }
            // Over-cap Stemify confirmation (the server's needsConfirm gate).
            .alert("Stemify \(controller.stemConfirmCount) songs?", isPresented: $controller.showStemConfirm) {
                Button("Stemify", role: .destructive) { controller.confirmStemify(rips: rips) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("That's more than the \(controller.stemConfirmCap)-song limit — separating stems is a long job (minutes per song). Proceed?")
            }
    }

    /// A bottom progress capsule: spinner + text + an inline destructive Stop button.
    private func pill(_ text: String, stopId: String, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(Theme.fg).lineLimit(1)
            Button(role: .destructive, action: stop) {
                Label("Stop", systemImage: "stop.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(stopId)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}
