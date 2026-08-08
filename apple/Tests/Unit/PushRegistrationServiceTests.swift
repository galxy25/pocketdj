import XCTest
@testable import PocketDJ

/// Push-token plumbing — hex encoding + the onToken fan-out the MwF store hangs off.
/// (No UNUserNotificationCenter touch: authorization is exercised on-device only.)
@MainActor
final class PushRegistrationServiceTests: XCTestCase {

    func testHandleTokenHexEncodesAndFiresOnToken() {
        let service = PushRegistrationService()
        var fired: [String] = []
        service.onToken = { fired.append($0) }
        service.handleToken(Data([0xab, 0x01, 0xff, 0x00]))
        XCTAssertEqual(service.deviceTokenHex, "ab01ff00")
        XCTAssertEqual(fired, ["ab01ff00"])
        // Rotation: a NEW token replaces and re-fires.
        service.handleToken(Data([0x00, 0x10]))
        XCTAssertEqual(service.deviceTokenHex, "0010")
        XCTAssertEqual(fired, ["ab01ff00", "0010"])
    }

    func testPlatformString() {
        let service = PushRegistrationService()
        #if os(macOS)
        XCTAssertEqual(service.platformString, "macos")
        #else
        XCTAssertEqual(service.platformString, "ios")
        #endif
        #if os(iOS) || os(macOS)
        XCTAssertTrue(service.isSupported)
        #else
        XCTAssertFalse(service.isSupported, "visionOS v1 rides the poll")
        #endif
    }
}
