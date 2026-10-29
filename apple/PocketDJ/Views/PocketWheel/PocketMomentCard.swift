#if !os(tvOS)
import SwiftUI

/// The detail card for one wheel cell (§2.5): its moment, its collections as coloured bars, top
/// artists / genres, BPM band, place/trip chips (re-labelled on device), plays + skip rate,
/// ▶ Play this pocket, "Why this colour", and the run history that shows learning happening.
struct PocketMomentCard: View {
    let moment: PocketMoment
    let names: [String: String]
    let palette: PocketPaletteStore
    let location: ListeningLocationStore?
    let actions: PocketWheelActions
    let onClose: () -> Void

    @State private var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            collectionBars
            featureRows
            if !placeChips.isEmpty { chips(placeChips) }
            stats
            if let play = actions.playMoment {
                Button { play(moment.key) } label: {
                    Label("Play this pocket", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pocket-card-play")
            }
            DisclosureGroup("Why this colour", isExpanded: $showWhy) {
                Text(whyText).font(.caption).foregroundStyle(Theme.fgDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.caption.weight(.semibold))
            .tint(Theme.fgDim)
            .accessibilityIdentifier("pocket-card-why")
            runHistory
        }
        .padding(14)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket-card")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: moment.key.mode.symbol).foregroundStyle(Theme.fgDim)
            Text(moment.key.longLabel).font(.headline).foregroundStyle(Theme.fg)
                .accessibilityIdentifier("pocket-card-title")
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.fgDim) }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("pocket-card-close")
        }
    }

    private var sortedCollections: [(id: String, share: Double)] {
        moment.collections.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    @ViewBuilder private var collectionBars: some View {
        if sortedCollections.isEmpty {
            Text("No collection yet — these were singles.").font(.caption).foregroundStyle(Theme.fgDim)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sortedCollections.prefix(4), id: \.id) { c in
                    HStack(spacing: 8) {
                        Text(names[c.id] ?? "Collection").font(.caption).foregroundStyle(Theme.fg)
                            .frame(width: 110, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.bgOverlay)
                                Capsule().fill(palette.swatch(for: c.id).color(dark: true))
                                    .frame(width: max(4, g.size.width * c.share))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int((c.share * 100).rounded())) %").font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.fgDim).frame(width: 36, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder private var featureRows: some View {
        let artists = moment.artists.sorted { $0.value > $1.value }.prefix(3).map { $0.key.capitalized }
        let genres = moment.genres.sorted { $0.value > $1.value }.prefix(3).map { InThePocketScorer.genreLabel($0.key) }
        VStack(alignment: .leading, spacing: 4) {
            if !artists.isEmpty { row("Artists", artists.joined(separator: ", ")) }
            if !genres.isEmpty { row("Genres", genres.joined(separator: ", ")) }
            if let b = moment.bpmBand { row("Tempo", "\(Int(b.lowerBound))–\(Int(b.upperBound)) BPM") }
            if let e = moment.era { row("Era", "\(Int(e.lo.rounded()))–\(Int(e.hi.rounded()))") }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(Theme.fgDim).frame(width: 60, alignment: .leading)
            Text(v).font(.caption).foregroundStyle(Theme.fg).lineLimit(2)
        }
    }

    /// Place / trip chips re-labelled on device ("Location A", "A → B"); unknown ids read
    /// "Earlier place". "none" isn't a chip.
    private var placeChips: [String] {
        moment.ctx.sorted { $0.value > $1.value }.compactMap { key, _ -> String? in
            if key == "none" { return nil }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let tag = parts[0] == "trip" ? ListeningContextTag(kind: "trip", tripId: parts[1], origin: "?")
                                         : ListeningContextTag.place(parts[1])
            return location?.label(for: tag) ?? (parts[0] == "trip" ? "A trip" : "Earlier place")
        }.prefix(3).map { $0 }
    }

    private func chips(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.caption2).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.bgOverlay, in: Capsule()).foregroundStyle(Theme.fg)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("\(moment.directPlays)", "plays")
            stat("\(Int((moment.skipRate * 100).rounded())) %", "skips")
            stat(moment.isRecurring ? "\(moment.distinctDays) days" : "once", moment.isRecurring ? "recurring" : "one-off")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket-card-stats")
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.fg)
            Text(l).font(.caption2).foregroundStyle(Theme.fgDim)
        }
    }

    private var whyText: String {
        guard let d = moment.dominantCollectionId else {
            return "No single playlist or pocket made up a quarter of what you played here, so this cell is drawn as mixed."
        }
        let name = names[d] ?? "This collection"
        let pct = Int(((moment.collections[d] ?? 0) * 100).rounded())
        var s = "\(name) is where \(pct) % of the music you played here came from"
        s += moment.isRecurring ? ", across \(moment.distinctDays) different days." : ". It happened once, so it's drawn paler."
        s += " Colours are assigned automatically and stay the same on all your devices."
        return s
    }

    @ViewBuilder private var runHistory: some View {
        if let rows = actions.runHistory?(moment.key), !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Past runs").font(.caption.weight(.semibold)).foregroundStyle(Theme.fgDim)
                ForEach(rows.prefix(5)) { r in
                    HStack {
                        Text(r.label).font(.caption).foregroundStyle(Theme.fg)
                        Spacer()
                        Text("\(r.playedThrough) played · \(Int((r.skipRate * 100).rounded())) % skipped")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                    }
                }
            }
            .accessibilityIdentifier("pocket-card-runs")
        }
    }
}

/// The legend (§2.4): each colour, its collection, and its share of the week. Tapping a chip
/// highlights that collection's cells and dims the rest.
struct PocketWheelLegend: View {
    let snapshot: PocketWheelSnapshot
    @Binding var highlighted: String?
    @Environment(PocketPaletteStore.self) private var palette

    var body: some View {
        let ids = snapshot.dominanceOrder
        if !ids.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        let on = highlighted == id
                        Button { highlighted = on ? nil : id } label: {
                            HStack(spacing: 6) {
                                Circle().fill(palette.swatch(for: id).color(dark: true)).frame(width: 10, height: 10)
                                Text(snapshot.collectionNames[id] ?? "Collection").font(.caption)
                                Text("\(Int(((snapshot.weekShare[id] ?? 0) * 100).rounded())) %")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(Theme.fgDim)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Theme.bgOverlay : Theme.bgRaised, in: Capsule())
                            .overlay(Capsule().stroke(on ? Theme.fg : Theme.border))
                            .foregroundStyle(Theme.fg)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("pocket-legend-\(id)")
                    }
                }
            }
            .accessibilityIdentifier("pocket-wheel-legend")
        }
    }
}

/// VoiceOver for the Canvas (§2.7): 7 adjustable elements (one per weekday ring). Swipe up/down
/// moves through the hours; the value names the cell's modes, collections, plays and skips;
/// double-tap opens the card.
struct PocketWheelAccessibility: View {
    let layout: WheelLayout
    let index: [PocketMomentKey: PocketMoment]
    let names: [String: String]
    let onOpen: (PocketMomentKey) -> Void

    var body: some View {
        VStack {
            ForEach(1...7, id: \.self) { dow in
                PocketWheelRingA11y(dow: dow, layout: layout, index: index, names: names, onOpen: onOpen)
            }
        }
    }

    /// The spoken value for one (day, hour) cell.
    static func value(dow: Int, hour: Int, layout: WheelLayout, index: [PocketMomentKey: PocketMoment],
                      names: [String: String]) -> String {
        let h = PocketMomentKey.hourLabel(hour)
        guard let cell = layout.cell(dow: dow, hour: hour), !cell.slivers.isEmpty else { return "\(h), nothing yet" }
        let parts = cell.slivers.compactMap { s -> (Double, String)? in
            guard let m = index[s.key] else { return nil }
            let coll = m.dominantCollectionId.flatMap { names[$0] } ?? "mixed"
            let skip = Int((m.skipRate * 100).rounded())
            return (m.plays, "\(s.key.mode.label): \(coll), \(m.directPlays) plays, \(skip)% skips")
        }.sorted { $0.0 > $1.0 }.map(\.1)
        guard let first = parts.first else { return "\(h), nothing yet" }
        return "\(h), " + first + (parts.count > 1 ? "; also " + parts.dropFirst().joined(separator: "; ") : "")
    }

    /// Hours with a recurring pocket on this ring (the "Recurring pockets" rotor).
    static func recurringHours(dow: Int, layout: WheelLayout, index: [PocketMomentKey: PocketMoment]) -> [Int] {
        layout.cells.filter { $0.dow == dow && $0.slivers.contains { index[$0.key]?.isRecurring == true } }.map(\.hour)
    }
}

private struct PocketWheelRingA11y: View {
    let dow: Int
    let layout: WheelLayout
    let index: [PocketMomentKey: PocketMoment]
    let names: [String: String]
    let onOpen: (PocketMomentKey) -> Void
    @State private var hour = PocketClock.local(atMs: Date().timeIntervalSince1970 * 1000,
                                                tzOffsetMin: TimeZone.current.secondsFromGMT() / 60).hour

    var body: some View {
        let recurring = PocketWheelAccessibility.recurringHours(dow: dow, layout: layout, index: index)
        Text(PocketMomentKey.weekdayNames[dow - 1])
            .accessibilityElement()
            .accessibilityLabel(PocketMomentKey.weekdayNames[dow - 1])
            .accessibilityValue(PocketWheelAccessibility.value(dow: dow, hour: hour, layout: layout, index: index, names: names))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: hour = (hour + 1) % 24
                case .decrement: hour = (hour + 23) % 24
                @unknown default: break
                }
            }
            .accessibilityAction {
                if let key = layout.cell(dow: dow, hour: hour)?.slivers.max(by: {
                    (index[$0.key]?.plays ?? 0) < (index[$1.key]?.plays ?? 0)
                })?.key { onOpen(key) }
            }
            // "Recurring pockets": spoken as custom content (More Content rotor) rather than a
            // custom rotor — the ring is ONE adjustable element, so there is nothing to jump to.
            .accessibilityCustomContent("Recurring pockets",
                                        recurring.isEmpty ? "None yet"
                                            : recurring.map(PocketMomentKey.hourLabel).joined(separator: ", "))
            .accessibilityIdentifier("pocket-wheel-ring-\(dow)")
    }
}
#endif
