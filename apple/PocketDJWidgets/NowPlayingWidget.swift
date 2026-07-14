import WidgetKit
import SwiftUI
import AppIntents

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Timeline

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    /// The current track's cover PNG bytes (loaded once per timeline, not in the view body).
    let coverData: Data?
}

struct NowPlayingProvider: TimelineProvider {
    /// Read the shared state + trace what THIS (widget) process actually sees — the app-side
    /// trace shows what was written; diffing the two pins down container/entitlement gaps.
    private func currentEntry() -> NowPlayingEntry {
        NPLog.processTag = "widget"
        let snap = NowPlayingShared.read()
        let cover = NowPlayingShared.readCoverData()
        NPLog.trace("timeline read title=\(snap.title) hasContent=\(snap.hasContent) playing=\(snap.isPlaying) coverV=\(snap.coverVersion) coverBytes=\(cover?.count ?? -1) groupOK=\(NowPlayingShared.defaults != nil) container=\(NowPlayingShared.containerURL?.path ?? "nil")")
        return NowPlayingEntry(date: Date(), snapshot: snap, coverData: cover)
    }

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .sample, coverData: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview
            ? NowPlayingEntry(date: Date(), snapshot: .sample, coverData: nil)
            : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // Single entry; the APP drives refreshes via WidgetCenter.reloadAllTimelines() whenever
        // the now-playing state changes, so there's no time-based schedule to keep.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }
}

// MARK: - Widget

struct NowPlayingWidget: Widget {
    let kind = "PocketDJNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Your current track and what's up next — with play, pause, and skip.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.snapshot.hasContent {
            IdleView()
        } else {
            switch family {
            case .systemSmall: SmallView(entry: entry)
            case .systemLarge: LargeView(entry: entry)
            default:           MediumView(entry: entry)
            }
        }
    }
}

/// Nothing playing — a calm placeholder rather than a blank tile.
private struct IdleView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Square cover with a subtle music-note fallback when no art has been written yet.
private struct Cover: View {
    let data: Data?
    var body: some View {
        ZStack {
            if let data, let img = platformCoverImage(data) {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TitleBlock: View {
    let title: String
    let artist: String
    var titleFont: Font = .headline
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(titleFont).fontWeight(.semibold).lineLimit(1)
            if !artist.isEmpty { Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// The ⏮ ⏯ ⏭ row — each is a `Button(intent:)` so a tap runs the AudioPlaybackIntent.
private struct TransportRow: View {
    let isPlaying: Bool
    var iconSize: CGFloat = 18
    var body: some View {
        HStack(spacing: 22) {
            Button(intent: NowPlayingPreviousIntent()) {
                Image(systemName: "backward.fill")
            }
            Button(intent: NowPlayingToggleIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            Button(intent: NowPlayingNextIntent()) {
                Image(systemName: "forward.fill")
            }
        }
        .font(.system(size: iconSize, weight: .semibold))
        .buttonStyle(.plain)
        .tint(.primary)
    }
}

private struct SmallView: View {
    let entry: NowPlayingEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cover(data: entry.coverData).frame(maxWidth: .infinity)
            TitleBlock(title: entry.snapshot.title, artist: entry.snapshot.artist, titleFont: .subheadline)
            HStack {
                Spacer()
                Button(intent: NowPlayingToggleIntent()) {
                    Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain).tint(.primary)
                Spacer()
                Button(intent: NowPlayingNextIntent()) {
                    Image(systemName: "forward.fill").font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain).tint(.primary)
                Spacer()
            }
        }
    }
}

private struct MediumView: View {
    let entry: NowPlayingEntry
    var body: some View {
        HStack(spacing: 12) {
            Cover(data: entry.coverData).aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                TitleBlock(title: entry.snapshot.title, artist: entry.snapshot.artist)
                if let up = entry.snapshot.upNext.first {
                    Text("Up next: \(up.title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                TransportRow(isPlaying: entry.snapshot.isPlaying)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LargeView: View {
    let entry: NowPlayingEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Cover(data: entry.coverData).frame(width: 84, height: 84)
                TitleBlock(title: entry.snapshot.title, artist: entry.snapshot.artist)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TransportRow(isPlaying: entry.snapshot.isPlaying, iconSize: 20)
                .frame(maxWidth: .infinity)

            if entry.snapshot.upNext.isEmpty {
                Spacer(minLength: 0)
            } else {
                Divider()
                Text("Up Next").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.snapshot.upNext.prefix(4)) { t in
                        HStack(spacing: 6) {
                            Text(t.title).font(.caption).lineLimit(1)
                            if !t.artist.isEmpty {
                                Text("· \(t.artist)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Cover decoding (platform image → SwiftUI Image)

private func platformCoverImage(_ data: Data) -> Image? {
    #if canImport(UIKit)
    return UIImage(data: data).map { Image(uiImage: $0) }
    #elseif canImport(AppKit)
    return NSImage(data: data).map { Image(nsImage: $0) }
    #else
    return nil
    #endif
}

// MARK: - Preview sample

extension NowPlayingSnapshot {
    static let sample = NowPlayingSnapshot(
        isPlaying: true, hasContent: true,
        title: "Midnight City", artist: "M83", songId: "sample",
        coverVersion: 0,
        upNext: [
            .init(id: "1", songId: "a", title: "Outro", artist: "M83"),
            .init(id: "2", songId: "b", title: "Reunion", artist: "M83"),
            .init(id: "3", songId: "c", title: "Wait", artist: "M83"),
        ])
}
