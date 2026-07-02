import Foundation
import AppIntents

/// "Create a pocket in PocketDJ" → Siri asks for the brief ("optimistic soul, funk,
/// r&b or disco songs from 1960 to 1989") → the on-device Foundation model + a
/// deterministic catalog search build a pocket of up to `minutes` of songs, ASYNC:
/// the intent validates model availability, kicks the build off, and answers
/// immediately — the pocket appears in Pockets when the build lands (see
/// PocketBuilderService). Needs iOS 26 / macOS 26 Apple Intelligence; on older OS
/// the intent fails fast with a spoken reason.
struct CreatePocketIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Pocket"
    static let description = IntentDescription("""
        Builds a new pocket from a description of the vibe — mood words, genres, and \
        a year range — using on-device intelligence to pick songs from your sources.
        """)

    @Parameter(title: "Brief",
               description: "The vibe to build from, e.g. “optimistic soul, funk, r&b or disco songs from 1960 to 1989”.",
               requestValueDialog: "What kind of pocket should I build?")
    var brief: String

    @Parameter(title: "Minutes of music", default: 90, controlStyle: .field, inclusiveRange: (10, 600))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Create a pocket for \(\.$brief)") { \.$minutes }
    }

    @Dependency private var services: IntentServices

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $brief.needsValueError("What kind of pocket should I build?")
        }
        try await services.createPocket(brief: trimmed, targetMinutes: minutes)
        return .result(dialog: "On it — building a pocket for “\(trimmed)”. It'll show up in Pockets shortly.")
    }
}
