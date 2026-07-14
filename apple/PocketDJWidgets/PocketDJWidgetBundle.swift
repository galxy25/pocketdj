import WidgetKit
import SwiftUI

/// The widget extension's entry point. One bundle, one widget today (Now Playing) — add
/// more `Widget`s here later (e.g. a "Jump back in" recents widget).
@main
struct PocketDJWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
