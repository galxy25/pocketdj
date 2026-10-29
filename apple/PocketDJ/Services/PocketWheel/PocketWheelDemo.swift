import Foundation

/// The `PDJ_SEED_POCKET_WHEEL` seam (screenshots + XCUITest, the `showcase` seed precedent): a
/// deterministic three-week listening scenario — the same shape as the unit-test fixture
/// (`Tests/Fixtures/pocket-wheel-history.json`) — built relative to NOW through the REAL engine,
/// so the wheel the screenshot shows is exactly what that history would paint.
enum PocketWheelDemo {
    static let collections: [(id: String, name: String)] = [
        ("pl_potential", "Potential"), ("pkt_late", "Late Night"), (PocketWheelIds.favorites, PocketWheelIds.favoritesName),
        ("pls_road", "Roadtrip"), ("pkt_chill", "Chill Lunch"), ("pkt_warmup", "Gym Warmup"),
    ]

    static func input(nowMs: Double, tzOffsetMin: Int) -> PocketMomentEngine.Input {
        let day = 86_400_000.0, hour = 3_600_000.0
        let localNow = nowMs + Double(tzOffsetMin) * 60_000
        let midnight = localNow - localNow.truncatingRemainder(dividingBy: day)
        func at(_ daysAgo: Int, _ h: Double, _ m: Double = 0) -> Double {
            midnight - Double(daysAgo) * day + h * hour + m * 60_000 - Double(tzOffsetMin) * 60_000
        }
        var events: [PlayHistoryStore.PlayEvent] = []
        var n = 0
        func ev(_ song: String, _ t: Double, _ src: PlayHistoryStore.PlaySource, origin: String? = nil,
                carPlay: Bool? = nil, motion: String? = nil, skipped: Bool = false, ctx: ListeningContextTag? = nil) {
            guard t < nowMs else { return }
            n += 1
            var e = PlayHistoryStore.PlayEvent(id: UUID(), songId: song, playedAt: t, source: src,
                                               contextId: origin == nil ? nil : "set_now_playing",
                                               contextName: nil, title: nil, artist: nil, originInstallId: nil,
                                               tzOffsetMin: tzOffsetMin, carPlay: carPlay, originCollectionId: origin)
            e.motion = motion
            e.wasSkipped = skipped ? true : nil
            e.listenedFraction = skipped ? 0.1 : 1
            e.listeningContext = ctx
            events.append(e)
        }
        let trip = ListeningContextTag.trip("trp_demo", origin: "plc_a", destination: "plc_b")
        for d in stride(from: 21, through: 0, by: -1) {
            let dow = PocketClock.local(atMs: at(d, 12), tzOffsetMin: tzOffsetMin).dow
            if dow <= 5 {
                for k in 0..<3 { ev("pot_\((d * 3 + k) % 24)", at(d, 8, Double(5 + k * 4)), .playlist, origin: "pl_potential",
                                    carPlay: true, skipped: dow == 1 && k == 0) }
                for k in 0..<2 { ev("pot_\((d + k) % 24)", at(d, 17, Double(40 + k * 4)), .playlist, origin: "pl_potential", carPlay: true) }
                ev("lun_\(d % 8)", at(d, 12, 10), .browser, origin: "pkt_chill")
                ev("lun_\((d + 3) % 8)", at(d, 12, 20), .pocket, origin: "pkt_chill")
                if dow == 2 || dow == 4 {
                    for k in 0..<3 { ev("gym_\((d + k) % 10)", at(d, 6, Double(k * 4)), .pocket, origin: "pkt_warmup", motion: MotionToken.running) }
                }
                if dow == 3 { ev("fav_\(d % 10)", at(d, 13, 0), .browser, origin: PocketWheelIds.favorites, motion: MotionToken.walking) }
            }
            if dow == 6 {
                for k in 0..<4 { ev("fav_\((d + k) % 10)", at(d, 9, Double(k * 4)), .browser, origin: PocketWheelIds.favorites,
                                    motion: MotionToken.running) }
                for k in 0..<3 { ev("late_\((d + k) % 12)", at(d, 22, Double(k * 5)), .mix, origin: "pkt_late") }
            }
            if dow == 7 {
                for k in 0..<3 { ev("road_\((d + k) % 8)", at(d, 15, Double(k * 4)), .playlist, origin: "pls_road", ctx: trip) }
                ev("fav_\(d % 10)", at(d, 11, 0), .browser, origin: PocketWheelIds.favorites)
            }
            ev("late_\(d % 12)", at(d, 21, 0), .mix, origin: "pkt_late")
            ev("late_\((d + 5) % 12)", at(d, 21, 5), .mix, origin: "pkt_late", skipped: d % 5 == 0)
            if d % 4 == 0 { ev("late_\((d + 2) % 12)", at(d, 23, 0), .mix, origin: "pkt_late") }
        }
        let artists = ["Drake", "Bryson Tiller", "6LACK", "dvsn", "Majid Jordan", "SZA"]
        var songs: [String: PocketMomentEngine.SongInfo] = [:]
        for i in 0..<24 { songs["pot_\(i)"] = .init(artist: artists[i % artists.count], genre: i % 3 == 0 ? "hip-hop" : "r&b",
                                                    bpm: Double(88 + (i % 6) * 4), year: 2012 + i % 10) }
        for i in 0..<12 { songs["late_\(i)"] = .init(artist: ["Massive Attack", "Portishead", "Burial"][i % 3], genre: "electronic",
                                                     bpm: Double(70 + i * 2), year: 1994 + i % 8) }
        for i in 0..<10 { songs["fav_\(i)"] = .init(artist: ["Daft Punk", "Justice"][i % 2], genre: "electronic", bpm: Double(120 + i), year: 2007) }
        for i in 0..<10 { songs["gym_\(i)"] = .init(artist: "Run the Jewels", genre: "hip-hop", bpm: Double(140 + i), year: 2016) }
        for i in 0..<8 { songs["road_\(i)"] = .init(artist: "Tom Petty", genre: "rock", bpm: Double(110 + i), year: 1979 + i) }
        for i in 0..<8 { songs["lun_\(i)"] = .init(artist: "Khruangbin", genre: "electronic", bpm: Double(96 + i), year: 2018) }
        return PocketMomentEngine.Input(
            events: events,
            collections: collections.map { .init(id: $0.id, name: $0.name, songIds: []) },
            songs: songs, librarySize: songs.count, nowMs: nowMs)
    }

    static var isRequested: Bool { ProcessInfo.processInfo.environment["PDJ_SEED_POCKET_WHEEL"] != nil }
}
