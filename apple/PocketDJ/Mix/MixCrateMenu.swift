import SwiftUI

/// The Mix crate picker (Auto Crate A / Crate B, each deck's source menu, the loader sheet).
///
/// EQUATABLE ON PURPOSE. Picking a crate starts its download run, and the run's progress
/// re-renders the whole Mix screen several times a second. A SwiftUI `Menu` whose body is
/// re-evaluated while it is OPEN is rebuilt by the system — on iPhone that snaps its list back
/// to the top, so the NEXT crate could never be scrolled to and picked (Levi, 2026-10-25).
/// This view only re-renders when what it SHOWS changes (the entries or the label text); the
/// pick closure is deliberately left out of equality.
struct MixCrateMenu<MenuLabel: View>: View, Equatable {
    typealias Entry = MixCrateEntry

    let entries: [Entry]
    /// A leading reset choice ("Same as Crate A"); nil ⇒ none.
    var resetTitle: String? = nil
    /// The label's visible text — part of equality so a pick still updates the label.
    let labelText: String
    let onPick: (MixSource?) -> Void
    @ViewBuilder let label: () -> MenuLabel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.entries == b.entries && a.resetTitle == b.resetTitle && a.labelText == b.labelText
    }

    var body: some View {
        Menu {
            if let resetTitle { Button(resetTitle) { onPick(nil) } }
            if entries.isEmpty { Text("No pockets, playlists, or set lists yet") }
            ForEach(Self.sections(entries), id: \.self) { section in
                Section(section) {
                    ForEach(entries.filter { $0.section == section }) { e in
                        Button(e.name) { onPick(e.source) }
                    }
                }
            }
        } label: { label() }
    }

    /// Section titles in first-appearance order.
    static func sections(_ entries: [Entry]) -> [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.section) { seen.append(e.section) }
        return seen
    }
}

/// One pickable crate.
struct MixCrateEntry: Equatable, Identifiable {
    let section: String
    let name: String
    let source: MixSource
    var id: String { "\(section)|\(name)|\(source)" }
}

extension MixCrateEntry {
    /// Every crate the Mix can pull from, A–Z within Pockets · Playlists · Set lists.
    @MainActor static func all(_ collections: CollectionsStore) -> [Self] {
        collections.pocketsAZ.map { .init(section: "Pockets", name: $0.name, source: .pocket($0.id)) }
        + collections.playlistsAZ.map { .init(section: "Playlists", name: $0.name, source: .playlist($0.id)) }
        + collections.visibleSetlistsAZ.map { .init(section: "Set lists", name: $0.name ?? "Set list", source: .setlist($0.id)) }
    }
}
