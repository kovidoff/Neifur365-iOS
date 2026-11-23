import XCTest
@testable import Neifur365

final class ThemeTests: XCTestCase {
    func testVariableFontsResolve() {
        let manrope = NfFont.variableUIFont(postScriptName: "Manrope-ExtraLight", size: 16, weight: 700)
        let unbounded = NfFont.variableUIFont(postScriptName: "Unbounded-Regular", size: 22, weight: 600)
        XCTAssertEqual(manrope.pointSize, 16, accuracy: 0.01)
        XCTAssertEqual(unbounded.pointSize, 22, accuracy: 0.01)
    }

    func testRootTabsCount() {
        XCTAssertEqual(RootTab.allCases.count, 4)
    }
}
