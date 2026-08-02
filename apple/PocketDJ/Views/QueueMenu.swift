import SwiftUI

/// "Play Next" / "Play Last" — put an item into the RUNNING Now Playing session without
/// disturbing what is currently playing.
///
/// One component rather than four copies, because every surface that offers this has to make the
/// same three decisions identically:
///
///  • HIDDEN when no set is running. Not disabled — hidden. There is nothing to add to, and the
///    alternative (starting a session from a context menu) would double-start the sequencer via
///    `SetlistDetailView`'s `nowPlayingRevision` observer and could also cut off a single-row ▶,
///    which plays without ever setting `isRunning`. Same rule `BrowseDiscover`'s row menu follows.
///  • An ALBUM inserts in ONE call. Looping per track would land them reversed, since each insert
///    goes directly after the current row.
///  • Rows are minted FRESH every time (`Item` mints a new `uid` per instance). Queueing the same
///    song twice must produce two independently addressable rows — the uid is what the live-queue
///    edits, the Jukebox, and CarPlay's Up Next all key on.
enum QueueMenu {

    /// Catalog songs → live-queue rows, in order.
    @MainActor
    static func items(_ songs: [IndexSong]) -> [SetlistPlayer.Item] {
        songs.map { .init(id: $0.id, title: $0.name, artist: $0.artist, lengthMs: $0.length) }
    }
}

/// The menu body. Use inside an existing `.contextMenu {}` (never as a nested `Menu` — a row that
/// already owns a context menu must fold these in, see `ForceSyncMenu`'s note) or inside a `Menu`
/// for a toolbar/header button.
struct QueueMenuItems: View {
    @Environment(SetlistPlayer.self) private var sequencer
    /// What to queue. Empty ⇒ nothing renders.
    let songs: [IndexSong]
    /// Shown in the labels for a multi-track add ("Play Album Next"); nil ⇒ the plain wording.
    var noun: String?

    var body: some View {
        if sequencer.isRunning, !songs.isEmpty {
            Button {
                sequencer.insertNextInQueue(QueueMenu.items(songs))
            } label: {
                Label(noun.map { "Play \($0) Next" } ?? "Play Next",
                      systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .accessibilityIdentifier("queue-play-next")
            Button {
                sequencer.appendToQueue(QueueMenu.items(songs))
            } label: {
                Label(noun.map { "Play \($0) Last" } ?? "Play Last",
                      systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .accessibilityIdentifier("queue-play-last")
        }
    }
}
