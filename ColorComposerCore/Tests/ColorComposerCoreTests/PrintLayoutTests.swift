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
}
