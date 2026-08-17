import XCTest
@testable import ColorComposerCore

final class PrintLayoutTests: XCTestCase {
    func testLayoutWithoutBleedOrMarksMatchesArtworkSize() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 100, height: 80),
            options: PrintOverlayOptions()
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 100, height: 80))
        XCTAssertEqual(layout.trimRect, .init(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(layout.artworkRect, layout.trimRect)
        XCTAssertTrue(layout.cropMarks.isEmpty)
        XCTAssertTrue(layout.registrationMarks.isEmpty)
    }

    func testLayoutAddsBleedAndMarkMarginOutsideTrimArea() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 100, height: 80),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: 2, bleedMM: 5)
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 126, height: 106))
        XCTAssertEqual(layout.trimRect, .init(x: 13, y: 13, width: 100, height: 80))
        XCTAssertEqual(layout.artworkRect, .init(x: 8, y: 8, width: 110, height: 90))
        XCTAssertEqual(layout.cropMarks.count, 8)
        XCTAssertEqual(layout.registrationMarks.count, 4)
    }

    func testCropMarksAndRegistrationMarksUseRequestedInset() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 40, height: 20),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: 4, bleedMM: 0)
        )

        XCTAssertEqual(
            layout.cropMarks.first,
            .init(start: .init(x: 10, y: 0), end: .init(x: 10, y: 6))
        )
        XCTAssertEqual(
            layout.registrationMarks,
            [
                .init(center: .init(x: 30, y: 3), radius: 3),
                .init(center: .init(x: 30, y: 37), radius: 3),
                .init(center: .init(x: 3, y: 20), radius: 3),
                .init(center: .init(x: 57, y: 20), radius: 3)
            ]
        )
    }

    func testNegativeBleedAndInsetAreClampedToZero() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 40, height: 20),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: -4, bleedMM: -2)
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 52, height: 32))
        XCTAssertEqual(layout.trimRect, .init(x: 6, y: 6, width: 40, height: 20))
        XCTAssertEqual(layout.artworkRect, layout.trimRect)
        XCTAssertEqual(layout.cropMarks.first, .init(start: .init(x: 6, y: 0), end: .init(x: 6, y: 6)))
        XCTAssertEqual(layout.registrationMarks.first, .init(center: .init(x: 26, y: 3), radius: 3))
    }

    func testBleedDoesNotIncreaseCanvasWithoutMarks() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 40, height: 20),
            options: PrintOverlayOptions(showsMarks: false, markInsetMM: 12, bleedMM: 5)
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 50, height: 30))
        XCTAssertEqual(layout.trimRect, .init(x: 5, y: 5, width: 40, height: 20))
        XCTAssertEqual(layout.artworkRect, .init(x: 0, y: 0, width: 50, height: 30))
        XCTAssertTrue(layout.cropMarks.isEmpty)
        XCTAssertTrue(layout.registrationMarks.isEmpty)
    }

    func testNegativePhysicalSizeIsClampedToZero() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: -40, height: -20),
            options: PrintOverlayOptions(showsMarks: false, markInsetMM: 12, bleedMM: 5)
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 10, height: 10))
        XCTAssertEqual(layout.trimRect, .init(x: 5, y: 5, width: 0, height: 0))
        XCTAssertEqual(layout.artworkRect, .init(x: 0, y: 0, width: 10, height: 10))
    }

    func testZeroPhysicalSizeWithMarksStillProducesFiniteLayout() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 0, height: 0),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: 4, bleedMM: 2)
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 24, height: 24))
        XCTAssertEqual(layout.trimRect, .init(x: 12, y: 12, width: 0, height: 0))
        XCTAssertEqual(layout.artworkRect, .init(x: 10, y: 10, width: 4, height: 4))
        XCTAssertEqual(layout.cropMarks.count, 8)
        XCTAssertEqual(layout.registrationMarks.count, 4)
    }
}
