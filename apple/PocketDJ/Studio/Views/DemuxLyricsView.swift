import SwiftUI

/// Time-synced lyrics for the Demuxer: the transcript's words grouped into lines, the CURRENT
/// line auto-centered while playing, the already-sung words in each line highlighted karaoke-
/// style, and tap-a-line seeks there. The word highlight samples the player's host-clock
/// position inside a `TimelineView` (nothing observable ticks).
struct DemuxLyricsView: View {
    let words: [DemuxWord]
    let player: StemPlayer
    var onSeek: (Int) -> Void

    private var lines: [DemuxLine] { DemuxLine.lines(from: words) }

    var body: some View {
        let lines = self.lines
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let nowMs = Int(player.currentTime * 1_000)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lines) { line in
                            lineRow(line, nowMs: nowMs)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .accessibilityIdentifier("demux-lyrics")
            .task(id: lines.count) {
                // Auto-center the current line while playing (poll — currentTime isn't observed).
                var lastCentered = -1
                while !Task.isCancelled {
                    if player.isPlaying {
                        let nowMs = Int(player.currentTime * 1_000)
                        if let current = lines.last(where: { $0.startMs <= nowMs }),
                           current.id != lastCentered {
                            lastCentered = current.id
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(current.id, anchor: .center)
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    private func lineRow(_ line: DemuxLine, nowMs: Int) -> some View {
        let isCurrent = line.startMs <= nowMs && nowMs < line.endMs + 800
        return Button { onSeek(line.startMs) } label: {
            karaokeText(line, nowMs: nowMs, isCurrent: isCurrent)
                .font(isCurrent ? .callout.weight(.semibold) : .callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(line.id)
    }

    /// One `Text` of per-word styled runs — the karaoke fill. Built imperatively with explicit
    /// types (a `reduce` of `Text + Text` blows the type-checker budget).
    private func karaokeText(_ line: DemuxLine, nowMs: Int, isCurrent: Bool) -> Text {
        var t = Text(verbatim: "")
        for w in line.words {
            let color: Color = isCurrent ? (w.startMs <= nowMs ? Theme.accent : Theme.fg) : Theme.fgDim
            t = t + Text(w.text + " ").foregroundColor(color)
        }
        return t
    }
}
