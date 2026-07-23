import Foundation
// @preconcurrency: AVFAudio's value types (AVAudioPCMBuffer, AVAudioConverterInputBlock) predate
// Swift's Sendable annotations, so passing them across the offline converter's `@Sendable` input
// block trips Sendable warnings that are noise here — all this work is actor-serialized on one
// thread. This is the compiler's own suggested fix.
@preconcurrency import AVFoundation
import AudioToolbox       // kAUSampler_DefaultMelodicBankMSB / kAUSampler_DefaultBankLSB (instrumental render)
import Accelerate
import os

// MARK: - Render errors

/// StudioRender failures. Every case leaves NO partial file behind (temp + atomic move).
enum StudioRenderError: Error {
    /// The pattern has zero sounding content — bouncing it would schedule zero frames (an
    /// uncatchable crash) or bake a silent bar. The view shows the inline notice (spec §2).
    case emptyPattern
    /// The source audio couldn't be opened/read.
    case unreadableSource(URL)
    /// The requested window resolves to zero frames (bad trim / region past EOF).
    case emptyWindow
    /// No usable beat grid for the loop slice (no beats AND no positive BPM).
    case noGrid
    /// The offline engine refused to start (should not happen — manual rendering is headless).
    case engineStart(Error)
    /// PCM buffer/converter allocation failed (absurd sizes / exhausted memory).
    case cannotCreateBuffer
    /// The imported file is DRM-protected (a FairPlay `.m4p` / stream) — never a sample (spec §12).
    case protectedSource(URL)
    /// An instrumental render was asked for with no note events — it would schedule zero frames.
    case emptyTake
    /// The instrument's SoundFont bank couldn't be loaded into the offline sampler (missing /
    /// unreadable / not downloaded). The view points the user at the pack download.
    case bankLoadFailed(URL)
}

// MARK: - Stretch identity

/// Identity of a pre-stretched pattern-step buffer: one TARGET tempo-fit to `span` steps at the
/// pattern's bpm. Prepare/bounce call sites dedupe stretch renders on this key (the same sample
/// fit to 4 steps on two rows stretches once) — the span sibling of `bouncePattern`'s
/// target-id buffer keying.
struct StudioStretchKey: Hashable, Sendable {
    let targetId: String
    let span: Int
}

// MARK: - StudioRender (offline bounce — spec §4)

/// The Studio OFFLINE renderer — `AVAudioEngine.enableManualRenderingMode(.offline)` graphs that
/// MIRROR the audition chains, pulled faster than realtime and written with
/// `AVAudioFile(forWriting:settings:)` (blocking writes — no backpressure, no dropped buffers).
///
/// This is deliberately NOT the MixTapSink/AVAssetWriter recipe: that sink is a REALTIME tap
/// consumer (`expectsMediaDataInRealTime`, drops buffers when the encoder is busy — the common
/// case offline) and using it here was a reviewed blocker. Only its failure-latch discipline
/// carries over: a throwing render never leaves a partial file behind (everything writes to a
/// temp sibling and atomically moves into place on success).
///
/// Formats (spec §2/§4):
///   • sample renders + pattern bounces → AAC `.m4a` (44.1 kHz stereo, ~192 kbps);
///   • loops → LPCM CAF Float32 (AAC priming/padding makes m4a loop files tick at the seam;
///     CAF + an authoritative frame count is the seamless-loop guarantee).
///
/// Render rules (each closes a reviewed defect):
///   • samples/bounces: length = ⌈sourceFrames/rate⌉ **+ FX tail drain** — keep rendering until
///     a 512-frame RMS window falls below −60 dBFS or a +3 s cap, so a reverb/delay tail is
///     never truncated and a dry render doesn't run to the cap;
///   • loops: EXACTLY the beat-window frame count (post-rate) — tails truncated, seams clean;
///   • the AU priming-latency head (timePitch latency + engine render latency, in frames) is
///     TRIMMED so frame 0 of the written file is musical frame 0 (otherwise every baked loop
///     starts with silence and beat-sync dies).
///
/// An ACTOR: rendering is CPU-bound, so the work runs off the main actor, and actor isolation
/// serializes concurrent render requests for free (two simultaneous bakes would just thrash the
/// encoder). Callers hop back to `@MainActor` themselves to file results into `StudioStore`.
actor StudioRender {
    /// The app-wide renderer (all render traffic serializes here by design).
    static let shared = StudioRender()

    // Statics on an actor are nonisolated — shared with the sync decode seam + tests.
    static let canonicalSampleRate = StudioAudio.canonicalSampleRate
    private static var canonicalFormat: AVAudioFormat { StudioAudio.canonicalFormat }

    /// The offline pull size. Also the manual-rendering maximumFrameCount — one buffer is
    /// allocated per render and reused for every pull.
    private static let chunkFrames: AVAudioFrameCount = 4096
    /// Tail-drain window (spec §4): the drain stops at the first 512-frame window whose RMS is
    /// below `tailFloorDb`, or after `tailCapSeconds` of tail.
    private static let tailWindowFrames: AVAudioFrameCount = 512
    private static let tailFloorDb: Double = -60
    private static let tailCapSeconds: Double = 3

    /// Diagnostics: same subsystem as mixdiag (one `log stream` predicate covers everything);
    /// lines are mirrored into the Settings ▸ Debug capture via a main-actor hop (ordering
    /// jitter across the hop is fine for logs).
    private static let diag = Logger(subsystem: "com.levi.pocketdj", category: "studiodiag")
    private static func rlog(_ s: String) {
        diag.info("\(s, privacy: .public)")
        Task { @MainActor in MixDiag.shared.append("render " + s) }
    }

    // MARK: - Public API

    /// Bake a sample's non-destructive edit (trim + gain + rate + pitch + wets) into an AAC
    /// `.m4a` at `destURL` — the render cache collection playback prefers (`StudioStore.
    /// setRenderedSample` files the result with the edit revision it was rendered at).
    func renderSample(_ sample: StudioSample, sourceURL: URL, to destURL: URL) async throws
        -> (frames: Int64, durationMs: Int) {
        let edit = sample.edit.clamped()
        guard let file = try? AVAudioFile(forReading: sourceURL) else {
            throw StudioRenderError.unreadableSource(sourceURL)
        }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { throw StudioRenderError.emptyWindow }
        // Trim window in SOURCE frames (`trimEndMs == 0` ⇒ end of file — the model's neutral).
        let startFrame = min(AVAudioFramePosition((Double(max(0, edit.trimStartMs)) / 1000 * sr).rounded()),
                             file.length)
        let endFrame = edit.trimEndMs > 0
            ? min(AVAudioFramePosition((Double(edit.trimEndMs) / 1000 * sr).rounded()), file.length)
            : file.length
        let count = endFrame - startFrame
        guard count > 0 else { throw StudioRenderError.emptyWindow }   // zero-frame schedule = crash

        let chain = try Self.makeOfflineChain(fileFormat: file.processingFormat, edit: edit)
        defer { chain.engine.stop() }
        Self.scheduleSegment(file, on: chain.player, startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(count))
        chain.player.play()

        // Musical length: the source window, resampled to canonical, time-stretched by rate.
        let nominal = Int64(ceil(Double(count) * Self.canonicalSampleRate / sr / edit.rate))
        let head = Self.primingHeadFrames(chain)
        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            try Self.pullAndWrite(engine: chain.engine, to: out, skipHead: head,
                                  nominal: nominal, drainTail: true)
        }
        let ms = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        Self.rlog("sample \(sample.id): \(frames)f/\(ms)ms (nominal=\(nominal) head=\(head) rate=\(edit.rate))")
        return (frames, ms)
    }

    /// Render a beat-window slice of a sample to a seamless LPCM CAF loop. The window comes from
    /// `BeatMath.sliceBoundaries` on the sample's grid (ms from the SAMPLE's 0:00 — the same
    /// timeline as `anchorMs`); the sample's SONIC edits (gain/rate/pitch/wets) are baked; the
    /// edit's trim is deliberately superseded by the beat window (the window IS the trim). The
    /// output is EXACTLY the post-rate beat-window frame count: tails truncated, a source that
    /// runs out zero-pads (the engine renders silence past the schedule) — either way the seam
    /// lands on the musical boundary. Returned `bpm` is the loop's standalone tempo — derived
    /// from beats over the RENDERED length, so a baked rate≠1 is already accounted for.
    func renderLoop(sample: StudioSample, sourceURL: URL, anchorMs: Int, beats: LoopBeats,
                    grid: StudioGrid, to destURL: URL) async throws
        -> (frames: Int64, lengthMs: Int, bpm: Double) {
        guard let slice = BeatMath.sliceBoundaries(anchorMs: anchorMs, beats: beats.beatCount,
                                                   grid: grid.sliceGrid),
              slice.lengthMs > 0 else { throw StudioRenderError.noGrid }
        let edit = sample.edit.clamped()
        let exact = Int64((Double(slice.lengthMs) / 1000 * Self.canonicalSampleRate / edit.rate).rounded())
        guard exact > 0 else { throw StudioRenderError.emptyWindow }

        guard let file = try? AVAudioFile(forReading: sourceURL) else {
            throw StudioRenderError.unreadableSource(sourceURL)
        }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { throw StudioRenderError.emptyWindow }
        let startFrame = max(0, AVAudioFramePosition((Double(slice.startMs) / 1000 * sr).rounded()))
        guard startFrame < file.length else { throw StudioRenderError.emptyWindow }   // window fully past EOF
        let endFrame = min(AVAudioFramePosition((Double(slice.endMs) / 1000 * sr).rounded()), file.length)
        let count = endFrame - startFrame
        guard count > 0 else { throw StudioRenderError.emptyWindow }

        let chain = try Self.makeOfflineChain(fileFormat: file.processingFormat, edit: edit)
        defer { chain.engine.stop() }
        Self.scheduleSegment(file, on: chain.player, startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(count))
        chain.player.play()

        let head = Self.primingHeadFrames(chain)
        let frames = try Self.writeAtomically(to: destURL, settings: Self.cafSettings) { out in
            try Self.pullAndWrite(engine: chain.engine, to: out, skipHead: head,
                                  nominal: exact, drainTail: false)   // EXACT frames — no tail
        }
        let lengthMs = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        // Standalone tempo of the rendered audio: beats over rendered time (post-rate by
        // construction). Guard the degenerate 0-ms case (can't happen past the guards above).
        let bpm = lengthMs > 0 ? beats.beatCount * 60_000.0 / Double(lengthMs) : (grid.bpm * edit.rate)
        Self.rlog("loop for \(sample.id): \(frames)f/\(lengthMs)ms bpm=\(String(format: "%.2f", bpm))"
                  + " (window \(slice.startMs)–\(slice.endMs)ms head=\(head))")
        return (frames, lengthMs, bpm)
    }

    /// Bounce one bar of a pattern (+ FX-free tail drain — hits ringing past the bar end) to an
    /// AAC `.m4a`. `buffers` maps row TARGET id → the row's pre-baked canonical PCM. Rows whose
    /// target is missing (no buffer) are SKIPPED, never a throw (spec §2) — but a pattern whose
    /// sounding rows are ALL missing is refused as `.emptyPattern`: the bounce would be a bar of
    /// silence, and playback refuses the same pattern for the same reason.
    ///
    /// Per-step modes: `spanBuffers` carries the pre-stretched span variants (`stretchBuffer`
    /// output, keyed target+span — deduped across rows). LOOP steps are baked as FINITE chained
    /// repeats trimmed to the row's next trigger or the bar end — never `.loops`: an endless
    /// schedule would ring straight through the tail drain to its 3 s cap, and the bounce's wrap
    /// restart is the bar boundary itself (the bounced bar loops as a whole downstream).
    func bouncePattern(_ pattern: StudioPattern, buffers: [String: AVAudioPCMBuffer],
                       spanBuffers: [StudioStretchKey: AVAudioPCMBuffer] = [:], to destURL: URL)
        async throws -> (frames: Int64, lengthMs: Int) {
        guard pattern.hasSoundingSteps else { throw StudioRenderError.emptyPattern }
        let bpm = pattern.bpm > 0 ? pattern.bpm : 120

        // Mirror the audition graph: plain player → gain → mainMixer per row, no live AUs (the
        // buffers are pre-baked), scheduled sample-accurately with `.interrupts` mono-choke.
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: Self.canonicalFormat,
                                                  maximumFrameCount: Self.chunkFrames) }
        catch { throw StudioRenderError.engineStart(error) }
        var voices: [(player: AVAudioPlayerNode, row: StudioPatternRow, buffer: AVAudioPCMBuffer)] = []
        for row in pattern.rows.prefix(StudioEngine.maxPatternRows) {
            guard !row.isSilent,
                  let buf = buffers[row.targetId], buf.frameLength > 0,     // zero-frame schedule = crash
                  StudioAudio.isCanonical(buf.format) else { continue }     // format mismatch raises
            let p = AVAudioPlayerNode(); let g = AVAudioMixerNode()
            engine.attach(p); engine.attach(g)
            engine.connect(p, to: g, format: Self.canonicalFormat)
            engine.connect(g, to: engine.mainMixerNode, format: Self.canonicalFormat)
            g.outputVolume = StudioAudio.gainMultiplier(db: row.gainDb)
            voices.append((p, row, buf))
        }
        guard !voices.isEmpty else { throw StudioRenderError.emptyPattern }
        defer { engine.stop() }
        do { try engine.start() } catch { throw StudioRenderError.engineStart(error) }

        let stepF = StudioEngine.stepFrames(bpm: bpm, sampleRate: Self.canonicalSampleRate)
        let barFrames = stepF * Int64(pattern.stepCount)   // the full pattern loop (SEQ4: may be many bars)
        for v in voices {
            let onCols = v.row.steps.indices.filter { v.row.steps[$0] }
            let stepBuf: (Int) -> AVAudioPCMBuffer = { col in
                let span = v.row.stepSpans.indices.contains(col) ? v.row.stepSpans[col] : 0
                return span > 0
                    ? (spanBuffers[StudioStretchKey(targetId: v.row.targetId, span: span)] ?? v.buffer)
                    : v.buffer
            }
            // STEADY-STATE WRAP FILL, scheduled FIRST (the player queue must stay time-ordered):
            // live playback's LAST loop trigger rings across the bar wrap until the row's FIRST
            // trigger of the next pass. The one-bar bounce represents that steady state — fill
            // [0, firstTrigger) with the loop's continuing phase so the bounced bar has no
            // dropout live playback doesn't have (bounce ≡ live).
            if let last = onCols.last, let first = onCols.first, first > 0,
               v.row.loopSteps.indices.contains(last), v.row.loopSteps[last] {
                let loopBuf = stepBuf(last)
                let bufFrames = Int64(loopBuf.frameLength)
                if bufFrames > 0 {
                    let firstF = Int64(first) * stepF
                    var offset = (barFrames - Int64(last) * stepF) % bufFrames
                    var pos: Int64 = 0
                    while pos < firstF {
                        let len = min(bufFrames - offset, firstF - pos)
                        guard len > 0, let piece = Self.sliceBuffer(loopBuf, from: offset, frames: len)
                        else { break }
                        Self.scheduleStep(piece, on: v.player,
                                          at: AVAudioTime(sampleTime: pos, atRate: Self.canonicalSampleRate))
                        pos += len
                        offset = 0                       // after the phase-continuation piece: full repeats
                    }
                }
            }
            for (k, col) in onCols.enumerated() {
                let buf = stepBuf(col)
                let start = Int64(col) * stepF
                let isLoop = v.row.loopSteps.indices.contains(col) && v.row.loopSteps[col]
                if isLoop {
                    // Finite loop bake: repeats chained back-to-back from the trigger, the last
                    // one trimmed so the chain ends EXACTLY at the next trigger (which live
                    // playback would cut with `.interrupts`) or the bar end (the wrap).
                    let cut = k + 1 < onCols.count ? Int64(onCols[k + 1]) * stepF : barFrames
                    var pos = start
                    while pos < cut {
                        let repFrames = min(Int64(buf.frameLength), cut - pos)
                        guard repFrames > 0,
                              let piece = repFrames == Int64(buf.frameLength)
                                  ? buf : StudioAudio.trimmedOrPadded(buf, to: repFrames) else { break }
                        Self.scheduleStep(piece, on: v.player,
                                          at: AVAudioTime(sampleTime: pos, atRate: Self.canonicalSampleRate))
                        pos += repFrames
                    }
                } else {
                    Self.scheduleStep(buf, on: v.player,
                                      at: AVAudioTime(sampleTime: start, atRate: Self.canonicalSampleRate))
                }
            }
            v.player.play()
        }

        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            // No AU chain here ⇒ no priming head to trim; the drain lets the last hit ring out.
            try Self.pullAndWrite(engine: engine, to: out, skipHead: 0,
                                  nominal: barFrames, drainTail: true)
        }
        let lengthMs = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        Self.rlog("bounce \(pattern.id): \(frames)f/\(lengthMs)ms (bar=\(barFrames) rows=\(voices.count))")
        return (frames, lengthMs)
    }

    /// Decode a whole audio file to a CANONICAL (44.1 kHz stereo Float32 deinterleaved) PCM
    /// buffer — the shared seam for pattern-row buffers and any caller that schedules PCM on the
    /// canonical-pinned graph. Off-main via the actor; `decodeFileSync` is the same code for the
    /// engine's synchronous loop-audition path (small files, one-time cost).
    func decodeBuffer(url: URL) async throws -> AVAudioPCMBuffer {
        try Self.decodeFileSync(url: url)
    }

    /// Tempo-fit a canonical PCM buffer to EXACTLY `frames` frames — time-stretch through a bare
    /// offline `player → timePitch → main` chain (rate = source/target, pitch preserved), head
    /// latency dropped, output trimmed/zero-padded to the exact target. This is the sequencer's
    /// step-span bake: a span buffer must land bit-exactly on span×step frames or the grid's
    /// sample-accurate schedule drifts (the `renderLoop` exact-frames doctrine). The rate is
    /// clamped to timePitch's legal 1/32…32; extreme fits are the user's call — artifacts and all.
    func stretchBuffer(_ source: AVAudioPCMBuffer, toFrames frames: Int64) async throws
        -> AVAudioPCMBuffer {
        guard frames > 0, source.frameLength > 0 else { throw StudioRenderError.emptyWindow }
        guard StudioAudio.isCanonical(source.format) else { throw StudioRenderError.cannotCreateBuffer }
        if Int64(source.frameLength) == frames { return source }
        let rate = min(max(Double(source.frameLength) / Double(frames), 1.0 / 32.0), 32.0)
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: Self.canonicalFormat,
                                                  maximumFrameCount: Self.chunkFrames) }
        catch { throw StudioRenderError.engineStart(error) }
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.rate = Float(rate)
        engine.attach(player); engine.attach(tp)
        engine.connect(player, to: tp, format: Self.canonicalFormat)
        engine.connect(tp, to: engine.mainMixerNode, format: Self.canonicalFormat)
        defer { engine.stop() }
        do { try engine.start() } catch { throw StudioRenderError.engineStart(error) }
        Self.scheduleWhole(source, on: player)
        player.play()
        let headSec = tp.auAudioUnit.latency + engine.outputNode.auAudioUnit.latency
        let head = max(0, Int64((headSec * Self.canonicalSampleRate).rounded()))
        let out = try Self.pullFrames(engine: engine, skipHead: head, count: frames)
        Self.rlog("stretch \(source.frameLength)f → \(frames)f (rate \(String(format: "%.3f", rate)))")
        return out
    }

    /// Neutral-edit region carve for sample creation (spec §4/§10): read the `[startMs, endMs)`
    /// frames, convert to canonical, write AAC `.m4a`. No FX graph — nothing to bake, so a plain
    /// read+convert+write is exact and fast (the sample's edit starts neutral).
    func carveTrackRegion(sourceURL: URL, startMs: Int, endMs: Int, to destURL: URL) async throws
        -> (frames: Int64, durationMs: Int) {
        guard startMs >= 0, endMs > startMs else { throw StudioRenderError.emptyWindow }
        guard let file = try? AVAudioFile(forReading: sourceURL) else {
            throw StudioRenderError.unreadableSource(sourceURL)
        }
        let sr = file.processingFormat.sampleRate
        guard sr > 0, file.length > 0 else { throw StudioRenderError.emptyWindow }
        let startFrame = min(AVAudioFramePosition((Double(startMs) / 1000 * sr).rounded()), file.length)
        let endFrame = min(AVAudioFramePosition((Double(endMs) / 1000 * sr).rounded()), file.length)
        let count = endFrame - startFrame
        guard count > 0 else { throw StudioRenderError.emptyWindow }
        file.framePosition = startFrame
        // Loop-read (short reads are legal — see `readFrames`) so the carve is frame-exact.
        let raw = try Self.readFrames(file, count: AVAudioFrameCount(count), from: sourceURL)
        guard raw.frameLength > 0 else { throw StudioRenderError.emptyWindow }
        let canonical = try Self.convertToCanonical(raw)
        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            try out.write(from: canonical)
            return Int64(canonical.frameLength)
        }
        let ms = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        Self.rlog("carve \(sourceURL.lastPathComponent) [\(startMs)–\(endMs)ms] → \(frames)f/\(ms)ms")
        return (frames, ms)
    }

    /// Carve a MIX of selected STEMS for a region into one canonical AAC sample (spec §10 + stem
    /// sampling). Reads each stem's `[startMs, endMs)` window — stems are SONG-RELATIVE (0:00 = song
    /// start, like a cut, so NO album offset), converts each to canonical, and SUMS them
    /// sample-for-sample into one accumulator. Demucs stems sum back to ~the original mix, so no
    /// attenuation is applied (a subset is simply quieter, exactly like muting stems on a deck). At
    /// least one stem URL required; an unreadable stem throws (all-or-nothing, the mix must be whole).
    func carveStemMix(stemURLs: [URL], startMs: Int, endMs: Int, to destURL: URL) async throws
        -> (frames: Int64, durationMs: Int) {
        guard startMs >= 0, endMs > startMs, !stemURLs.isEmpty else { throw StudioRenderError.emptyWindow }
        let windowFrames = AVAudioFrameCount(max(1, Int((Double(endMs - startMs) / 1000
                                                         * Self.canonicalSampleRate).rounded())))
        guard let acc = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat,
                                         frameCapacity: windowFrames) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        acc.frameLength = windowFrames
        if let d = acc.floatChannelData {                    // fresh buffers aren't guaranteed zeroed
            for c in 0..<Int(acc.format.channelCount) {
                memset(d[c], 0, Int(windowFrames) * MemoryLayout<Float>.size)
            }
        }
        var summed = 0
        for url in stemURLs {
            guard let file = try? AVAudioFile(forReading: url) else {
                throw StudioRenderError.unreadableSource(url)
            }
            let sr = file.processingFormat.sampleRate
            guard sr > 0, file.length > 0 else { continue }
            let startFrame = min(AVAudioFramePosition((Double(startMs) / 1000 * sr).rounded()), file.length)
            let endFrame = min(AVAudioFramePosition((Double(endMs) / 1000 * sr).rounded()), file.length)
            guard endFrame > startFrame else { continue }
            file.framePosition = startFrame
            let raw = try Self.readFrames(file, count: AVAudioFrameCount(endFrame - startFrame), from: url)
            guard raw.frameLength > 0 else { continue }
            let canonical = try Self.convertToCanonical(raw)
            Self.addBuffer(canonical, into: acc)
            summed += 1
        }
        guard summed > 0 else { throw StudioRenderError.emptyWindow }
        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            try out.write(from: acc)
            return Int64(acc.frameLength)
        }
        let ms = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        Self.rlog("stem-carve \(summed) stems [\(startMs)–\(endMs)ms] → \(frames)f/\(ms)ms")
        return (frames, ms)
    }

    /// Sum `src`'s frames into `acc` in place (both canonical stereo) — `acc[i] += src[i]` per
    /// channel over the overlapping length. The mix accumulator's length is the authority; a stem
    /// that ran a frame short just contributes silence for the tail.
    private nonisolated static func addBuffer(_ src: AVAudioPCMBuffer, into acc: AVAudioPCMBuffer) {
        guard let s = src.floatChannelData, let d = acc.floatChannelData else { return }
        let n = min(src.frameLength, acc.frameLength)
        guard n > 0 else { return }
        let ch = min(Int(src.format.channelCount), Int(acc.format.channelCount))
        for c in 0..<ch {
            vDSP_vadd(d[c], 1, s[c], 1, d[c], 1, vDSP_Length(n))
        }
    }

    /// Import an ARBITRARY audio file (file browser) as a new sample: decode the WHOLE file →
    /// canonical → AAC `.m4a`, exactly like a full-length `carveTrackRegion` but from any container
    /// AVFoundation can read (mp3/wav/aiff/caf/m4a…). Rejects DRM-protected assets up front — a
    /// FairPlay `.m4p` must never be turned into a sample (spec §12). The imported sample starts
    /// grid-less (no server sidecar); auto-detect/tap-tempo sets a grid before slicing.
    func importAudioFile(sourceURL: URL, to destURL: URL) async throws -> (frames: Int64, durationMs: Int) {
        let asset = AVURLAsset(url: sourceURL)
        if (try? await asset.load(.hasProtectedContent)) == true {
            throw StudioRenderError.protectedSource(sourceURL)
        }
        let canonical = try Self.decodeFileSync(url: sourceURL)   // whole-file read + convert-to-canonical
        guard canonical.frameLength > 0 else { throw StudioRenderError.emptyWindow }
        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            try out.write(from: canonical)
            return Int64(canonical.frameLength)
        }
        let ms = Int((Double(frames) / Self.canonicalSampleRate * 1000).rounded())
        Self.rlog("import \(sourceURL.lastPathComponent) → \(frames)f/\(ms)ms")
        return (frames, ms)
    }

    // MARK: - Instrumental render (sampler note events → audio)

    /// Synthesize an instrument take's note events into a REAL AAC `.m4a` at `destURL` by playing
    /// them through an OFFLINE `AVAudioUnitSampler` loaded with the take's SoundFont bank at GM
    /// `program`. This is the events→audio render that `InstrumentEngine.replayTake` does live, in
    /// realtime — done offline, faster than realtime — so a take (recorded OR saved from the live
    /// staff, whose stored file is only a silent placeholder) can become a real, audible file for
    /// "Use as sample", "Sample from instrumental", and audio export.
    ///
    /// The caller passes `take.scoreEvents` (the edited stream once the score's been touched, else
    /// the raw performance) so an edited take renders what the score shows. `bankURL` is resolved
    /// by the caller via `InstrumentPackStore.localBankURL(forInstrument:)`; a nil there is the
    /// "download the pack first" prompt (the same gate Replay uses), never a silent fallback.
    ///
    /// Timing mirrors the sample bakes: notes fire frame-accurately, the AU priming-latency head is
    /// trimmed so written frame 0 is musical frame 0, and the sampler's release rings out into the
    /// −60 dBFS / 3 s tail drain (a note-off's decay is never truncated).
    func renderTake(events: [StudioNoteEvent], bankURL: URL, program: UInt8,
                    to destURL: URL) async throws -> (frames: Int64, durationMs: Int) {
        let actions = InstrumentEngine.replayActions(events: events)
        guard !actions.isEmpty else { throw StudioRenderError.emptyTake }

        let fmt = Self.canonicalFormat
        let sr = Self.canonicalSampleRate
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: fmt,
                                                  maximumFrameCount: Self.chunkFrames) }
        catch { throw StudioRenderError.engineStart(error) }
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: fmt)
        // Parse the SoundFont BEFORE start (manual-mode setup needs the engine stopped). Synchronous
        // here — one render, one parse, nothing else touches the sampler — so no engineReady gate is
        // needed the way the live engine's background parse requires it.
        do {
            try sampler.loadSoundBankInstrument(at: bankURL, program: program,
                                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        } catch { throw StudioRenderError.bankLoadFailed(bankURL) }
        do { try engine.start() } catch { throw StudioRenderError.engineStart(error) }
        defer { engine.stop() }

        // Musical length = last note-off. The priming head (AU + output-node latency, in frames) is
        // dropped from the front so the first note lands at written-frame 0.
        let lastMs = actions.map(\.ms).max() ?? 0
        let nominal = Int64((Double(lastMs) / 1000 * sr).rounded())
        let latencySec = sampler.auAudioUnit.latency + engine.outputNode.auAudioUnit.latency
        let skipHead = max(0, Int64((latencySec * sr).rounded()))

        let frames = try Self.writeAtomically(to: destURL, settings: Self.aacSettings) { out in
            try Self.pumpSampler(engine: engine, sampler: sampler, actions: actions,
                                 sampleRate: sr, skipHead: skipHead, nominal: nominal, to: out)
        }
        let durationMs = Int((Double(frames) / sr * 1000).rounded())
        Self.rlog("take \(events.count) events → \(frames)f/\(durationMs)ms")
        return (frames, durationMs)
    }

    /// Event-driven offline pump: render the sampler's output in blocks, firing each note on/off at
    /// its frame, then drain the release tail (the same −60 dBFS / 3 s stop the sample bakes use).
    /// The counterpart to `pullAndWrite`, but the source is MIDI actions instead of a scheduled
    /// file — everything past the priming head is written; the head is dropped.
    private static func pumpSampler(engine: AVAudioEngine, sampler: AVAudioUnitSampler,
                                    actions: [(ms: Int, on: Bool, note: Int, velocity: Int)],
                                    sampleRate: Double, skipHead: Int64, nominal: Int64,
                                    to out: AVAudioFile) throws -> Int64 {
        let fmt = engine.manualRenderingFormat
        guard let render = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames),
              let scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        // Render-timeline frame of an event = musical frame + priming head.
        func frameOf(_ ms: Int) -> Int64 {
            skipHead + Int64((Double(max(0, ms)) / 1000 * sampleRate).rounded())
        }
        var pulled: Int64 = 0
        var written: Int64 = 0
        // Render forward to `target`, writing everything past the head (dropping the head's frames).
        func pull(to target: Int64) throws {
            while pulled < target {
                let want = AVAudioFrameCount(min(Int64(chunkFrames), target - pulled))
                let status = try engine.renderOffline(want, to: render)
                guard status == .success, render.frameLength > 0 else { break }
                let dropFront = Int(max(0, min(Int64(render.frameLength), skipHead - pulled)))
                try writeSlice(render, from: dropFront, to: out, scratch: scratch)
                written += Int64(render.frameLength) - Int64(dropFront)
                pulled += Int64(render.frameLength)
            }
        }
        // Fire events in time order, rendering up to each event's frame before applying it.
        var idx = 0
        while idx < actions.count {
            try pull(to: frameOf(actions[idx].ms))
            while idx < actions.count, frameOf(actions[idx].ms) <= pulled {
                let a = actions[idx]; idx += 1
                let n = UInt8(clamping: max(0, min(127, a.note)))
                if a.on {
                    sampler.startNote(n, withVelocity: UInt8(clamping: max(1, min(127, a.velocity))),
                                      onChannel: 0)
                } else {
                    sampler.stopNote(n, onChannel: 0)
                }
            }
        }
        try pull(to: skipHead + nominal)   // out to the last note-off
        // Release-tail drain: the last note-off's decay rings out here (same stop as sample bakes).
        let cap = Int64(tailCapSeconds * sampleRate)
        var tail: Int64 = 0
        while tail < cap {
            let status = try engine.renderOffline(tailWindowFrames, to: render)
            guard status == .success, render.frameLength > 0 else { break }
            try writeSlice(render, from: 0, to: out, scratch: scratch)
            written += Int64(render.frameLength)
            tail += Int64(render.frameLength)
            if isBelowFloor(render, floorDb: tailFloorDb) { break }
        }
        return written
    }

    // MARK: - Sync decode (nonisolated — the engine's loop-audition path calls this directly)

    /// Read a whole file and return it as ONE canonical PCM buffer. Throws instead of returning
    /// nil so callers get the reason (unreadable vs allocation).
    nonisolated static func decodeFileSync(url: URL) throws -> AVAudioPCMBuffer {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw StudioRenderError.unreadableSource(url)
        }
        guard file.length > 0, file.length <= Int64(UInt32.max) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        let raw = try readFrames(file, count: AVAudioFrameCount(file.length), from: url)
        return try convertToCanonical(raw)
    }

    /// Read up to `count` frames from `file`'s CURRENT position, looping over SHORT READS:
    /// `AVAudioFile.read(into:)` can legally return fewer frames than asked even when more data
    /// exists (measured: a 24 000-frame CAF returning 23 552, then 448 on the next call) — a
    /// single-call read silently truncates the decode and every downstream frame count with it.
    /// Returns a buffer whose `frameLength` is `count` clamped to what the file actually held.
    private nonisolated static func readFrames(_ file: AVAudioFile, count: AVAudioFrameCount,
                                               from url: URL) throws -> AVAudioPCMBuffer {
        guard count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: min(count, chunkFrames)) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        while out.frameLength < count, file.framePosition < file.length {
            let before = file.framePosition
            do { try file.read(into: chunk, frameCount: min(chunk.frameCapacity, count - out.frameLength)) }
            catch { throw StudioRenderError.unreadableSource(url) }
            guard chunk.frameLength > 0, file.framePosition > before else { break }   // no progress — never spin
            appendPCM(chunk, to: out)
        }
        return out
    }

    /// Convert any PCM buffer to the canonical format (passthrough when it already is — the
    /// common case for StudioRender-baked artifacts, which keeps loop audition zero-copy).
    /// Sample-rate conversion of a FINITE signal needs care at both ends (all measured):
    ///   • `primeMethod = .none` — the default treats the head as resampler warm-up and EATS
    ///     ~400 frames, shifting every decoded file off its downbeat;
    ///   • the SRC's polyphase filter holds ~400 frames of TAIL state it only emits given
    ///     trailing input context — so a silence tail is fed after the real buffer, then the
    ///     output is truncated to the exact resampled length (the silence's contribution).
    /// Net result: `frameLength == ceil(input × ratio)` with content aligned at frame 0.
    nonisolated static func convertToCanonical(_ raw: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if StudioAudio.isCanonical(raw.format) { return raw }
        guard let conv = AVAudioConverter(from: raw.format, to: StudioAudio.canonicalFormat) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        conv.primeMethod = .none
        let ratio = canonicalSampleRate / raw.format.sampleRate
        let expected = Int64((Double(raw.frameLength) * ratio).rounded(.up))
        guard expected > 0, expected + 8192 <= Int64(UInt32.max),
              let out = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat,
                                         frameCapacity: AVAudioFrameCount(expected + 8192)),
              let flushTail = AVAudioPCMBuffer(pcmFormat: raw.format, frameCapacity: 4096) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        flushTail.frameLength = 4096   // fresh buffers aren't guaranteed zeroed — silence explicitly
        if let d = flushTail.floatChannelData {
            for c in 0..<Int(raw.format.channelCount) { memset(d[c], 0, 4096 * MemoryLayout<Float>.size) }
        }
        var inputStage = 0             // 0 → the real buffer, 1 → the silence tail, 2 → end-of-stream
        var convError: NSError?
        while out.frameLength < AVAudioFrameCount(expected) {
            guard let piece = AVAudioPCMBuffer(pcmFormat: StudioAudio.canonicalFormat,
                                               frameCapacity: 8192) else {
                throw StudioRenderError.cannotCreateBuffer
            }
            let status = conv.convert(to: piece, error: &convError) { _, outStatus in
                switch inputStage {
                case 0: inputStage = 1; outStatus.pointee = .haveData; return raw
                case 1: inputStage = 2; outStatus.pointee = .haveData; return flushTail
                default: outStatus.pointee = .endOfStream; return nil
                }
            }
            guard status != .error, convError == nil else { throw StudioRenderError.cannotCreateBuffer }
            if piece.frameLength > 0 { appendPCM(piece, to: out) }
            if status == .endOfStream { break }
            if piece.frameLength == 0 { break }   // defensive: no progress — never spin
        }
        // Truncate the silence tail's contribution: exactly the resampled real signal remains.
        out.frameLength = min(out.frameLength, AVAudioFrameCount(expected))
        return out
    }

    /// Append `piece` onto `out` (same format), clamped to `out`'s capacity — the accumulation
    /// step of the pull-until-end-of-stream conversion above.
    private nonisolated static func appendPCM(_ piece: AVAudioPCMBuffer, to out: AVAudioPCMBuffer) {
        guard let src = piece.floatChannelData, let dst = out.floatChannelData else { return }
        let have = Int(out.frameLength)
        let add = min(Int(piece.frameLength), Int(out.frameCapacity) - have)
        guard add > 0 else { return }
        for c in 0..<Int(out.format.channelCount) {
            memcpy(dst[c] + have, src[c], add * MemoryLayout<Float>.size)
        }
        out.frameLength = AVAudioFrameCount(have + add)
    }

    // MARK: - Offline chain (mirrors StudioEngine's sample-audition graph)

    private struct OfflineChain {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
    }

    /// Build the offline sample chain — `player → inputMixer → timePitch → EQ(globalGain) →
    /// reverb → delay → mainMixer`, exactly the audition topology, with `player → inputMixer`
    /// at the FILE's format (the normalizer mixer converts; studio sources are heterogeneous)
    /// and everything downstream at canonical. Manual rendering is enabled BEFORE start (Apple's
    /// contract: the engine must be stopped), then the edit's voicing is applied through the
    /// SAME `StudioAudio.applyEditToChain` the live engine uses — audition and bake can't drift.
    private static func makeOfflineChain(fileFormat: AVAudioFormat, edit: StudioSampleEdit)
        throws -> OfflineChain {
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: canonicalFormat,
                                                  maximumFrameCount: chunkFrames) }
        catch { throw StudioRenderError.engineStart(error) }
        let player = AVAudioPlayerNode()
        let inputMixer = AVAudioMixerNode()
        let tp = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let rv = AVAudioUnitReverb()
        let dl = AVAudioUnitDelay()
        rv.loadFactoryPreset(.mediumHall)   // the same Studio reverb voicing as the live chain
        for n in [player, inputMixer, tp, eq, rv, dl] as [AVAudioNode] { engine.attach(n) }
        engine.connect(player, to: inputMixer, format: fileFormat)
        engine.connect(inputMixer, to: tp, format: canonicalFormat)
        engine.connect(tp, to: eq, format: canonicalFormat)
        engine.connect(eq, to: rv, format: canonicalFormat)
        engine.connect(rv, to: dl, format: canonicalFormat)
        engine.connect(dl, to: engine.mainMixerNode, format: canonicalFormat)
        StudioAudio.applyEditToChain(edit, timePitch: tp, eq: eq, reverb: rv, delay: dl)
        do { try engine.start() } catch { throw StudioRenderError.engineStart(error) }
        return OfflineChain(engine: engine, player: player, timePitch: tp)
    }

    /// The AU priming-latency head, in CANONICAL frames: timePitch's reported latency plus the
    /// engine's render (output-node) latency. These frames are dropped from the front of the
    /// stream so frame 0 of the written file is MUSICAL frame 0 (spec §4 — an untrimmed head
    /// puts silence at the top of every bake and beat-sync dies).
    private static func primingHeadFrames(_ chain: OfflineChain) -> Int64 {
        let sec = chain.timePitch.auAudioUnit.latency
            + chain.engine.outputNode.auAudioUnit.latency
        return max(0, Int64((sec * canonicalSampleRate).rounded()))
    }

    // MARK: - Fire-and-forget scheduling (synchronous by design)

    /// Schedule a file segment for offline pull. Deliberately the completion-handler overload —
    /// NOT the `async` variant the concurrency checker suggests in the `async` render bodies:
    /// awaiting that suspends until the segment finishes PLAYING, but here we schedule and then
    /// immediately `renderOffline` faster than realtime. Kept in a synchronous helper so the
    /// (inapplicable) async-alternative suggestion never fires at the call sites.
    private nonisolated static func scheduleSegment(_ file: AVAudioFile, on player: AVAudioPlayerNode,
                                                    startingFrame: AVAudioFramePosition,
                                                    frameCount: AVAudioFrameCount) {
        player.scheduleSegment(file, startingFrame: startingFrame, frameCount: frameCount,
                               at: nil, completionHandler: nil)
    }

    /// Schedule one sequencer step buffer (`.interrupts` mono-choke) for offline pull. Same
    /// rationale as `scheduleSegment(_:on:...)` — the synchronous completion-handler overload.
    private nonisolated static func scheduleStep(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                                                 at time: AVAudioTime) {
        player.scheduleBuffer(buffer, at: time, options: .interrupts, completionHandler: nil)
    }

    /// Schedule a whole buffer from the player's time 0 (the stretch bake's single source).
    /// Same synchronous-overload rationale as the helpers above.
    private nonisolated static func scheduleWhole(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Copy `frames` frames starting at `from` out of a buffer — the bounce's loop-phase
    /// continuation piece (`trimmedOrPadded` only cuts from frame 0). nil on a bad window or
    /// a non-float buffer; never zero-pads (callers size the window from the buffer).
    private nonisolated static func sliceBuffer(_ buffer: AVAudioPCMBuffer, from: Int64,
                                                frames: Int64) -> AVAudioPCMBuffer? {
        guard from >= 0, frames > 0, from + frames <= Int64(buffer.frameLength),
              frames <= Int64(UInt32.max),
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for c in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[c], src[c] + Int(from), Int(frames) * MemoryLayout<Float>.size)
        }
        out.frameLength = AVAudioFrameCount(frames)
        return out
    }

    // MARK: - Pull → trim head → write → drain tail

    /// The shared offline pump. Pulls `skipHead + nominal` frames (writing everything past the
    /// head), then — for samples/bounces — keeps draining in 512-frame windows until one falls
    /// below −60 dBFS RMS or the 3 s cap trips. Loops pass `drainTail: false` and get EXACTLY
    /// `nominal` frames (the engine renders silence past the schedule, so a short source is
    /// zero-padded for free). Returns the frames actually written.
    private static func pullAndWrite(engine: AVAudioEngine, to out: AVAudioFile,
                                     skipHead: Int64, nominal: Int64, drainTail: Bool) throws -> Int64 {
        let fmt = engine.manualRenderingFormat
        guard let render = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames),
              let scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else {
            throw StudioRenderError.cannotCreateBuffer
        }
        var pulled: Int64 = 0
        var written: Int64 = 0
        let phase1Target = skipHead + nominal
        while pulled < phase1Target {
            let want = AVAudioFrameCount(min(Int64(chunkFrames), phase1Target - pulled))
            let status = try engine.renderOffline(want, to: render)
            guard status == .success, render.frameLength > 0 else { break }   // offline should never stall — bail, never spin
            let dropFront = Int(max(0, min(Int64(render.frameLength), skipHead - pulled)))
            try writeSlice(render, from: dropFront, to: out, scratch: scratch)
            written += Int64(render.frameLength) - Int64(dropFront)
            pulled += Int64(render.frameLength)
        }
        guard drainTail else { return written }
        let cap = Int64(tailCapSeconds * fmt.sampleRate)
        var tail: Int64 = 0
        while tail < cap {
            let status = try engine.renderOffline(tailWindowFrames, to: render)
            guard status == .success, render.frameLength > 0 else { break }
            try writeSlice(render, from: 0, to: out, scratch: scratch)
            written += Int64(render.frameLength)
            tail += Int64(render.frameLength)
            if isBelowFloor(render, floorDb: tailFloorDb) { break }   // FX tail fully decayed
        }
        return written
    }

    /// The buffer-out sibling of `pullAndWrite`: pull `skipHead + count` frames from an offline
    /// engine, drop the head, and return EXACTLY `count` frames of canonical PCM (a source that
    /// runs short is zero-padded — fresh buffer memory is NOT guaranteed zeroed). For callers
    /// that feed a schedule directly (span stretches) rather than a file.
    private static func pullFrames(engine: AVAudioEngine, skipHead: Int64, count: Int64)
        throws -> AVAudioPCMBuffer {
        let fmt = engine.manualRenderingFormat
        guard count > 0, count <= Int64(UInt32.max),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
              let render = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames),
              let dst = out.floatChannelData else {
            throw StudioRenderError.cannotCreateBuffer
        }
        var pulled: Int64 = 0
        var written: Int64 = 0
        let target = skipHead + count
        while pulled < target, written < count {
            let want = AVAudioFrameCount(min(Int64(chunkFrames), target - pulled))
            let status = try engine.renderOffline(want, to: render)
            guard status == .success, render.frameLength > 0,        // offline should never stall — bail, never spin
                  let src = render.floatChannelData else { break }
            let dropFront = Int(max(0, min(Int64(render.frameLength), skipHead - pulled)))
            let copy = Int(min(Int64(render.frameLength) - Int64(dropFront), count - written))
            if copy > 0 {
                for c in 0..<Int(fmt.channelCount) {
                    memcpy(dst[c] + Int(written), src[c] + dropFront, copy * MemoryLayout<Float>.size)
                }
                written += Int64(copy)
            }
            pulled += Int64(render.frameLength)
        }
        if written < count {
            for c in 0..<Int(fmt.channelCount) {
                memset(dst[c] + Int(written), 0, Int(count - written) * MemoryLayout<Float>.size)
            }
        }
        out.frameLength = AVAudioFrameCount(count)
        return out
    }

    /// Append `buffer[from...]` to the file. The full-buffer case writes directly; a head-trimmed
    /// slice is copied through `scratch` first because `AVAudioFile.write(from:)` always writes
    /// from frame 0.
    private static func writeSlice(_ buffer: AVAudioPCMBuffer, from: Int, to out: AVAudioFile,
                                   scratch: AVAudioPCMBuffer) throws {
        let total = Int(buffer.frameLength)
        guard from < total else { return }                        // whole chunk inside the head
        if from == 0 { try out.write(from: buffer); return }
        let count = total - from
        guard let src = buffer.floatChannelData, let dst = scratch.floatChannelData else {
            throw StudioRenderError.cannotCreateBuffer
        }
        for c in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[c], src[c] + from, count * MemoryLayout<Float>.size)
        }
        scratch.frameLength = AVAudioFrameCount(count)
        try out.write(from: scratch)
    }

    /// Is this whole buffer's RMS below `floorDb` dBFS? Pure — the tail-drain stop condition
    /// (and unit-testable in isolation). An unreadable/empty buffer counts as silence.
    nonisolated static func isBelowFloor(_ buffer: AVAudioPCMBuffer, floorDb: Double) -> Bool {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return true }
        let n = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        var sum = 0.0
        for c in 0..<ch {
            let p = data[c]
            for i in 0..<n { sum += Double(p[i]) * Double(p[i]) }
        }
        let rms = (sum / Double(n * ch)).squareRoot()
        return rms < pow(10.0, floorDb / 20.0)
    }

    // MARK: - Atomic output (the failure-latch discipline)

    /// AAC `.m4a` — sample renders, pattern bounces, take audio (spec §4): 44.1 kHz stereo
    /// ~192 kbps.
    private static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: canonicalSampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    /// LPCM CAF Float32 — loops only (seamless: no encoder priming/padding, exact frame counts).
    private static let cafSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: canonicalSampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Write via a hidden temp sibling + atomic move: a THROWING render never leaves a partial
    /// file at `destURL` (the MixTapSink failure-latch discipline, transplanted). The temp name
    /// keeps the destination's extension (AVAudioFile infers the container from it) and starts
    /// with a dot + non-family prefix so the strict `StudioFolders.fileId` parser can never
    /// mistake a crashed render's leftover for a real artifact. The `AVAudioFile` var is nil-ed
    /// BEFORE the move — closing on dealloc is what flushes the m4a's moov atom; moving first
    /// would ship a truncated container.
    private static func writeAtomically(to dest: URL, settings: [String: Any],
                                        _ body: (AVAudioFile) throws -> Int64) throws -> Int64 {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".studio-render-\(UUID().uuidString)-\(dest.lastPathComponent)")
        try? FileManager.default.removeItem(at: tmp)
        do {
            var file: AVAudioFile? = try AVAudioFile(forWriting: tmp, settings: settings)
            let frames = try body(file!)
            file = nil                      // finalize the container BEFORE the move
            try? FileManager.default.removeItem(at: dest)   // replace an older render
            try FileManager.default.moveItem(at: tmp, to: dest)
            return frames
        } catch {
            try? FileManager.default.removeItem(at: tmp)    // no partial file survives a throw
            throw error
        }
    }
}
