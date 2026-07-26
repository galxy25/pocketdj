import Foundation
import AVFoundation

/// Bounces a set of arranger tracks into ONE master clip (`clip-<id>.m4a`) by summing their clips
/// sample-for-sample at their timeline positions. Arranger clips are already-baked canonical
/// snapshots, so a straight scaled sum IS the mix — EXCEPT for the per-track channel strip: pitch/
/// tempo warp each clip's audio and EQ/reverb/delay/chorus process each track's summed contribution.
/// Both are applied here IDENTICALLY to `MultitrackPlayer` (the two-read-path WYSIWYG invariant) so a
/// bounce matches what you heard. Per-track GAIN + pan are applied; mute/solo are live-monitor aids
/// only (you choose which tracks to bounce). A peak-limit prevents summing overflow. Runs the decode
/// + transform + sum + write off the main actor.
@MainActor
enum ArrangerBouncer {
    /// Cap the master length so a runaway timeline can't allocate an unbounded accumulator.
    private static let maxSeconds = 30 * 60

    /// One clip to bake into a track: its timeline start + the scissor window + the per-track pitch/
    /// tempo warp to apply (rate = tempoRatio, pitchCents = semitones×100). All Sendable value types /
    /// a URL so the plan can cross into the detached mix task (no AVAudioPCMBuffer crosses the boundary
    /// — buffers are decoded/warped INSIDE the task).
    private struct ClipJob: Sendable {
        let startFrame: Int64; let srcStart: Int64; let len: Int64; let url: URL
        let rate: Double; let pitchCents: Double
    }
    /// One track: mix scalars + its live channel-strip FX (EQ + reverb/delay/chorus) + its clips.
    private struct TrackJob: Sendable {
        let gain: Float; let panL: Float; let panR: Float; let fx: TrackFXParams; let clips: [ClipJob]
    }

    /// Resolve the tracks into per-track jobs. Shared by both bounce entry points so gain/pan/strip
    /// handling can't drift. `totalFrames` is NOT computed here — per-track tempo changes each clip's
    /// length, so the true master length is only known after the warp (computed in `mixAndWrite`).
    private static func plan(tracks: [StudioTrack], store: StudioStore, bpm: Double,
                             beatMatch: Bool) -> [TrackJob]? {
        let sr = StudioAudio.canonicalSampleRate
        let beatFrames = bpm > 0 ? 60.0 / bpm * sr : 0   // Beat Match: snap starts to this grid
        var jobs: [TrackJob] = []
        for track in tracks {
            let strip = track.strip.clamped()
            let db = min(6.0, max(-24.0, track.gainDb))
            let gain = Float(pow(10.0, db / 20.0))
            // Center-unity balance: pan 0 leaves both channels full; a hard pan silences the opposite.
            let p = min(1.0, max(-1.0, track.pan))
            let panL = Float(p <= 0 ? 1.0 : 1.0 - p)
            let panR = Float(p >= 0 ? 1.0 : 1.0 + p)
            var clips: [ClipJob] = []
            for clip in track.clips {
                guard let url = store.clipFileURL(clip.fileName) else { continue }
                // Beat-match warp + start-snap — the SAME ArrangerBeatMatch helpers as
                // MultitrackPlayer.play so a bounce matches playback exactly.
                let rate = ArrangerBeatMatch.rate(clipBpm: clip.grid?.bpm ?? 0, masterBpm: bpm,
                                                  tempoRatio: strip.tempoRatio, beatMatch: beatMatch)
                let startFrame = Int64(ArrangerBeatMatch.snappedStartFrame(
                    Int((Double(clip.startMs) / 1000 * sr).rounded()),
                    beatFrames: beatFrames, beatMatch: beatMatch))
                let srcStart = max(0, Int64((Double(clip.fileStartMs) / 1000 * sr).rounded()))
                let len = Int64((Double(clip.durationMs) / 1000 * sr).rounded())
                clips.append(ClipJob(startFrame: startFrame, srcStart: srcStart, len: len, url: url,
                                     rate: rate, pitchCents: strip.pitchSemitones * 100))
            }
            guard !clips.isEmpty else { continue }
            jobs.append(TrackJob(gain: gain, panL: panL, panR: panR,
                                 fx: TrackFXParams(strip, bpm: bpm), clips: clips))
        }
        return jobs.isEmpty ? nil : jobs
    }

    /// Returns a ready-to-file master `StudioClip` (audio already written), positioned at `startMs`,
    /// or nil when the tracks hold no resolvable clips. The caller files it onto a new master track.
    static func bounce(tracks: [StudioTrack], store: StudioStore, name: String, startMs: Int = 0,
                       masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120,
                       beatMatch: Bool = false) async -> StudioClip? {
        guard let jobs = plan(tracks: tracks, store: store, bpm: bpm, beatMatch: beatMatch) else { return nil }
        let clipId = StudioFactory.newClipId()
        let fileName = StudioStore.clipFileName(clipId)
        guard let dir = try? StudioStore.arrangementsDir() else { return nil }
        let dest = dir.appendingPathComponent(fileName)
        guard let durationMs = await render(jobs: jobs, masterFX: masterFX, bpm: bpm, to: dest),
              durationMs > 0 else { return nil }
        return StudioClip(id: clipId, name: name, fileName: fileName, startMs: max(0, startMs),
                          durationMs: durationMs, source: .master, sourceId: nil,
                          createdAt: Date().timeIntervalSince1970 * 1000)
    }

    /// Bounce straight to a caller-provided file URL (a dated artifact in the arrangements dir),
    /// returning the master length in ms — the artifact-only Bounce path. No clip/track is created.
    static func bounceToFile(tracks: [StudioTrack], store: StudioStore, to dest: URL,
                             masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120,
                             beatMatch: Bool = false) async -> Int? {
        guard let jobs = plan(tracks: tracks, store: store, bpm: bpm, beatMatch: beatMatch) else { return nil }
        guard let durationMs = await render(jobs: jobs, masterFX: masterFX, bpm: bpm, to: dest),
              durationMs > 0 else { return nil }
        return durationMs
    }

    /// Off-main decode + per-track warp/FX + master-FX + write. Freeze is a live-only hold → bypassed.
    private static func render(jobs: [TrackJob], masterFX: StudioMasterFX, bpm: Double, to dest: URL) async -> Int? {
        let fxParams = MasterFXParams(masterFX, bpm: bpm, allowFreeze: false)
        return await Task.detached(priority: .userInitiated) {
            await mixAndWrite(tracks: jobs, to: dest, fx: fxParams)
        }.value
    }

    /// Off-main: warp each clip (pitch/tempo, offline), sum per track, run the track's channel-strip FX
    /// over its summed buffer, then sum tracks into the master (gain/pan), master-FX, peak-limit, write.
    /// Returns the master length in ms.
    nonisolated private static func mixAndWrite(tracks: [TrackJob], to dest: URL, fx: MasterFXParams) async -> Int? {
        let fmt = StudioAudio.canonicalFormat
        let sr = fmt.sampleRate
        let channels = Int(fmt.channelCount)

        // Pass 1: decode each clip, warp its scissor window by the track's pitch/tempo (neutral ⇒ a
        // plain slice), and keep the resulting buffers grouped per track.
        var perTrack: [(gain: Float, panL: Float, panR: Float, fx: TrackFXParams, clips: [(Int64, AVAudioPCMBuffer)])] = []
        for tj in tracks {
            var cbs: [(Int64, AVAudioPCMBuffer)] = []
            for cj in tj.clips {
                guard let raw = try? StudioRender.decodeFileSync(url: cj.url), raw.frameLength > 0 else { continue }
                let n = Int64(raw.frameLength)
                let srcStart = max(0, min(n, cj.srcStart))
                let avail = n - srcStart
                let want = cj.len > 0 ? min(cj.len, avail) : avail
                guard want > 0 else { continue }
                guard let buf = try? await StudioRender.shared.transformBuffer(
                    raw, from: srcStart, frames: want, rate: cj.rate, pitchCents: cj.pitchCents),
                    buf.frameLength > 0 else { continue }
                cbs.append((cj.startFrame, buf))
            }
            if !cbs.isEmpty { perTrack.append((tj.gain, tj.panL, tj.panR, tj.fx, cbs)) }
        }

        // Master length = the furthest warped clip end across all tracks.
        var total: Int64 = 0
        for t in perTrack { for (sf, b) in t.clips { total = max(total, sf + Int64(b.frameLength)) } }
        let totalI = Int(total)
        guard totalI > 0, total < Int64(maxSeconds) * Int64(sr),
              let acc = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(totalI)),
              let accData = acc.floatChannelData else { return nil }
        acc.frameLength = AVAudioFrameCount(totalI)
        for ch in 0..<channels { memset(accData[ch], 0, totalI * MemoryLayout<Float>.size) }

        // Pass 2: per track — sum clips, run channel-strip FX (if any), add to master with gain/pan.
        for t in perTrack {
            if t.fx.active {
                guard let tb = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(totalI)),
                      let td = tb.floatChannelData else { continue }
                tb.frameLength = AVAudioFrameCount(totalI)
                for ch in 0..<channels { memset(td[ch], 0, totalI * MemoryLayout<Float>.size) }
                for (sf, b) in t.clips { addBuffer(b, into: td, at: Int(sf), total: totalI, channels: channels) }
                let kernel = TrackFXKernel()
                kernel.configure(sampleRate: sr, channelCount: channels)
                kernel.update(t.fx)
                kernel.processFloatChannels(td, channelCount: channels, frames: totalI)
                for ch in 0..<channels {
                    let g = t.gain * (ch == 0 ? t.panL : t.panR)
                    let d = accData[ch], s = td[ch]
                    for i in 0..<totalI { d[i] += s[i] * g }
                }
            } else {
                for (sf, b) in t.clips {
                    addBuffer(b, into: accData, at: Int(sf), total: totalI, channels: channels,
                              gain: t.gain, panL: t.panL, panR: t.panR)
                }
            }
        }

        // Master FX (WYSIWYG with live): the SAME kernel over the summed master. Freeze bypassed in fx.
        if fx.active {
            let kernel = MasterFXKernel()
            kernel.configure(sampleRate: sr, channelCount: channels)
            kernel.update(fx)
            kernel.processFloatChannels(accData, channelCount: channels, frames: totalI, framePos: 0)
        }

        // Peak-limit so summed overlaps / master gain never clip.
        var peak: Float = 0
        for ch in 0..<channels { let d = accData[ch]; for i in 0..<totalI { let a = abs(d[i]); if a > peak { peak = a } } }
        if peak > 1 {
            let inv = 1 / peak
            for ch in 0..<channels { let d = accData[ch]; for i in 0..<totalI { d[i] *= inv } }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
        guard let out = try? AVAudioFile(forWriting: dest, settings: settings) else { return nil }
        do { try out.write(from: acc) } catch { return nil }
        return Int(Double(totalI) / sr * 1000)
    }

    /// Add a (window-warped, plays-from-0) clip buffer into a destination at `startFrame`, optionally
    /// scaled by track gain/pan. Clamped to the destination length.
    nonisolated private static func addBuffer(_ b: AVAudioPCMBuffer,
                                              into dst: UnsafePointer<UnsafeMutablePointer<Float>>,
                                              at startFrame: Int, total: Int, channels: Int,
                                              gain: Float = 1, panL: Float = 1, panR: Float = 1) {
        guard let src = b.floatChannelData, startFrame < total else { return }
        let srcCh = Int(b.format.channelCount)
        let count = min(Int(b.frameLength), total - startFrame)
        guard count > 0 else { return }
        for ch in 0..<channels {
            let s = src[min(ch, srcCh - 1)]
            let d = dst[ch]
            let g = gain * (ch == 0 ? panL : panR)
            for i in 0..<count { d[startFrame + i] += s[i] * g }
        }
    }
}
