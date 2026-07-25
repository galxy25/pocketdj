import Foundation
import AVFoundation

/// Bounces a set of arranger tracks into ONE master clip (`clip-<id>.m4a`) by summing their clips
/// sample-for-sample at their timeline positions — the `carveStemMix`/`addBuffer` mixdown, not an
/// offline engine, because arranger clips are already-baked canonical snapshots with NO per-clip
/// DSP, so a straight scaled sum IS the mix. Per-track GAIN is applied; mute/solo are live-monitor
/// aids only and don't affect a bounce (you choose which tracks to bounce). A peak-limit prevents
/// summing overflow. Runs the decode + sum + write off the main actor.
@MainActor
enum ArrangerBouncer {
    /// Cap the master length so a runaway timeline can't allocate an unbounded accumulator.
    private static let maxSeconds = 30 * 60

    private typealias MixJob = (gain: Float, panL: Float, panR: Float, startFrame: Int64,
                                srcStart: Int64, len: Int64, url: URL)

    /// Resolve the tracks into per-clip mix jobs + the master length, or nil when nothing resolves /
    /// the timeline is absurdly long. Shared by both bounce entry points so gain/pan handling can't
    /// drift between "bounce to a clip" and "bounce to an artifact file".
    private static func plan(tracks: [StudioTrack], store: StudioStore) -> (jobs: [MixJob], totalFrames: Int64)? {
        let sr = StudioAudio.canonicalSampleRate
        var jobs: [MixJob] = []
        var totalFrames: Int64 = 0
        for track in tracks {
            let db = min(6.0, max(-24.0, track.gainDb))
            let gain = Float(pow(10.0, db / 20.0))
            // Center-unity balance: pan 0 leaves both channels at full; a hard pan silences the
            // opposite channel. Same direction the live AVAudioMixerNode.pan moves the sound.
            let p = min(1.0, max(-1.0, track.pan))
            let panL = Float(p <= 0 ? 1.0 : 1.0 - p)
            let panR = Float(p >= 0 ? 1.0 : 1.0 + p)
            for clip in track.clips {
                guard let url = store.clipFileURL(clip.fileName) else { continue }
                let startFrame = Int64((Double(clip.startMs) / 1000 * sr).rounded())
                // Non-destructive scissor window: read [srcStart, srcStart+len) from the file.
                let srcStart = max(0, Int64((Double(clip.fileStartMs) / 1000 * sr).rounded()))
                let len = Int64((Double(clip.durationMs) / 1000 * sr).rounded())
                let endFrame = startFrame + len
                jobs.append((gain, panL, panR, startFrame, srcStart, len, url))
                totalFrames = max(totalFrames, endFrame)
            }
        }
        guard !jobs.isEmpty, totalFrames > 0, totalFrames < Int64(maxSeconds) * Int64(sr) else { return nil }
        return (jobs, totalFrames)
    }

    /// Returns a ready-to-file master `StudioClip` (audio already written), positioned at `startMs`,
    /// or nil when the tracks hold no resolvable clips. The caller files it onto a new master track.
    /// (Retained for "Add as track"-style flows; the Bounce button writes an artifact via `bounceToFile`.)
    static func bounce(tracks: [StudioTrack], store: StudioStore, name: String, startMs: Int = 0,
                       masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120) async -> StudioClip? {
        guard let p = plan(tracks: tracks, store: store) else { return nil }
        let clipId = StudioFactory.newClipId()
        let fileName = StudioStore.clipFileName(clipId)
        guard let dir = try? StudioStore.arrangementsDir() else { return nil }
        let dest = dir.appendingPathComponent(fileName)
        guard let durationMs = await render(plan: p, masterFX: masterFX, bpm: bpm, to: dest),
              durationMs > 0 else { return nil }
        return StudioClip(id: clipId, name: name, fileName: fileName, startMs: max(0, startMs),
                          durationMs: durationMs, source: .master, sourceId: nil,
                          createdAt: Date().timeIntervalSince1970 * 1000)
    }

    /// Bounce straight to a caller-provided file URL (a dated artifact in the arrangements dir),
    /// returning the master length in ms — the artifact-only Bounce path. No clip/track is created.
    static func bounceToFile(tracks: [StudioTrack], store: StudioStore, to dest: URL,
                             masterFX: StudioMasterFX = StudioMasterFX(), bpm: Double = 120) async -> Int? {
        guard let p = plan(tracks: tracks, store: store) else { return nil }
        guard let durationMs = await render(plan: p, masterFX: masterFX, bpm: bpm, to: dest),
              durationMs > 0 else { return nil }
        return durationMs
    }

    /// Off-main mix + master-FX + write for a resolved plan. Freeze is a live-only hold → bypassed.
    private static func render(plan: (jobs: [MixJob], totalFrames: Int64),
                               masterFX: StudioMasterFX, bpm: Double, to dest: URL) async -> Int? {
        let fxParams = MasterFXParams(masterFX, bpm: bpm, allowFreeze: false)
        let jobs = plan.jobs
        let frames = plan.totalFrames
        return await Task.detached(priority: .userInitiated) {
            mixAndWrite(jobs: jobs, totalFrames: frames, to: dest, fx: fxParams)
        }.value
    }

    /// Off-main: allocate a canonical accumulator, add each clip (decoded canonical) at its start
    /// frame scaled by its track gain, peak-limit, write AAC. Returns the master length in ms.
    nonisolated private static func mixAndWrite(jobs: [(gain: Float, panL: Float, panR: Float, startFrame: Int64,
                                                        srcStart: Int64, len: Int64, url: URL)],
                                                totalFrames: Int64, to dest: URL, fx: MasterFXParams) -> Int? {
        let fmt = StudioAudio.canonicalFormat
        let total = Int(totalFrames)
        guard total > 0, let acc = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)),
              let accData = acc.floatChannelData else { return nil }
        acc.frameLength = AVAudioFrameCount(total)
        let channels = Int(fmt.channelCount)
        for ch in 0..<channels { memset(accData[ch], 0, total * MemoryLayout<Float>.size) }

        for job in jobs {
            guard let buf = try? StudioRender.decodeFileSync(url: job.url),
                  buf.frameLength > 0, let src = buf.floatChannelData else { continue }
            let srcCh = Int(buf.format.channelCount)
            let n = Int(buf.frameLength)
            let srcStart = max(0, min(n, Int(job.srcStart)))     // in-file window start (clamped)
            let avail = n - srcStart
            let want = job.len > 0 ? Int(job.len) : avail
            let start = Int(job.startFrame)
            guard start < total, avail > 0 else { continue }
            let count = min(want, avail, total - start)
            guard count > 0 else { continue }
            for ch in 0..<channels {
                let s = src[min(ch, srcCh - 1)]
                let d = accData[ch]
                let g = job.gain * (ch == 0 ? job.panL : job.panR)   // channel 0 = L, 1 = R
                for i in 0..<count { d[start + i] += s[srcStart + i] * g }
            }
        }

        // Master FX (WYSIWYG with live): run the SAME kernel over the summed master. Freeze is
        // already bypassed in `fx`; master gain is applied inside the kernel.
        if fx.active {
            let kernel = MasterFXKernel()
            kernel.configure(sampleRate: fmt.sampleRate, channelCount: channels)
            kernel.update(fx)
            kernel.processFloatChannels(accData, channelCount: channels, frames: total, framePos: 0)
        }

        // Peak-limit so summed overlaps / master gain never clip.
        var peak: Float = 0
        for ch in 0..<channels {
            let d = accData[ch]
            for i in 0..<total { let a = abs(d[i]); if a > peak { peak = a } }
        }
        if peak > 1 {
            let inv = 1 / peak
            for ch in 0..<channels { let d = accData[ch]; for i in 0..<total { d[i] *= inv } }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
        guard let out = try? AVAudioFile(forWriting: dest, settings: settings) else { return nil }
        do { try out.write(from: acc) } catch { return nil }
        return Int(Double(total) / fmt.sampleRate * 1000)
    }
}
