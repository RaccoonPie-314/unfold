import XCTest
@testable import UnfoldMac

final class TargetWiringTests: XCTestCase {
    func testPlatformTargetIsImportableFromTests() {
        XCTAssertEqual(UnfoldMacModuleMarker.name, "UnfoldMac")
    }
}
