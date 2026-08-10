import Foundation

/// The vocabulary of the recommendation tuning loop, in `Shared/` because BOTH targets speak it:
/// the app records it (`RecFeedbackStore`) and the widget extension renders it off the App Group
/// snapshot (`NowPlayingSnapshot.recFeedback`).
///
/// It lives here rather than being duplicated as string literals on the widget side for the
/// reason every cross-process value in this app does: two copies of `"rejected"` is one typo away
/// from a widget that renders "untouched" for a track the user has explicitly thumbed down, and
/// the failure would be invisible in every unit test that only exercises the app target.
///
/// RAW VALUES ARE THE WIRE (`RecFeedbackWire.action`) and the on-disk document, so they are
/// FROZEN — the same rule `PlaySource` / `ActivityKind` / `RecModels` live under.
enum RecFeedbackAction: String, Codable, CaseIterable, Sendable {
    case accepted
    case rejected
    /// An explicit undo. Persisted as a row rather than by deleting the earlier one, so the log
    /// stays append-only (which is what makes the union-by-id CloudKit merge safe) and so the
    /// server can apply the same last-writer-wins fold the device does.
    case cleared

    /// What the App Group snapshot carries when a track has no decision. Deliberately NOT a case:
    /// "no decision" is the absence of a row, and giving it a case would let it be recorded.
    static let none = "none"

    /// SF Symbols. The owner settled the iconography: thumbs, everywhere, as a matched pair —
    /// never a thumb beside an xmark, and never an emoji (which would drag skin-tone rendering
    /// into a control that has to work at glyph size on a lock screen).
    static let acceptSymbol = "hand.thumbsup"
    static let acceptSymbolFilled = "hand.thumbsup.fill"
    static let rejectSymbol = "hand.thumbsdown"
    static let rejectSymbolFilled = "hand.thumbsdown.fill"
}
