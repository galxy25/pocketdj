import XCTest
import UniformTypeIdentifiers
@testable import PocketDJ

/// Guards the collection document type. A typo between the `UTType(exportedAs:)` constant and the
/// `com.pocketdj.collection` identifier in the Info.plist would yield a type that conforms to
/// nothing — which silently re-greys the import picker and kills tap-to-open. These asserts fail
/// loudly if the two drift.
final class PocketDJUTTypeTests: XCTestCase {
    func testCollectionTypeIdentifier() {
        XCTAssertEqual(UTType.pocketDJCollection.identifier, "com.pocketdj.collection")
    }

    func testCollectionTypeConformsToZip() {
        // The payload is a real PKZIP, so the type must conform to .zip — this is what lets a
        // picker/importer that accepts .zip also accept a .pdjcollection file.
        XCTAssertTrue(UTType.pocketDJCollection.conforms(to: .zip))
    }
}
