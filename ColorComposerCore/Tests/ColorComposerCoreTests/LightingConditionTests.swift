import XCTest
@testable import ColorComposerCore

final class LightingConditionTests: XCTestCase {
    func testCanonicalOrderMatchesPreviewShortcutNumbering() {
        XCTAssertEqual(LightingCondition.all, [.white, .red, .green, .blue, .lps])
    }
}
