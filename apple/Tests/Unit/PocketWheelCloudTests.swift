import XCTest
@testable import PocketDJ

/// Pocket Wheel Phase 6 — what the pockets upload carries for the wheel (W4): the SENSOR mode
/// (running / walking / trip from motion) and the run tag, both additive (absent otherwise, so the
/// app↔cloud golden is byte-identical for plays without them), and a fingerprint that re-sends a
/// play once when either appears.
final class PocketWheelCloudTests: XCTestCase {

    private func event(source: PlayHistoryStore.PlaySource = .playlist, carPlay: Bool? = nil,
                       motion: String? = nil) -> PlayHistoryStore.PlayEvent {
        var e = PlayHistoryStore.PlayEvent(id: UUID(), songId: "s1", playedAt: 1_793_115_000_000, source: source,
                                           contextId: nil, contextName: nil, title: nil, artist: nil, originInstallId: nil,
                                           carPlay: carPlay)
        e.motion = motion
        return e
    }

    @MainActor
    func testSensorModeOnly() {
        XCTAssertEqual(ListeningPocketsService.sensorMode(event(motion: "running"), ctx: nil), "running")
        XCTAssertEqual(ListeningPocketsService.sensorMode(event(motion: "walking"), ctx: nil), "walking")
        XCTAssertEqual(ListeningPocketsService.sensorMode(event(motion: "automotive"), ctx: nil), "trip")
        XCTAssertNil(ListeningPocketsService.sensorMode(event(carPlay: true, motion: "running"), ctx: nil),
                     "CarPlay is already on the wire")
        XCTAssertNil(ListeningPocketsService.sensorMode(event(source: .mix), ctx: nil), "surface modes are derivable server-side")
        XCTAssertNil(ListeningPocketsService.sensorMode(event(motion: "stationary"), ctx: nil))
        XCTAssertNil(ListeningPocketsService.sensorMode(event(source: .game, motion: "running"), ctx: nil), "games never")
    }

    @MainActor
    func testWireIsAdditiveAndFingerprintMoves() throws {
        let plain = ListeningPocketsUploadEvent(id: "E", songId: "s", atMs: 0, ord: 0, tzOffsetMin: 0, source: "playlist",
                                                outcome: "completed", fraction: 1, originInstallId: nil, artist: nil,
                                                carPlay: nil, ctx: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        XCTAssertNil(json["mode"]); XCTAssertNil(json["run"])
        var wheel = plain
        wheel.mode = "running"
        wheel.run = .init(id: "R", moment: "h08|d2|carPlay", slot: 3, collectionId: "pl_pot")
        let j2 = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wheel)) as? [String: Any])
        XCTAssertEqual(j2["mode"] as? String, "running")
        XCTAssertEqual((j2["run"] as? [String: Any])?["moment"] as? String, "h08|d2|carPlay")
        XCTAssertEqual((j2["run"] as? [String: Any])?["slot"] as? Int, 3)
        let fpPlain = ListeningPocketsService.fingerprint(plain)
        XCTAssertFalse(fpPlain.contains("|m:"), "an old play's fingerprint is unchanged (no mass re-send)")
        XCTAssertNotEqual(ListeningPocketsService.fingerprint(wheel), fpPlain, "a settled mode / run tag re-sends once")
    }
}
