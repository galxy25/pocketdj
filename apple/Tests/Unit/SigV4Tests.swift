import XCTest
@testable import PocketDJ

final class SigV4Tests: XCTestCase {
    func testSha256KnownVectors() {
        XCTAssertEqual(SigV4.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SigV4.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSignProducesWellFormedAuthorization() {
        let creds = SigV4Creds(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "SECRET")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let headers = SigV4.sign(method: "POST", host: "example.aoss.amazonaws.com",
                                 path: "/pocketdj/_search", body: Data("{}".utf8),
                                 region: "us-west-2", service: "aoss", creds: creds, date: date)

        let auth = try! XCTUnwrap(headers["Authorization"])
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"))
        XCTAssertTrue(auth.contains("/us-west-2/aoss/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))

        let signature = auth.components(separatedBy: "Signature=").last ?? ""
        XCTAssertEqual(signature.count, 64)                       // SHA256 hex
        XCTAssertTrue(signature.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(headers["x-amz-content-sha256"], SigV4.sha256Hex(Data("{}".utf8)))
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func testSignIsDeterministic() {
        let creds = SigV4Creds(accessKeyId: "A", secretAccessKey: "S")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func sign() -> [String: String] {
            SigV4.sign(method: "POST", host: "h", path: "/pocketdj/_search", body: Data("x".utf8),
                       region: "us-west-2", service: "aoss", creds: creds, date: date)
        }
        XCTAssertEqual(sign()["Authorization"], sign()["Authorization"])
    }
}
