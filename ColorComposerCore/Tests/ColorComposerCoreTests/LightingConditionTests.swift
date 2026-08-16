import XCTest
@testable import ColorComposerCore

final class LightingConditionTests: XCTestCase {
    func testCanonicalOrderMatchesPreviewShortcutNumbering() {
        let conditions = LightingCondition.all

        XCTAssertEqual(conditions, [.white, .red, .green, .blue, .lps])
        XCTAssertEqual(conditions.count, 5)
        XCTAssertEqual(
            conditions.map(\.displayName),
            ["White", "Red", "Green", "Blue", "LPS (Sodium)"]
        )
    }
}
