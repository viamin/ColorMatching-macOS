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

        XCTAssertEqual(layout.canvasSize, .init(width: 130, height: 110))
        XCTAssertEqual(layout.trimRect, .init(x: 15, y: 15, width: 100, height: 80))
        XCTAssertEqual(layout.artworkRect, .init(x: 10, y: 10, width: 110, height: 90))
        XCTAssertEqual(layout.cropMarks.count, 8)
        XCTAssertEqual(layout.registrationMarks.count, 4)
    }

    func testBleedPushesMarksOutsideArtworkBounds() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 100, height: 80),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: 2, bleedMM: 5)
        )

        XCTAssertEqual(
            layout.cropMarks.first,
            .init(start: .init(x: 15, y: 2), end: .init(x: 15, y: 8))
        )
        XCTAssertEqual(
            layout.registrationMarks.first,
            .init(center: .init(x: 65, y: 5), radius: 3)
        )
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

        XCTAssertEqual(layout.canvasSize, .init(width: 56, height: 36))
        XCTAssertEqual(layout.trimRect, .init(x: 8, y: 8, width: 40, height: 20))
        XCTAssertEqual(layout.artworkRect, layout.trimRect)
        XCTAssertEqual(layout.cropMarks.first, .init(start: .init(x: 8, y: 2), end: .init(x: 8, y: 8)))
        XCTAssertEqual(layout.registrationMarks.first, .init(center: .init(x: 28, y: 5), radius: 3))
    }

    func testBleedExpandsCanvasWithoutMarks() {
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

        XCTAssertEqual(layout.canvasSize, .init(width: 28, height: 28))
        XCTAssertEqual(layout.trimRect, .init(x: 14, y: 14, width: 0, height: 0))
        XCTAssertEqual(layout.artworkRect, .init(x: 12, y: 12, width: 4, height: 4))
        XCTAssertEqual(layout.cropMarks.count, 8)
        XCTAssertEqual(layout.registrationMarks.count, 4)
    }

    func testLayoutAddsEnoughPaddingForRegistrationCrosshairs() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: 40, height: 20),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: 3, bleedMM: 0)
        )

        XCTAssertEqual(layout.trimRect.minY, 11)
        XCTAssertEqual(layout.registrationMarks.first, .init(center: .init(x: 31, y: 5), radius: 3))
    }

    func testNonFiniteMeasurementsAreClampedToZero() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: .nan, height: .infinity),
            options: PrintOverlayOptions(showsMarks: false, markInsetMM: .nan, bleedMM: .infinity),
            markLengthMM: .nan,
            registrationRadiusMM: .infinity
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 0, height: 0))
        XCTAssertEqual(layout.trimRect, .init(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(layout.artworkRect, layout.trimRect)
        XCTAssertTrue(layout.cropMarks.isEmpty)
        XCTAssertTrue(layout.registrationMarks.isEmpty)
    }

    func testNonFiniteMeasurementsWithMarksStillProduceFiniteLayout() {
        let layout = PrintLayout.make(
            physicalSizeMM: .init(width: .nan, height: .infinity),
            options: PrintOverlayOptions(showsMarks: true, markInsetMM: .nan, bleedMM: .infinity),
            markLengthMM: .nan,
            registrationRadiusMM: .infinity
        )

        XCTAssertEqual(layout.canvasSize, .init(width: 4, height: 4))
        XCTAssertEqual(layout.trimRect, .init(x: 2, y: 2, width: 0, height: 0))
        XCTAssertEqual(layout.artworkRect, layout.trimRect)
        XCTAssertEqual(layout.cropMarks.count, 8)
        XCTAssertEqual(
            layout.registrationMarks,
            [
                .init(center: .init(x: 2, y: 2), radius: 0),
                .init(center: .init(x: 2, y: 2), radius: 0),
                .init(center: .init(x: 2, y: 2), radius: 0),
                .init(center: .init(x: 2, y: 2), radius: 0)
            ]
        )
    }
}
