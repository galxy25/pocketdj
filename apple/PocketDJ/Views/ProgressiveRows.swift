import SwiftUI

// MARK: - Progressive rows for very large collections
//
// A collection detail view can hold thousands of rows — the default "Recently added" list is
// 3,650, and a converted Apple Music playlist can be far larger. Handing that whole array to a
// `List`'s `ForEach` makes SwiftUI build identity and layout for every element up front, which
// is the bulk of the multi-second stall when opening such a collection (and, because Shuffle
// also raises the Now Playing panel's Up Next list, of the stall after tapping Shuffle).
//
// The fix is to render a WINDOW and grow it as the user scrolls: the first page paints
// immediately, and the rest streams in without ever blocking the main thread on the full set.
// This is deliberately a plain window rather than a `LazyVStack` swap — `List` is what gives
// these views their swipe actions, section styling and platform row chrome, and windowing keeps
// all of that while removing the O(all rows) construction cost.

extension BrowseState {
    /// True when nothing reorders or removes rows — no text query, no filter clauses, no sort
    /// keys, and no read-time (membership / favorite) filter. In that state a collection's
    /// displayed rows are exactly its stored ids in stored order, so a view can paint the first
    /// page straight from the catalog while the full pipeline resolves.
    var isStoredOrder: Bool {
        query.isEmpty && clauses.allSatisfy(\.isIncomplete) && sortKeys.isEmpty
            && !membershipActive && !favoriteActive
    }
}

/// How many rows a windowed collection list paints at a time. Sized to comfortably overfill the
/// tallest supported screen so the sentinel is never already on-screen when a page lands (which
/// would grow the window repeatedly within one frame).
enum RowWindow {
    static let page = 150
}

/// The row that grows a windowed list. It sits after the last rendered row; when it scrolls into
/// view there is more to show, so it extends the window by one page. It renders as a slim
/// progress indicator, which doubles as the "still loading" affordance the user sees while
/// scrolling a very long collection.
///
/// `shown` is clamped to `total`, so once the whole collection is rendered this view disappears
/// and stops firing.
struct RowWindowSentinel: View {
    let total: Int
    @Binding var shown: Int
    var page: Int = RowWindow.page

    var body: some View {
        if shown < total {
            HStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("\(total - shown) more").font(.caption).foregroundStyle(Theme.fgDim)
                Spacer()
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("row-window-sentinel")
            // `.onAppear` (not `.task`) so extending is a synchronous state write on the main
            // actor — the next page is laid out in the same update as the scroll that revealed
            // this row, which is what keeps the list from visibly stuttering at a page boundary.
            .onAppear { shown = min(shown + page, total) }
        }
    }
}
