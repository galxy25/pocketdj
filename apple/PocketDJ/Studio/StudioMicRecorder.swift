import Foundation
import Observation
import AVFoundation
import os

// MARK: - Mic level meter (TimelineView-polled, non-observable)

/// The record UI's input level readout — written on the realtime tap thread every buffer
/// (~10 Hz at 4096 frames), polled by a `TimelineView` at ~10 Hz. Deliberately NOT `@Observable`
/// (the `PlayerClock` doctrine: fast meter writes must never invalidate SwiftUI — observation-
/// driven invalidation from position ticks was the proven dead-play-button bug) and plain
/// aligned stores like `MixTapPulse`: a torn read skews one meter frame, which is invisible.
final class StudioMicLevels: @unchecked Sendable {
    /// Peak absolute sample of the last tap buffer, linear 0…1.
    var peak: Float = 0
    /// Root-mean-square of the last tap buffer, linear 0…1 (the "loudness" bar).
    var rms: Float = 0
    /// `Date().timeIntervalSinceReferenceDate` of the last update (0 = never) — lets the meter
    /// decay to silence when the tap stops firing (engine parked by an interruption).
    var updatedAt: Double = 0
}

// MARK: - Studio microphone recorder (spec §4)

/// Records SAMPLES from the microphone — the `.mic` leg of spec §10 — on its OWN small
/// `AVAudioEngine` (input tap only, no playback nodes), writing crash-safe fragmented AAC
/// through the same `MixTapSink` recipe the mix recorder ships (deep-copy off the realtime
/// thread → private queue → `AVAssetWriter` with 2 s fragments, failure latched per take,
/// content clock from appended media). Reusing the sink CLASS, not a copy, is deliberate:
/// its discipline closes uncatchable-crash bugs (never retry `startWriting`; monotonic PTS
/// from appended frames) and a second implementation would drift.
///
/// Lifecycle mirrors `MixRecorder`: app-scoped `@MainActor @Observable`, `activeTake` guard for
/// storage sweeps, launch-time `recoverOrphans()`, a capture-stall watchdog, writer-death
/// auto-stop-and-file, and a synchronous-enough `finalizeForExit()` for the
/// `RecordingExitBridge` quit path. Mic recordings ARE samples (spec §4): files are minted as
/// `sample-<smp_id>.m4a` in the SAMPLES family root (user-relocatable) and, on a clean stop,
/// the tuple this returns is filed as a `StudioSample` BY THE VIEW (which owns naming/grid UX);
/// only the unattended paths (writer death, quit, sheet dismissal mid-take) file directly.
///
/// Route-change hardening (the MixEngine contract, input-side edition):
///   • the session is configured `.playAndRecord` AND activated BEFORE `inputNode`'s format is
///     read or the tap installed — a 0 Hz input format makes `installTap` raise uncatchably;
///   • the tap runs at the HARDWARE input format (mono/48 kHz is fine — the writer takes the
///     rate/channels as given) and is REINSTALLED at the fresh hardware format on every engine
///     recovery: a route change flips the input rate (AirPods ⇄ built-in) and a tap left at the
///     old rate asserts uncatchably when the engine restarts;
///   • intent (`isMonitoring`/`isRecording`) is separate from engine state; a ~10 Hz tick
///     watchdog (0.5 s dt clamp) retries recovery ~1/s; interruption `.began` is LATCHED (it can
///     arrive twice) and `.ended` is treated as a hint only (not guaranteed — the watchdog is
///     the backstop); `mediaServicesWereReset` files the in-flight take FIRST, then recreates
///     the engine and re-registers the per-INSTANCE `.AVAudioEngineConfigurationChange` observer;
///   • there are NO player nodes here, so the zombie-node re-prime / `healParkedPlayers` legs of
///     the contract have no subject — and a STOPPED input engine appends NOTHING (the tap simply
///     stops firing), so unlike MixEngine there is no "restarting appends silence into an open
///     take" hazard: the watchdog may always retry, even while interruption-parked (a failed
///     `setActive` during a live phone call is a harmless soft-fail, retried next second).
///
/// Session coexistence (spec §4): `AudioSessionPolicy.beginMicCapture()` is set for the whole
/// monitoring window — every playback engine's `setCategory(.playback)` site is guarded on it,
/// because playback engines re-arm `.playback` on EVERY load and would tear down the live input
/// tap. `endMonitoring()`/`stop()` clear the flag and restore `.playback` themselves.
@MainActor
@Observable
final class StudioMicRecorder {

    // MARK: Published state (the record sheet renders off these)

    /// True while the mic session is live (level meter running) — spans `beginMonitoring()` →
    /// `endMonitoring()`; recording is a sub-window of it. While true the shared session is
    /// `.playAndRecord` and `AudioSessionPolicy.micCaptureActive` is set.
    private(set) var isMonitoring = false
    /// How many mic-record SHEETS are currently on screen (multi-window). The sheet retains on
    /// appear and releases on disappear; the shared single-session recorder is torn down only when
    /// the LAST sheet leaves (see `releasePresenter()`), so a second window closing its sheet can't
    /// kill a capture the first window still shows. Not observed — it drives no UI.
    @ObservationIgnored private var presenterCount = 0
    /// True while a take is being written (drives the pulsing record button).
    private(set) var isRecording = false
    /// Mic permission was explicitly denied — the sheet shows the Settings hand-off instead of a
    /// dead record button (the Shazam `.denied`-state pattern, never a thrown error).
    private(set) var permissionDenied = false
    /// Epoch ms when the current take began (the view derives the elapsed clock from this —
    /// never a ticking published property).
    private(set) var startedAtMs: Double = 0
    /// True while capturing but no MEDIA has been appended for ≥5 s — the engine is down and the
    /// watchdog is still trying; the record UI warns instead of pulsing over a dead take.
    /// Deliberately warn-only (the MixRecorder doctrine): definitive writer death auto-stops via
    /// the failure latch; anything else may recover mid-take.
    private(set) var captureStalled = false
    /// Set when a take was auto-stopped because its writer died (disk full / samples folder
    /// vanished) or media services reset. The sheet surfaces it once as an alert and clears it.
    var writerFailureMessage: String?

    /// One selectable capture INPUT (iOS): the built-in mic OR an external audio input — a USB-C
    /// interface / line / the TX-6 mixer (`isLineIn`). The record sheet lists these so a user can
    /// SAMPLE FROM AUDIO IN, not just the mic. `id` is the port UID (`setPreferredInput` key).
    struct InputOption: Identifiable, Hashable, Sendable {
        let id: String          // AVAudioSessionPortDescription.uid
        let name: String        // portName ("iPhone Microphone", "TX-6", …)
        let isLineIn: Bool      // NOT the built-in mic ⇒ an external audio input
    }
    /// Available capture inputs, refreshed after the session goes live + on every route change
    /// (plug/unplug the interface). Empty on macOS (no AVAudioSession — it uses the system default).
    private(set) var availableInputs: [InputOption] = []
    /// The chosen input's UID; the picker reads it. nil ⇒ the current route's default input.
    private(set) var selectedInputUID: String?
    /// The provenance stamped on a recorded sample — `.mic` for the built-in mic, `.lineIn` for an
    /// external audio input (with its port name). Derived from the selected input.
    private(set) var captureSource: StudioSource = .mic

    // MARK: Wiring (pushed from the view layer — the MixRecorder.settings pattern)

    /// Files auto-stopped takes + answers the orphan scan. Weak ⇒ no retain of the app graph;
    /// pushed in by the Studio view (no app-init wiring needed). When nil (tests / unwired), the
    /// unattended paths leave the file on disk for the next launch's orphan recovery.
    @ObservationIgnored weak var store: StudioStore?
    /// Source of the samples-family folder bookmark (mic recordings are samples — spec §4).
    @ObservationIgnored weak var settings: SettingsStore?

    /// The input level meter — non-observable on purpose (see `StudioMicLevels`); the record UI
    /// polls it from a `TimelineView`.
    @ObservationIgnored let levels = StudioMicLevels()

    // MARK: Internals (@ObservationIgnored: none of this should ever invalidate SwiftUI)

    /// Recreated wholesale on `mediaServicesWereReset` (an orphaned graph is unusable — the
    /// MixEngine rebuild doctrine), hence `var`.
    @ObservationIgnored private var engine = AVAudioEngine()
    /// Observers registered / engine considered usable. Reset by the media-services rebuild so
    /// the next `beginMonitoring()` re-registers the per-instance config observer.
    @ObservationIgnored private var built = false
    /// Whether a tap is currently installed on `inputNode` bus 0 (so recovery can remove-then-
    /// reinstall at the fresh hardware format without double-install crashes).
    @ObservationIgnored private var tapInstalled = false
    /// The hardware format the tap was installed at — what the writer is told, and what the
    /// heartbeat reports.
    @ObservationIgnored private var tapSampleRate: Double = 0
    @ObservationIgnored private var tapChannels: AVAudioChannelCount = 0
    /// The crash-safe fragmented-AAC writer (MixEngine's reviewed realtime recipe — see the
    /// class doc for why it's reused, not copied).
    @ObservationIgnored private let sink = MixTapSink()
    /// The samples folder's security-scope release, OWNED for the whole capture and dropped only
    /// AFTER the async finalize completes — releasing a provider folder's scope mid-
    /// `finishWriting` fails the fragmented file's tail write (the stopRecording lesson).
    @ObservationIgnored private var scopeRelease: (() -> Void)?

    // The in-flight take, captured at start so unattended filing (writer death / quit) still has
    // the truth even after published state is cleared.
    @ObservationIgnored private var recId = ""
    @ObservationIgnored private var recFileName = ""
    @ObservationIgnored private var recWasUserFolder = false

    // iOS session observers (registered once; the config observer is per-ENGINE-INSTANCE and
    // re-registered after a media-services rebuild).
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaResetObserver: NSObjectProtocol?
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?
    /// Interruption `.began` latch (NEVER assigned false by another `.began` — Bluetooth/CarPlay
    /// deliver duplicates). Diagnostic + `.ended` pairing only: the tick watchdog retries
    /// recovery regardless (see the class doc for why that's safe on a pure input graph).
    @ObservationIgnored private var interruptionParked = false

    // Tick watchdog state (~10 Hz; all math via the pure statics below so it's testable).
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastTickAt: Double?
    @ObservationIgnored private var stallAccum: Double = 0
    @ObservationIgnored private var lastAppended: Double = -1
    @ObservationIgnored private var lastRecoveryAt: Double = 0
    @ObservationIgnored private var lastHeartbeatAt: Double = 0

    // Per-root orphan-scan latches (the MixRecorder doctrine): each root scans once per launch,
    // but a root that FAILS TO RESOLVE (user folder offline / settings not wired yet) is retried
    // on the next call instead of being latched off for the whole launch.
    @ObservationIgnored private var scannedAppRoot = false
    @ObservationIgnored private var scannedUserRoot = false

    // MARK: Diagnostics (same mixdiag firehose as MixEngine, so Settings ▸ Debug capture covers
    // the mic engine for free; lines are "mic:"-prefixed to stay attributable)

    private static let diag = Logger(subsystem: "com.levi.pocketdj", category: "mixdiag")
    private func dlog(_ s: String) {
        Self.diag.info("\(s, privacy: .public)")
        MixDiag.shared.append(s)     // no-op unless a Settings ▸ Debug capture session is running
    }

    // MARK: Init

    init() {
        // Writer death mid-take (disk full / samples folder vanished) surfaces on the sink
        // queue → hop to the main actor and auto-stop + FILE the partial take (its fragments up
        // to the failure are durable). Without this the sink drops every later buffer while the
        // UI keeps pulsing "recording" — the unbounded silent-loss hole. One-shot per take.
        sink.onWriterFailure = { [weak self] _ in
            Task { @MainActor in self?.writerDidFail() }
        }
    }

    // MARK: Active-take guard (storage sweeps / orphan scan)

    /// The in-flight take's file while recording — `StudioStore.deleteAll(family: .samples)`
    /// skips this open file (sweeping it mid-write corrupts the capture), and the orphan scan
    /// must not adopt it (adopting would file a DUPLICATE record on stop). Root-aware because
    /// the same file name could exist in both roots.
    var activeTake: (fileName: String, wasUserFolder: Bool)? {
        isRecording ? (recFileName, recWasUserFolder) : nil
    }

    /// What `StudioStore.activeTakeFileName` is wired to (the store's closure takes a bare
    /// `String?`; the sweep skips by name in both roots).
    var activeTakeFileName: String? { activeTake?.fileName }

    // MARK: Monitoring (session + engine + tap; the level meter runs, nothing is written)

    /// Bring the mic up WITHOUT recording — the record sheet's "permission → level meter"
    /// phase (spec §10). Async because the first run shows the system permission prompt.
    /// Returns false (with `permissionDenied` published when that's why) if the mic can't run.
    @discardableResult
    func beginMonitoring() async -> Bool {
        if isMonitoring { return true }
        guard await Self.ensureMicPermission() else {
            permissionDenied = true
            dlog("mic: permission DENIED")
            return false
        }
        permissionDenied = false
        guard configureCaptureSession() else { return false }
        ensureEngine()
        // Session is configured AND active — only NOW is inputNode's format trustworthy.
        guard installTapAtHardwareFormat() else {
            restorePlaybackSession()
            return false
        }
        engine.prepare()
        do { try engine.start() } catch {
            // Soft-fail (headless CI / no input device): degrade to a dead meter, never a crash.
            dlog("mic: engine start FAILED \(error.localizedDescription)")
            removeTap()
            restorePlaybackSession()
            return false
        }
        isMonitoring = true
        interruptionParked = false
        refreshInputs()          // session is live ⇒ availableInputs is now trustworthy
        startTick()
        dlog("mic: MONITOR start hw=\(Int(tapSampleRate))Hz ch=\(tapChannels)")
        return true
    }

    // MARK: Input selection (sample from AUDIO IN — USB-C / line / interface)

    /// Re-read the session's available inputs into `availableInputs` + resolve the current
    /// selection's provenance. Called at monitor start + on every route change. No-op on macOS.
    func refreshInputs() {
        #if os(iOS)
        let ports = AVAudioSession.sharedInstance().availableInputs ?? []
        availableInputs = ports.map {
            InputOption(id: $0.uid, name: $0.portName, isLineIn: $0.portType != .builtInMic)
        }
        // Keep/repair the selection: honor an explicit pick if still present, else follow the
        // route's actual input (so plugging the interface auto-selects it when nothing was chosen).
        let routeUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        if selectedInputUID == nil || !availableInputs.contains(where: { $0.id == selectedInputUID }) {
            selectedInputUID = routeUID ?? availableInputs.first?.id
        }
        if let sel = availableInputs.first(where: { $0.id == selectedInputUID }) {
            captureSource = sel.isLineIn ? .lineIn(inputName: sel.name) : .mic
        } else {
            captureSource = .mic
        }
        dlog("mic: inputs [\(ports.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ", "))]")
        #endif
    }

    /// Route capture to the input with `uid` (`setPreferredInput`) and re-tap at its hardware
    /// format, so a live meter/recording switches source immediately. Stamps the sample provenance.
    func selectInput(uid: String) {
        selectedInputUID = uid
        #if os(iOS)
        guard let port = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.uid == uid }) else { return }
        captureSource = port.portType != .builtInMic ? .lineIn(inputName: port.portName) : .mic
        try? AVAudioSession.sharedInstance().setPreferredInput(port)
        // A preferred-input change flips the input format; re-install the tap at the new format so
        // the engine doesn't assert on the stale rate (same discipline as a route change).
        if isMonitoring {
            removeTap()
            if installTapAtHardwareFormat() {
                if !engine.isRunning { try? engine.start() }
            }
        }
        dlog("mic: input → \(port.portName) (\(port.portType.rawValue))")
        #endif
    }

    /// Tear the mic session down (sheet dismissed / capture finished): stop the engine, restore
    /// `.playback`, clear the coexistence flag. A dismissal MID-TAKE files the take first with a
    /// default name (never silently lose recorded audio); the normal path is `stop()`, where the
    /// view files it with the user's name.
    func endMonitoring() {
        if isRecording, let take = finishTake() { fileSample(take) }
        guard isMonitoring else { return }
        stopTick()
        removeTap()
        if engine.isRunning { engine.stop() }
        isMonitoring = false
        interruptionParked = false
        levels.peak = 0; levels.rms = 0     // freeze the meter at silence, not the last buffer
        restorePlaybackSession()
        dlog("mic: MONITOR end")
    }

    // MARK: Multi-window presenter tracking

    /// A mic-record sheet appeared. Balances `releasePresenter()`; see `presenterCount`.
    func retainPresenter() { presenterCount += 1 }

    /// A mic-record sheet went away. Tears the shared session down ONLY when no other window still
    /// shows a mic-record sheet — a second window closing its sheet must not silence/steal a capture
    /// the first window is still driving. The LAST release runs the full `endMonitoring()`, which
    /// files any in-flight take with a default name (audio is never silently lost — the exact
    /// single-window dismissal contract). `endMonitoring()` stays the unconditional teardown used by
    /// stop()/finalizeForExit()/writerDidFail(); those are NOT presenter-gated.
    func releasePresenter() {
        presenterCount = max(0, presenterCount - 1)
        guard presenterCount == 0 else { return }
        endMonitoring()
    }

    // MARK: Record / stop

    /// Begin a take. Bootstraps monitoring if the sheet hasn't already; mints a collision-free
    /// `sample-<smp_id>.m4a` in the ACTIVE samples root (user folder when set + reachable, else
    /// app storage — `wasUserFolder` is stamped from where it actually landed) and starts the
    /// fragmented writer. Returns false if already recording or nothing could be opened.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording else { return false }
        guard await beginMonitoring() else { return false }
        guard let folder = StudioFolders.folder(.samples, bookmark: settings?.samplesFolderBookmark) else {
            dlog("mic: REC start failed — no writable samples root")
            return false
        }
        // Collision-free minting: uuid ids never collide in practice, but a fixture/import could
        // occupy a name — never open a writer over an existing file (AVAssetWriter would refuse
        // and MixTapSink.begin removes-first, which would DESTROY the incumbent).
        let minted = Self.mintSampleFile(isTaken: { name in
            FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(name).path)
        })
        let url = folder.url.appendingPathComponent(minted.fileName)
        guard sink.begin(url: url, sampleRate: tapSampleRate, channels: tapChannels) else {
            folder.release?()
            dlog("mic: REC start failed — writer refused \(minted.fileName)")
            return false
        }
        scopeRelease = folder.release        // OWNED for the whole capture (see the property doc)
        recId = minted.id
        recFileName = minted.fileName
        recWasUserFolder = folder.isUserFolder
        startedAtMs = Date().timeIntervalSince1970 * 1000
        isRecording = true
        captureStalled = false
        stallAccum = 0
        lastAppended = -1
        dlog("mic: REC start file=\(minted.fileName) user=\(folder.isUserFolder ? 1 : 0)")
        return true
    }

    /// Stop the take and hand its identity back so the VIEW files the `StudioSample` (the view
    /// owns naming + the tap-tempo/BPM affordance; spec §10). `durationMs` is the sink's CONTENT
    /// clock — media actually appended — because wall clock overstates a take after any stall or
    /// route change (wall clock remains the degenerate no-media fallback). Also ends monitoring:
    /// the session goes back to `.playback` and the coexistence flag clears (re-open the sheet's
    /// meter with `beginMonitoring()` for another take). nil when nothing was recording.
    @discardableResult
    func stop() -> (id: String, fileName: String, durationMs: Int, wasUserFolder: Bool)? {
        guard let take = finishTake() else { return nil }
        endMonitoring()
        return take
    }

    /// Like `stop()`, but SUSPENDS until the writer's `finishWriting` has completed — for a caller
    /// that immediately READS (and may delete) the take file. Reading a fragmented-AAC take before
    /// finalize truncates the last <2 s or fails to open (the stopRecording lesson at the top of this
    /// file); `stop()` returns synchronously without waiting, so it's unsafe for a read-then-delete
    /// caller. nil when nothing was recording.
    @discardableResult
    func stopAwaitingFinalize() async -> (id: String, fileName: String, durationMs: Int, wasUserFolder: Bool)? {
        guard isRecording else { return nil }
        let contentMs = Int(sink.appendedSeconds * 1000)
        let wallMs = max(0, Int(Date().timeIntervalSince1970 * 1000 - startedAtMs))
        let durationMs = contentMs > 0 ? contentMs : wallMs
        let release = scopeRelease
        scopeRelease = nil
        isRecording = false
        captureStalled = false
        stallAccum = 0
        lastAppended = -1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sink.end {
                if let release { DispatchQueue.main.async { release() } }
                cont.resume()
            }
        }
        endMonitoring()
        return (recId, recFileName, durationMs, recWasUserFolder)
    }

    /// Orderly-exit finalize (the `RecordingExitBridge` contract): file an in-flight take with a
    /// default name and `flush()` the store SYNCHRONOUSLY — the store's normal save is an async
    /// actor write that loses the race with `.terminateNow`/`exit()`. The sink's finalize itself
    /// stays async, exactly like `MixRecorder.stop()` on quit: the 2 s fragments are already
    /// durable, so a process death before `finishWriting` completes still leaves a playable file.
    func finalizeForExit() {
        let hadTake = isRecording
        endMonitoring()                       // files the take (default name) + restores session
        if hadTake { store?.flush() }
    }

    /// End the writer + drop scope + clear take state, returning the take's identity. Shared by
    /// every stop path; does NOT touch monitoring. nil when not recording.
    private func finishTake() -> (id: String, fileName: String, durationMs: Int, wasUserFolder: Bool)? {
        guard isRecording else { return nil }
        let contentMs = Int(sink.appendedSeconds * 1000)
        let wallMs = max(0, Int(Date().timeIntervalSince1970 * 1000 - startedAtMs))
        let durationMs = contentMs > 0 ? contentMs : wallMs
        dlog("mic: REC stop appended=\(String(format: "%.1f", sink.appendedSeconds))s")
        let release = scopeRelease
        scopeRelease = nil
        isRecording = false
        captureStalled = false
        stallAccum = 0
        lastAppended = -1
        sink.end {
            // Scope dropped only AFTER finalize completes (see `scopeRelease`); hop off the
            // sink queue — release closures are main-actor artifacts.
            if let release { DispatchQueue.main.async { release() } }
        }
        return (recId, recFileName, durationMs, recWasUserFolder)
    }

    /// File a take as a `StudioSample` on the UNATTENDED paths (writer death, quit, dismissal
    /// mid-take) — no grid, `.mic` source, default name; the user renames later. When the store
    /// isn't wired (tests), the file simply waits for the next launch's orphan recovery.
    private func fileSample(_ take: (id: String, fileName: String, durationMs: Int, wasUserFolder: Bool)) {
        guard let store else { return }
        // Provenance follows the SELECTED input (mic vs an external audio-in); the default name too.
        store.addSample(StudioSample(id: take.id, name: defaultRecordingName, fileName: take.fileName,
                                     wasUserFolder: take.wasUserFolder, createdAt: startedAtMs,
                                     durationMs: take.durationMs, source: captureSource))
    }

    /// The default name for a recording, reflecting its input ("Mic recording" / "<input> recording").
    var defaultRecordingName: String {
        if case .lineIn(let name) = captureSource { return (name ?? "Line in") + " recording" }
        return "Mic recording"
    }

    /// The take's writer died permanently (latched by the sink — `startWriting` is never
    /// retried). Stop, file what was captured (fragments to the failure point are durable), and
    /// tell the UI why.
    private func writerDidFail() {
        guard isRecording else { return }
        writerFailureMessage = "Recording stopped: the take couldn't keep writing (low disk "
            + "space or the samples folder became unavailable). The audio captured so far was saved."
        if let take = finishTake() { fileSample(take) }
        endMonitoring()
    }

    // MARK: Orphan recovery (launch / Studio-tab entry / pre-sweep)

    /// File any RAW `sample-<smp_id>.m4a` on disk that the document doesn't know — a take
    /// interrupted by a crash (metadata is filed only on a clean stop, but the fragmented file
    /// survives). Idempotent (known ids skip; upsert by id can't duplicate). Gates:
    ///   • STRICT shape only, and never a render cache (`-r<rev>` stamp) — derived data must not
    ///     resurrect as a phantom take;
    ///   • never the take being captured RIGHT NOW (root-aware — a same-named file in the OTHER
    ///     root is a genuine orphan);
    ///   • `AVAudioFile`-readability gated: a take that died before its first ~2 s fragment is
    ///     unreadable by every AVFoundation consumer — filing it would create a dead 0:00 row
    ///     (it stays on disk unfiled; the family sweep cleans such strays).
    func recoverOrphans() {
        guard let store else { return }
        let fm = FileManager.default
        var roots: [(url: URL, isUser: Bool, release: (() -> Void)?)] = []
        if !scannedAppRoot, let app = try? StudioFolders.appRoot(.samples) {
            scannedAppRoot = true
            roots.append((app, false, nil))
        }
        if !scannedUserRoot, let bm = settings?.samplesFolderBookmark,
           let user = StudioFolders.resolveRoot(family: .samples, bookmark: bm, requireWritable: false),
           user.isUserFolder {
            scannedUserRoot = true
            roots.append((user.url, true,
                          user.scoped ? { user.url.stopAccessingSecurityScopedResource() } : nil))
        }
        // Known ids + ids adopted THIS pass: the same id in both roots (a user-copied file) must
        // resolve once, not upsert-flip between roots (app root wins — it was scanned first).
        var known = Set(store.samples.map(\.id))
        for root in roots {
            defer { root.release?() }
            let names = (try? fm.contentsOfDirectory(atPath: root.url.path)) ?? []
            for name in names {
                guard let id = Self.adoptableSampleId(fileName: name, knownIds: known,
                                                      activeTake: activeTake,
                                                      rootIsUser: root.isUser) else { continue }
                let url = root.url.appendingPathComponent(name)
                guard let af = try? AVAudioFile(forReading: url),
                      af.processingFormat.sampleRate > 0, af.length > 0 else { continue }
                let durMs = Int(Double(af.length) / af.processingFormat.sampleRate * 1000)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                store.addSample(StudioSample(id: id, name: "Recovered recording", fileName: name,
                                             wasUserFolder: root.isUser,
                                             createdAt: (created?.timeIntervalSince1970 ?? 0) * 1000,
                                             durationMs: durMs, source: .mic))
                known.insert(id)
                dlog("mic: recovered orphan \(name) user=\(root.isUser ? 1 : 0)")
            }
        }
    }

    // MARK: Session (iOS; macOS has no AVAudioSession — entitlement + permission suffice)

    /// Flip the shared session to `.playAndRecord` and ACTIVATE it — strictly BEFORE anything
    /// reads `inputNode` (its format is 0 Hz until the session actually grants input, and
    /// `installTap` on a 0 Hz format raises an uncatchable exception). The coexistence flag is
    /// set FIRST so a playback load racing the flip can't re-arm `.playback` in between.
    /// `[.defaultToSpeaker, .allowBluetoothA2DP]`: without them `.playAndRecord` reroutes output
    /// to the earpiece and drops A2DP headphones to phone-call audio — both would make "my music
    /// went quiet when I opened the sampler" bug reports.
    private func configureCaptureSession() -> Bool {
        AudioSessionPolicy.beginMicCapture()
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AudioSessionPolicy.endMicCapture()
            dlog("mic: session config FAILED \(error.localizedDescription)")
            return false
        }
        #endif
        return true
    }

    /// Give playback its category back: clear the coexistence flag FIRST (so this restore is the
    /// recorder's own, not a guarded site's), then re-arm `.playback` + keep the session active —
    /// whatever the playback engines are doing continues uninterrupted.
    private func restorePlaybackSession() {
        AudioSessionPolicy.endMicCapture()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Mic permission — the Shazam pattern verbatim: deployment targets (iOS 18 / macOS 15)
    /// clear `AVAudioApplication`'s availability floor, so no `#available` or legacy fallback.
    private static func ensureMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    // MARK: Engine + tap

    /// Idempotent observer/engine bring-up (the lazy `ensureEngine()` contract). There is no
    /// graph to WIRE for a pure input engine — `inputNode` exists implicitly and the tap is the
    /// whole render pull — so "build" here means: register the iOS session observers once, and
    /// the per-ENGINE-INSTANCE config-change observer (re-registered after a media-services
    /// rebuild replaced the instance).
    private func ensureEngine() {
        guard !built else { return }
        #if os(iOS)
        registerInterruptionHandling()
        registerRouteChangeHandling()
        registerMediaResetHandling()
        #endif
        registerConfigChangeHandling()
        built = true
    }

    /// (Re)install the input tap at the CURRENT hardware format. Called at monitoring start and
    /// on every recovery — a route change flips the input rate and a tap left at the old rate
    /// asserts uncatchably when the engine restarts. Returns false (soft) when the session isn't
    /// delivering input yet (0 Hz / 0 ch — the exact state that would crash `installTap`).
    private func installTapAtHardwareFormat() -> Bool {
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            dlog("mic: no usable input format (\(hw.sampleRate)Hz/\(hw.channelCount)ch)")
            return false
        }
        removeTap()
        tapSampleRate = hw.sampleRate
        tapChannels = hw.channelCount
        let sink = self.sink
        let levels = self.levels
        // Realtime thread: meter + flag-gated hand-off, nothing else. The sink deep-copies and
        // hops to its private queue; when not recording, `write` is a single flag check.
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { buffer, _ in
            Self.meter(buffer, into: levels)
            sink.write(buffer)
        }
        tapInstalled = true
        return true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Peak + RMS of one tap buffer into the meter mirror — runs ON the realtime thread (a
    /// straight float loop over ≤4096 frames is microseconds; full-precision RMS needs every
    /// sample, unlike MixEngine's stride-64 diagnostic scan). First channel only: the meter
    /// drives a UI bar, and studio input is mono in practice.
    private nonisolated static func meter(_ buffer: AVAudioPCMBuffer, into levels: StudioMicLevels) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        var sumSq: Float = 0
        for i in 0..<n {
            let v = ch[i]
            peak = max(peak, abs(v))
            sumSq += v * v
        }
        levels.peak = peak
        levels.rms = sqrtf(sumSq / Float(n))
        levels.updatedAt = Date().timeIntervalSinceReferenceDate
    }

    // MARK: Recovery (route change / config change / watchdog)

    /// Bring a stopped engine back while intent says the mic should be live: re-activate the
    /// session (after an interruption it's deactivated and `engine.start()` would fail forever),
    /// reinstall the tap at the FRESH hardware format, restart. Soft-fails and is retried by the
    /// watchdog ~1/s. A mid-take rate flip may still kill the AAC writer's appends — that path
    /// ends in the failure latch → auto-stop + file, never a crash or silent loss.
    private func recoverFromEngineStop() {
        guard isMonitoring, !engine.isRunning else { return }
        #if os(iOS)
        // Best-effort: while a phone call still owns audio this throws and we simply come back
        // next second (the `.ended`-not-guaranteed backstop).
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard installTapAtHardwareFormat() else { return }
        engine.prepare()
        do {
            try engine.start()
            interruptionParked = false
            dlog("mic: RECOVERED hw=\(Int(tapSampleRate))Hz ch=\(tapChannels)")
        } catch {
            dlog("mic: recover start failed — \(error.localizedDescription)")
        }
    }

    /// Per-ENGINE-INSTANCE config-change observer (`object: engine` — must be re-registered when
    /// the instance is replaced after a media reset): the system stopped + uninitialized the
    /// engine because its I/O configuration changed (the headphones→speaker rate flip). Recover
    /// immediately instead of waiting a watchdog tick so the capture misses as little as possible.
    private func registerConfigChangeHandling() {
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o) }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dlog("mic: CONFIG CHANGE run=\(self.engine.isRunning ? 1 : 0)"
                          + " in=\(Int(self.engine.inputNode.outputFormat(forBus: 0).sampleRate))Hz")
                self.recoverFromEngineStop()
            }
        }
    }

    #if os(iOS)
    /// Interruption park/latch (MixEngine's semantics, input-side): `.began` LATCHES (duplicates
    /// over Bluetooth/CarPlay must not erase the pairing record) — the system already stopped
    /// the engine, and a stopped input engine appends NOTHING, so the take's content clock
    /// freezes truthfully. `.ended` resumes only what `.began` parked and only on
    /// `.shouldResume`; it is NOT guaranteed to arrive — the tick watchdog keeps retrying either
    /// way, which is safe here because a successful mic restart resumes REAL capture (there is
    /// no "append silence into an open take" hazard on the input side).
    private func registerInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring,
                      let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.interruptionParked = true          // LATCH — never assign false here
                    self.dlog("mic: interruption BEGAN")
                case .ended:
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
                    self.dlog("mic: interruption ENDED resume=\(shouldResume ? 1 : 0)")
                    guard shouldResume, self.interruptionParked else { return }
                    self.interruptionParked = false
                    self.recoverFromEngineStop()
                @unknown default:
                    break
                }
            }
        }
    }

    /// A route CHANGE (headphones ⇄ speaker ⇄ Bluetooth) can stop the engine WITHOUT any
    /// interruption — recover immediately; `recoverFromEngineStop` no-ops when the engine kept
    /// running (same-format swaps).
    private func registerRouteChangeHandling() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverFromEngineStop()
                self?.refreshInputs()   // an interface was plugged/unplugged — update the picker
            }
        }
    }

    /// mediaserverd crashed: every node/tap in this process is orphaned. File the in-flight take
    /// FIRST (the AVAssetWriter is not CoreAudio-backed and can still finalize its fragments —
    /// the MixEngine rebuild doctrine), then recreate the engine. Capture does NOT auto-restart:
    /// whether to re-record after a daemon crash is the user's call (decks-come-back-paused
    /// doctrine); the next `beginMonitoring()` rebuilds and re-registers the per-instance
    /// config observer via `ensureEngine()`.
    private func registerMediaResetHandling() {
        guard mediaResetObserver == nil else { return }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
        }
    }

    private func rebuildAfterMediaReset() {
        guard built else { return }
        dlog("mic: MEDIA RESET")
        if isRecording {
            writerFailureMessage = "Recording stopped: the system's audio services were reset. "
                + "The audio captured so far was saved."
            if let take = finishTake() { fileSample(take) }
        }
        stopTick()
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o); configChangeObserver = nil }
        engine.stop()
        // The orphaned graph is unusable — recreate. The old tap dies with the old instance
        // (removeTap on an orphaned node is not worth the risk), so just drop the flag.
        engine = AVAudioEngine()
        tapInstalled = false
        built = false
        isMonitoring = false
        interruptionParked = false
        restorePlaybackSession()
    }
    #endif

    // MARK: Tick watchdog (~10 Hz — engine liveness + capture-stall warning + 1 Hz heartbeat)

    private func startTick() {
        tickTask?.cancel()
        lastTickAt = nil
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { break }
                self.tickFire()
            }
        }
    }

    private func stopTick() {
        tickTask?.cancel()
        tickTask = nil
        lastTickAt = nil
    }

    /// One watchdog tick. dt is CLAMPED to 0.5 s (the MixEngine contract) so an app suspension
    /// can't teleport the stall accumulator to "warned" the instant we resume — the stall window
    /// measures OBSERVED frozen time, not time asleep.
    private func tickFire() {
        guard isMonitoring else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let dt = Self.clampedTickDt(now: now, last: lastTickAt)
        lastTickAt = now

        // Engine liveness: intent says live but the engine is down → retry recovery ~1/s (the
        // observers usually beat this; the watchdog is the `.ended`-never-arrived backstop).
        if !engine.isRunning, now - lastRecoveryAt >= 1.0 {
            lastRecoveryAt = now
            recoverFromEngineStop()
        }

        // Capture stall: while recording, appended MEDIA must keep advancing. ≥5 s frozen flips
        // the warning (never auto-stop — the MixRecorder doctrine: definitive writer death
        // already auto-stops via the failure latch; anything else may recover mid-take).
        if isRecording {
            let appended = sink.appendedSeconds
            stallAccum = Self.nextStallAccum(stallAccum, dt: dt,
                                             appended: appended, previousAppended: lastAppended)
            lastAppended = appended
            let stalled = stallAccum >= Self.stallWarnSeconds
            if stalled != captureStalled {
                captureStalled = stalled
                dlog("mic: capture \(stalled ? "STALLED" : "resumed") appended=\(String(format: "%.1f", appended))s")
            }
        }

        // 1 Hz heartbeat while the mic is up — mirrors MixEngine's diagHeartbeat layer format so
        // a Settings ▸ Debug capture shows the input side's liveness next to the decks'.
        if now - lastHeartbeatAt >= 1.0 {
            lastHeartbeatAt = now
            dlog("mic hb: run=\(engine.isRunning ? 1 : 0) rec=\(isRecording ? 1 : 0)"
                 + " parked=\(interruptionParked ? 1 : 0)"
                 + " appended=\(String(format: "%.1f", sink.appendedSeconds))s"
                 + " peak=\(String(format: "%.3f", levels.peak))")
        }
    }

    // MARK: Pure seams (nonisolated statics — the hermetically-testable math)

    /// Frozen-capture time before `captureStalled` warns (seconds).
    nonisolated static let stallWarnSeconds = 5.0

    /// Watchdog dt: elapsed wall time since the last tick, clamped to [0, 0.5] s — a suspension
    /// gap contributes at most half a second of "observed" time (the MixEngine tick contract).
    nonisolated static func clampedTickDt(now: Double, last: Double?) -> Double {
        guard let last else { return 0 }
        return min(0.5, max(0, now - last))
    }

    /// Stall accumulator step: resets to 0 whenever appended media advanced (>10 ms — encoder
    /// granularity noise isn't progress) or on the first observation (`previousAppended < 0`,
    /// the just-armed state), else grows by the clamped dt.
    nonisolated static func nextStallAccum(_ accum: Double, dt: Double,
                                           appended: Double, previousAppended: Double) -> Double {
        guard previousAppended >= 0 else { return 0 }
        return appended > previousAppended + 0.01 ? 0 : accum + dt
    }

    /// Mint a fresh sample id + its deterministic file name, skipping names `isTaken` claims
    /// (collision-free against files already on disk). Bounded: after 100 mints the last one is
    /// returned regardless — 100 consecutive uuid collisions is not a real state, and a bounded
    /// loop can never hang the record button on a pathological `isTaken`.
    nonisolated static func mintSampleFile(
        isTaken: (String) -> Bool,
        mintId: () -> String = { StudioFactory.newSampleId() }) -> (id: String, fileName: String) {
        var minted = (id: "", fileName: "")
        for _ in 0..<100 {
            let id = mintId()
            minted = (id, StudioFolders.fileName(.samples, id: id))
            if !isTaken(minted.fileName) { return minted }
        }
        return minted
    }

    /// The orphan-scan adoption decision (pure — the disk-readability gate stays at the call
    /// site): the embedded sample id iff `fileName` is a RAW capture the document doesn't know
    /// and isn't the take being written right now. Rules, in order:
    ///   • STRICT family shape (`StudioFolders.fileId`) — loose prefix matches are forbidden,
    ///     user folders hold user files;
    ///   • RAW shape only: a render cache (`sample-<id>-r<rev>.m4a`) parses to the same id but
    ///     is derived data — adopting one would resurrect a deleted sample's bake as a take;
    ///   • not document-known (idempotency);
    ///   • not the active take in THIS root (root-aware: a same-named file in the OTHER root is
    ///     a genuine orphan — the both-roots doctrine).
    nonisolated static func adoptableSampleId(
        fileName: String, knownIds: Set<String>,
        activeTake: (fileName: String, wasUserFolder: Bool)?, rootIsUser: Bool) -> String? {
        guard let id = StudioFolders.fileId(family: .samples, name: fileName) else { return nil }
        guard fileName == StudioFolders.fileName(.samples, id: id) else { return nil }
        guard !knownIds.contains(id) else { return nil }
        if let live = activeTake, live.fileName == fileName, live.wasUserFolder == rootIsUser {
            return nil
        }
        return id
    }
}
