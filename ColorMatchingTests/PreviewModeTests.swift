import XCTest
@testable import ColorMatching
import ColorComposerCore

final class PreviewModeTests: XCTestCase {
    func testOrderedModesStayAlignedWithMenuNumbering() {
        XCTAssertEqual(
            PreviewMode.orderedModes,
            [
                .composite,
                .errorMap,
                .gamut,
                .lighting(.white),
                .lighting(.red),
                .lighting(.green),
                .lighting(.blue),
                .lighting(.lps)
            ]
        )
    }

    func testShortcutKeysMatchOrderedPreviewTabs() {
        XCTAssertEqual(
            PreviewMode.orderedModes.map(\.shortcutKey),
            [
                KeyEquivalent("1"),
                KeyEquivalent("2"),
                KeyEquivalent("3"),
                KeyEquivalent("4"),
                KeyEquivalent("5"),
                KeyEquivalent("6"),
                KeyEquivalent("7"),
                KeyEquivalent("8")
            ]
        )
    }

    func testMenuTitlesMatchVisiblePreviewTabs() {
        XCTAssertEqual(
            PreviewMode.orderedModes.map(\.menuTitle),
            [
                "Composite",
                "Error Map",
                "Gamut",
                "White",
                "Red",
                "Green",
                "Blue",
                "LPS (Sodium)"
            ]
        )
    }
}
