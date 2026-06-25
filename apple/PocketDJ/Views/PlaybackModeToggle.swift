import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Item 7 — the global device ⇄ cloud PLAYBACK-MODE toggle, styled like the browser's
/// on-device/online search toggle (a cloud glyph vs. the current-device glyph). Flips
/// `SettingsStore.playbackMode`:
///   • `.cloud`  — stream every track (Apple Music → rip-on-demand), today's behaviour.
///   • `.device` — play from BURNED local files (a single-row tap falls back to cloud for
///     a missing file; the sequencer SKIPS a track with no on-device file).
///
/// Dropped onto the Setlist / Playlist / Pocket detail toolbars. It's a single toolbar
/// button (no overflow risk) — the same footprint as the browser's `search-mode` toggle.
struct PlaybackModeToggle: View {
    @Environment(SettingsStore.self) private var settings

    /// SF Symbol for the current device — shown when playing FROM the device (burned files).
    private var deviceIcon: String {
        #if os(macOS)
        "macbook"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    var body: some View {
        let device = settings.playbackMode == .device
        Button {
            settings.playbackMode = device ? .cloud : .device
            settings.persist()
        } label: {
            Image(systemName: device ? deviceIcon : "cloud")
        }
        .accessibilityIdentifier("playback-mode")
        .help(device ? "Play from burned files" : "Cloud streaming")
    }
}
