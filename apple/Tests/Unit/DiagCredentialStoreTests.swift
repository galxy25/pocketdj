import XCTest
@testable import PocketDJ

final class DiagCredentialStoreTests: XCTestCase {
    private let store = DiagCredentialStore(service: "com.levi.pocketdj.diag.tests")

    override func setUp() { store.clear() }
    override func tearDown() { store.clear() }

    func testEmptyByDefault() {
        XCTAssertNil(store.load())
    }

    func testRoundTripTrimsWhitespace() {
        store.save(accessKeyID: " test-id \n", secret: "test-secret ")
        XCTAssertEqual(store.load(), .init(accessKeyID: "test-id", secret: "test-secret"))
    }

    func testBlankSaveClears() {
        store.save(accessKeyID: "test-id", secret: "test-secret")
        store.save(accessKeyID: "test-id", secret: "  ")
        XCTAssertNil(store.load())
    }
}
