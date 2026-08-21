import XCTest
@testable import ColorComposerCore

final class LightingConditionTests: XCTestCase {
    func testCanonicalOrderMatchesPreviewShortcutNumbering() {
        let conditions = LightingCondition.all

        XCTAssertEqual(conditions, [.white, .red, .green, .blue, .lps])
        XCTAssertEqual(conditions.count, 5)
        XCTAssertLessThanOrEqual(
            conditions.count + 3,
            9,
            "Preview shortcut numbering assumes the three static tabs plus lighting tabs stay single-digit."
        )
        XCTAssertEqual(
            conditions.map(\.displayName),
            ["White", "Red", "Green", "Blue", "LPS (Sodium)"]
        )
    }
}
