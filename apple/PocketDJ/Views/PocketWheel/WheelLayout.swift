import Foundation
import CoreGraphics

/// The Pocket Wheel's PURE geometry (§2.2 / §2.3): ring radii (with the focused-ring fisheye and
/// the Fri|Sat weekend gap), the cell → sliver split, and polar hit-testing. Built once per
/// (size, focus, mode filter, snapshot) and handed to the Canvas — the view body derives nothing.
///
/// Angles: radians measured CLOCKWISE from 12 o'clock (midnight at the top), 15° per hour.
/// Screen point for (r, θ): center + r·(sin θ, −cos θ).
struct WheelLayout: Equatable {

    // MARK: Tuning

    static let holeFraction: CGFloat = 0.30
    static let focusScale: CGFloat = 1.8
    static let weekendGapFraction: CGFloat = 0.025
    static let ringGapFraction: CGFloat = 0.006
    static let maxSlivers = 3
    static let minSliverShare = 0.2

    struct Ring: Equatable {
        var dow: Int          // 1 = Monday (innermost) … 7 = Sunday (outermost)
        var inner: CGFloat
        var outer: CGFloat
        var focused: Bool
        var mid: CGFloat { (inner + outer) / 2 }
        var thickness: CGFloat { outer - inner }
    }

    struct Sliver: Equatable {
        var key: PocketMomentKey
        var start: Double     // radians
        var end: Double
        var share: Double     // of the cell's arc
    }

    struct Cell: Equatable {
        var dow: Int
        var hour: Int
        var slivers: [Sliver]
    }

    let radius: CGFloat
    let rings: [Ring]
    let cells: [Cell]
    let modeFilter: PocketMode?

    var holeRadius: CGFloat { radius * Self.holeFraction }

    // MARK: Build

    init(radius: CGFloat, focusedDow: Int, modeFilter: PocketMode?, moments: [PocketMoment]) {
        self.radius = radius
        self.modeFilter = modeFilter
        self.rings = Self.rings(radius: radius, focusedDow: focusedDow)
        var byCell: [Int: [PocketMoment]] = [:]
        for m in moments where m.plays > 0 || m.skips > 0 {
            if let f = modeFilter, m.key.mode != f { continue }
            byCell[(m.key.dow - 1) * 24 + m.key.hour, default: []].append(m)
        }
        var cells: [Cell] = []
        for (idx, ms) in byCell.sorted(by: { $0.key < $1.key }) {
            let dow = idx / 24 + 1, hour = idx % 24
            cells.append(Cell(dow: dow, hour: hour, slivers: Self.slivers(hour: hour, moments: ms)))
        }
        self.cells = cells
    }

    static func rings(radius: CGFloat, focusedDow: Int) -> [Ring] {
        let hole = radius * holeFraction
        let weekendGap = radius * weekendGapFraction
        let ringGap = radius * ringGapFraction
        let usable = radius - hole - weekendGap - ringGap * 6
        let unit = usable / (6 + focusScale)
        var r = hole
        var out: [Ring] = []
        for dow in 1...7 {
            if dow == 6 { r += weekendGap }
            let t = unit * (dow == focusedDow ? focusScale : 1)
            out.append(Ring(dow: dow, inner: r, outer: r + t, focused: dow == focusedDow))
            r += t + (dow < 7 ? ringGap : 0)
        }
        return out
    }

    /// One (hour, day) cell's slivers: the top 3 modes by plays, in the fixed precedence order,
    /// each width ∝ plays with a 20 % floor. One mode ⇒ one full sector.
    static func slivers(hour: Int, moments: [PocketMoment]) -> [Sliver] {
        let top = moments.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.key.mode.rank < $1.key.mode.rank }
            .prefix(maxSlivers)
            .sorted { $0.key.mode.rank < $1.key.mode.rank }
        let shares = sliverShares(top.map { max($0.plays, 1e-9) })
        let a0 = angle(forHour: Double(hour))
        let span = angle(forHour: 1)
        var out: [Sliver] = []
        var cursor = a0
        for (m, s) in zip(top, shares) {
            out.append(Sliver(key: m.key, start: cursor, end: cursor + span * s, share: s))
            cursor += span * s
        }
        return out
    }

    /// Proportional shares with a floor: below-floor entries are lifted to the floor and the rest
    /// rescaled over what remains (iterated until stable — at most `count` passes).
    static func sliverShares(_ weights: [Double]) -> [Double] {
        guard !weights.isEmpty else { return [] }
        if weights.count == 1 { return [1] }
        let floor = minSliverShare
        var fixed = Set<Int>()
        var shares = weights.map { $0 / weights.reduce(0, +) }
        for _ in 0..<weights.count {
            let low = shares.indices.filter { !fixed.contains($0) && shares[$0] < floor }
            guard !low.isEmpty else { break }
            fixed.formUnion(low)
            let free = shares.indices.filter { !fixed.contains($0) }
            let remaining = 1 - Double(fixed.count) * floor
            let freeTotal = free.reduce(0) { $0 + weights[$1] }
            for i in shares.indices {
                shares[i] = fixed.contains(i) ? floor : (freeTotal > 0 ? remaining * weights[i] / freeTotal : 0)
            }
        }
        return shares
    }

    // MARK: Angles

    static func angle(forHour h: Double) -> Double { h / 24 * 2 * .pi }

    /// Clockwise-from-12 angle of a point relative to center, in [0, 2π).
    static func angle(of p: CGPoint, center c: CGPoint) -> Double {
        let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        return a
    }

    static func point(radius r: CGFloat, angle a: Double, center c: CGPoint) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }

    // MARK: Hit testing

    enum Hit: Equatable {
        case center
        case cell(dow: Int, hour: Int, key: PocketMomentKey?)
        case outside
    }

    /// Polar hit-test: (r, θ) → ring → hour → sliver. A point in a ring gap belongs to the nearer
    /// ring; inside the hole is the centre button; beyond the rim is outside.
    func hit(_ p: CGPoint, center c: CGPoint) -> Hit {
        let r = hypot(p.x - c.x, p.y - c.y)
        if r < holeRadius { return .center }
        if r > radius { return .outside }
        guard let ring = rings.min(by: { distance(r, $0) < distance(r, $1) }) else { return .outside }
        let a = Self.angle(of: p, center: c)
        let hour = min(23, Int(a / Self.angle(forHour: 1)))
        let cell = cells.first { $0.dow == ring.dow && $0.hour == hour }
        let key = cell?.slivers.first { a >= $0.start && a < $0.end }?.key ?? cell?.slivers.last?.key
        return .cell(dow: ring.dow, hour: hour, key: key)
    }

    private func distance(_ r: CGFloat, _ ring: Ring) -> CGFloat {
        if r >= ring.inner && r <= ring.outer { return 0 }
        return min(abs(r - ring.inner), abs(r - ring.outer))
    }

    func ring(_ dow: Int) -> Ring? { rings.first { $0.dow == dow } }
    func cell(dow: Int, hour: Int) -> Cell? { cells.first { $0.dow == dow && $0.hour == hour } }
}
