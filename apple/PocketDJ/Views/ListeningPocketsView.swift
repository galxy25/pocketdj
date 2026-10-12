import SwiftUI

/// History ▸ Pockets — "Your pockets": the stretches where you were in a groove (3+ songs in a
/// row with no skip), and what defined each one, as computed by the listening-pockets cloud job.
///
/// Two lists: **Recurring** (patterns — pockets that keep coming back on the same kind of day,
/// at the same time, in the same place or on the same trip) and **Recent** (individual pockets,
/// newest first). A row opens `ListeningPocketDetailView` with the defining features, the
/// member songs, Play, and Save as playlist.
///
/// Place / trip chips are RE-LABELLED ON DEVICE (`ListeningContextProviding.label(for:)`): the
/// cloud titled them with the labels uploaded at the time, but ranks move as time-at-place
/// shifts, and only this device knows today's. An id the device no longer knows reads "Earlier
/// place". A device with no location engine (Mac, TV, Vision Pro) uses the cloud's snapshot.
struct ListeningPocketsView: View {
    @Environment(ListeningPocketsService.self) private var pockets: ListeningPocketsService?
    @Environment(ListeningLocationStore.self) private var location: ListeningLocationStore?
    @Environment(SettingsStore.self) private var settings
    @Binding var path: NavigationPath

    var body: some View {
        Group {
            if let pockets, !pockets.isEnabled {
                // The engine is on but pockets were never asked about: offer them, once, with
                // the disclosure — the switch is never flipped on anyone's behalf.
                optIn(pockets)
            } else if let pockets {
                content(pockets)
                    .task { await pockets.refreshIfStale() }
            } else {
                emptyState(detail: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    @ViewBuilder private func content(_ pockets: ListeningPocketsService) -> some View {
        let results = pockets.results
        let patterns = results?.patterns ?? []
        let recent = (results?.pockets ?? []).sorted { $0.startMs > $1.startMs }
        if patterns.isEmpty && recent.isEmpty {
            emptyState(detail: pockets.serviceAvailable ? nil : "Pockets aren't available yet.")
                .refreshable { await pockets.refreshNow() }
        } else {
            let labeler = ListeningPocketLabeler(results: results, location: location)
            List {
                Section {
                    if results?.stale == true {
                        Label("Updating with your latest listening…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(Theme.fgDim)
                            .accessibilityIdentifier("pockets-stale")
                    }
                } header: {
                    Text("Your pockets").font(.title3.weight(.semibold)).foregroundStyle(Theme.fg)
                        .textCase(nil)
                }
                if !patterns.isEmpty {
                    Section("Recurring") {
                        ForEach(patterns) { p in
                            NavigationLink {
                                ListeningPocketDetailView(subject: .pattern(p), labeler: labeler, path: $path)
                            } label: {
                                ListeningPatternCard(pattern: p, labeler: labeler)
                            }
                            .accessibilityIdentifier("pattern-row-\(p.id)")
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { p in
                            NavigationLink {
                                ListeningPocketDetailView(subject: .pocket(p), labeler: labeler, path: $path)
                            } label: {
                                ListeningPocketRow(pocket: p, labeler: labeler)
                            }
                            .accessibilityIdentifier("pocket-row-\(p.id)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await pockets.refreshNow() }
            .accessibilityIdentifier("pockets-list")
        }
    }

    private func optIn(_ pockets: ListeningPocketsService) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "waveform.path").font(.system(size: 34)).foregroundStyle(Theme.fgDim)
                Text("Find your listening pockets?")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.fg)
                Text("A pocket is a stretch where you played three or more songs in a row without skipping. PocketDJ can find yours and show what they have in common.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.fgDim)
                Text(ListeningPocketsService.consentText)
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(Theme.fgDim)
                HStack(spacing: 12) {
                    Button("Not now") { choose(false, pockets) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("pockets-optin-decline")
                    Button("Turn on") { choose(true, pockets) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pockets-optin-accept")
                }
                .padding(.top, 4)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("pockets-optin")
    }

    /// Record the answer exactly as the Settings toggle would (persist, then the service's gate).
    private func choose(_ on: Bool, _ pockets: ListeningPocketsService) {
        settings.listeningPocketsEnabled = on
        settings.persist()
        pockets.enabledDidChange()
    }

    private func emptyState(detail: String?) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.system(size: 34)).foregroundStyle(Theme.fgDim)
                Text("No pockets yet. Play three or more songs in a row without skipping.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.fgDim)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.fgDim)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("pockets-empty")
    }
}

// MARK: - Labels + formatting (shared by rows and detail)

/// Turns result features into display text: on-device place/trip labels, chip selection,
/// and the local date/time a pocket happened at (in ITS OWN UTC offset, not the device's).
@MainActor
struct ListeningPocketLabeler {
    let results: ListeningPocketsResults?
    let location: ListeningLocationStore?

    /// Today's label for a place/trip id. See the type doc of `ListeningPocketsView`. With places
    /// & trips ON, this device's engine is the authority (an id it pruned reads "Earlier place");
    /// with it off — or on a platform with no engine — the cloud's last uploaded snapshot names it.
    func contextLabel(_ tag: ListeningContextTag, fallback: String? = nil) -> String {
        if let location, location.isSupported, location.isEnabled {
            return location.label(for: tag) ?? "Earlier place"
        }
        return results?.snapshotLabel(for: tag) ?? fallback ?? "Earlier place"
    }

    func label(for f: ListeningPocketFeature) -> String {
        if let tag = f.contextTag { return contextLabel(tag, fallback: f.label) }
        return f.label
    }

    /// Up to `limit` chips: the defining numeric ranges first (BPM reads instantly), then the
    /// categorical features in the server's score order.
    func chips(features: [ListeningPocketFeature], numeric: [String: ListeningPocketNumeric],
               limit: Int = 4) -> [String] {
        var out: [String] = []
        if let bpm = numeric["bpm"], bpm.defining { out.append(Self.bpmText(bpm)) }
        for f in features where out.count < limit {
            let text = label(for: f)
            if !out.contains(text) { out.append(text) }
        }
        return Array(out.prefix(limit))
    }

    static func bpmText(_ n: ListeningPocketNumeric) -> String {
        let lo = Int(n.lo.rounded()), hi = Int(n.hi.rounded())
        return lo == hi ? "\(lo) BPM" : "\(lo)–\(hi) BPM"
    }

    /// "Fri 10 Oct · 7:40 AM" in the pocket's own offset.
    static func whenText(ms: Double, tzOffsetMin: Int?) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = tzOffsetMin.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? .current
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let day = f.string(from: date)
        f.dateFormat = nil
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(day) · \(f.string(from: date))"
    }

    /// "last Tue" within a week, else "last 3 Oct".
    static func lastText(ms: Double?, now: Date = Date()) -> String? {
        guard let ms else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(now.timeIntervalSince(date) < 6.5 * 86_400 ? "EEE" : "dMMM")
        return "last \(f.string(from: date))"
    }
}

/// A row of small capsule chips.
private struct ListeningPocketChips: View {
    let chips: [String]
    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { c in
                    Text(c)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.fg)
                }
            }
        }
    }
}

private struct ListeningPatternCard: View {
    let pattern: ListeningPocketPattern
    let labeler: ListeningPocketLabeler

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pattern.title).font(.headline).foregroundStyle(Theme.fg).lineLimit(2)
            ListeningPocketChips(chips: labeler.chips(features: pattern.features, numeric: pattern.numeric))
            Text(summary).font(.caption).foregroundStyle(Theme.fgDim)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts = ["\(pattern.occurrences) \(pattern.occurrences == 1 ? "time" : "times")"]
        if let last = ListeningPocketLabeler.lastText(ms: pattern.lastMs) { parts.append(last) }
        return parts.joined(separator: " · ")
    }
}

private struct ListeningPocketRow: View {
    let pocket: ListeningPocket
    let labeler: ListeningPocketLabeler

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pocket.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.fg).lineLimit(2)
            Text(ListeningPocketLabeler.whenText(ms: pocket.startMs, tzOffsetMin: pocket.tzOffsetMin))
                .font(.caption).foregroundStyle(Theme.fgDim)
            Text(counts).font(.caption).foregroundStyle(Theme.fgDim)
            ListeningPocketChips(chips: labeler.chips(features: pocket.features, numeric: pocket.numeric))
        }
        .padding(.vertical, 3)
    }

    private var counts: String {
        var s = "\(pocket.memberCount) \(pocket.memberCount == 1 ? "song" : "songs")"
        if pocket.skippedCount > 0 { s += " · \(pocket.skippedCount) skipped" }
        return s
    }
}

// MARK: - Detail

/// One pocket or one recurring pattern: what defines it, when/where, the songs, and actions.
struct ListeningPocketDetailView: View {
    enum Subject {
        case pocket(ListeningPocket)
        case pattern(ListeningPocketPattern)
    }
    let subject: Subject
    let labeler: ListeningPocketLabeler
    @Binding var path: NavigationPath

    @Environment(AppModel.self) private var app
    @Environment(CollectionsStore.self) private var collections
    @Environment(PlayHistoryStore.self) private var history
    @State private var savedName: String?

    private var title: String {
        switch subject { case .pocket(let p): return p.title; case .pattern(let p): return p.title }
    }
    private var features: [ListeningPocketFeature] {
        switch subject { case .pocket(let p): return p.features; case .pattern(let p): return p.features }
    }
    private var numeric: [String: ListeningPocketNumeric] {
        switch subject { case .pocket(let p): return p.numeric; case .pattern(let p): return p.numeric }
    }
    private var harmonic: ListeningPocketHarmonic? {
        switch subject { case .pocket(let p): return p.harmonic; case .pattern(let p): return p.harmonic }
    }
    private var ctx: ListeningContextTag? {
        switch subject { case .pocket(let p): return p.ctx; case .pattern(let p): return p.ctx }
    }
    /// Pocket members in play order, or a pattern's most-played songs.
    private var songIds: [String] {
        switch subject { case .pocket(let p): return p.songIds; case .pattern(let p): return p.songIds }
    }

    var body: some View {
        List {
            Section {
                Text(title).font(.headline).foregroundStyle(Theme.fg)
                HStack {
                    Button {
                        play()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songIds.isEmpty)
                    .accessibilityIdentifier("pocket-play")
                    Button {
                        saveAsPlaylist()
                    } label: {
                        Label("Save as playlist", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(songIds.isEmpty)
                    .accessibilityIdentifier("pocket-save-playlist")
                }
                if let savedName {
                    Text("Saved \"\(savedName)\" to your playlists.")
                        .font(.caption).foregroundStyle(Theme.fgDim)
                        .accessibilityIdentifier("pocket-saved")
                }
            }
            Section("What defines it") {
                ForEach(numericLines, id: \.self) { Text($0) }
                if let h = harmonic, h.defining {
                    Text(harmonicLine(h))
                }
                ForEach(features, id: \.self) { f in
                    Text(featureLine(f))
                }
                if numericLines.isEmpty && features.isEmpty && harmonic?.defining != true {
                    Text("Nothing stands out yet — it gets sharper as you listen more.")
                        .foregroundStyle(Theme.fgDim)
                }
            }
            Section("When & where") {
                ForEach(whenLines, id: \.self) { Text($0) }
            }
            Section(songsHeader) {
                ForEach(Array(songIds.enumerated()), id: \.offset) { _, id in
                    songRow(id)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(isPattern ? "Recurring pocket" : "Pocket")
    }

    private var isPattern: Bool { if case .pattern = subject { return true } else { return false } }

    private var songsHeader: String { isPattern ? "Most played" : "Songs" }

    // MARK: Text

    /// "House: 80 % of this pocket vs 12 % of your listening".
    private func featureLine(_ f: ListeningPocketFeature) -> String {
        let share = Self.pct(f.share)
        if let base = f.baselineShare {
            return "\(labeler.label(for: f)): \(share) of this pocket vs \(Self.pct(base)) of your listening"
        }
        return "\(labeler.label(for: f)): \(share) of this pocket"
    }

    private var numericLines: [String] {
        var out: [String] = []
        if let bpm = numeric["bpm"], bpm.defining {
            out.append("\(ListeningPocketLabeler.bpmText(bpm)), \(Self.tightness(bpm))")
        }
        if let energy = numeric["energy"], energy.defining {
            let lvl = energy.center >= 0.6 ? "High energy" : energy.center <= 0.4 ? "Low energy" : "Mid energy"
            out.append("\(lvl), \(Self.tightness(energy))")
        }
        if let year = numeric["year"], year.defining {
            let lo = Int(year.lo.rounded()), hi = Int(year.hi.rounded())
            out.append("\(lo == hi ? "\(lo)" : "\(lo)–\(hi)") releases, \(Self.tightness(year))")
        }
        return out
    }

    private func harmonicLine(_ h: ListeningPocketHarmonic) -> String {
        var s = "Keys flow: \(Self.pct(h.rate)) of changes go to a neighbouring key"
        if let b = h.baselineRate { s += " vs \(Self.pct(b)) usually" }
        return s
    }

    private var whenLines: [String] {
        var out: [String] = []
        switch subject {
        case .pocket(let p):
            out.append(ListeningPocketLabeler.whenText(ms: p.startMs, tzOffsetMin: p.tzOffsetMin))
            var parts: [String] = []
            if let d = p.dayType { parts.append(d.capitalized) }
            if let b = p.timeBucket { parts.append(b.capitalized) }
            if !parts.isEmpty { out.append(parts.joined(separator: " · ")) }
            var counts = "\(p.memberCount) songs"
            if p.skippedCount > 0 { counts += " · \(p.skippedCount) skipped along the way" }
            out.append(counts)
        case .pattern(let p):
            var parts: [String] = []
            if let d = p.dayType { parts.append(d.capitalized + "s") }
            if let b = p.timeBucket { parts.append(b.capitalized) }
            if !parts.isEmpty { out.append(parts.joined(separator: " · ")) }
            var times = "\(p.occurrences) times on \(p.distinctDays) days"
            if let last = ListeningPocketLabeler.lastText(ms: p.lastMs) { times += " · \(last)" }
            out.append(times)
        }
        if let ctx {
            out.append(ctx.isTrip ? "On the trip \(labeler.contextLabel(ctx))" : "At \(labeler.contextLabel(ctx))")
        }
        return out
    }

    /// Dispersion vs the baseline spread → plain words.
    private static func tightness(_ n: ListeningPocketNumeric) -> String {
        guard let r = n.dispersionRatio else { return "a steady range" }
        if r <= 0.25 { return "much tighter than usual" }
        if r <= 0.5 { return "tighter than usual" }
        return "about as varied as usual"
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }

    // MARK: Songs

    @ViewBuilder private func songRow(_ id: String) -> some View {
        let song = app.songsById[id]
        // Unresolved (left the catalog, or another device's library): the play's own snapshot.
        let snapshot = song == nil ? history.events.last(where: { $0.songId == id }) : nil
        VStack(alignment: .leading, spacing: 2) {
            Text(song?.name ?? snapshot?.title ?? "Unknown song").foregroundStyle(Theme.fg).lineLimit(1)
            if let artist = song?.artist ?? snapshot?.artist {
                Text(artist).font(.caption).foregroundStyle(Theme.fgDim).lineLimit(1)
            }
        }
    }

    // MARK: Actions

    private func play() {
        collections.playNow(songIds: songIds, name: title)
        path.append(SetlistLaunch(setlistId: nowPlayingSetlistId, autoplay: true))
    }

    private func saveAsPlaylist() {
        let p = collections.createPlaylist(title, songIds: songIds)
        savedName = p.name
    }
}
