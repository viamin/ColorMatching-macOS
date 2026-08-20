import XCTest
@testable import ColorComposerCore

final class RasterTilerTests: XCTestCase {

    // MARK: - Planning

    func testImageSmallerThanTileProducesSingleFullTile() {
        let tiles = RasterTiler.plan(imageWidth: 100, imageHeight: 80, tileWidth: 200, tileHeight: 200, overlap: 10)
        XCTAssertEqual(tiles, [TileSpec(x: 0, y: 0, width: 100, height: 80, row: 0, column: 0)])
    }

    func testOversizedImageIsSplitIntoMultipleTiles() {
        let tiles = RasterTiler.plan(imageWidth: 200, imageHeight: 100, tileWidth: 100, tileHeight: 100, overlap: 20)
        XCTAssertGreaterThan(tiles.count, 1)
        assertFullCoverage(tiles, imageWidth: 200, imageHeight: 100)
        assertMinimumOverlap(tiles, imageWidth: 200, imageHeight: 100, requestedOverlap: 20)
    }

    func testTilesFullyCoverTheSourceImage() {
        let tiles = RasterTiler.plan(imageWidth: 517, imageHeight: 233, tileWidth: 150, tileHeight: 90, overlap: 15)
        assertFullCoverage(tiles, imageWidth: 517, imageHeight: 233)
    }

    func testAdjacentTilesOverlapByAtLeastTheRequestedAmount() {
        let tiles = RasterTiler.plan(imageWidth: 640, imageHeight: 480, tileWidth: 300, tileHeight: 200, overlap: 25)
        assertMinimumOverlap(tiles, imageWidth: 640, imageHeight: 480, requestedOverlap: 25)
    }

    func testTileOriginsSnapToCellBoundaries() {
        // A logical cell is 8px wide/tall; tile edges should land on multiples
        // of 8 so no cell is split between two tiles.
        let cellSize = 8
        let tiles = RasterTiler.plan(
            imageWidth: 400, imageHeight: 320,
            tileWidth: 133, tileHeight: 97, // deliberately not multiples of 8
            overlap: 17,
            cellSize: cellSize
        )
        for tile in tiles {
            XCTAssertEqual(tile.x % cellSize, 0, "tile x=\(tile.x) is not cell-aligned")
            XCTAssertEqual(tile.y % cellSize, 0, "tile y=\(tile.y) is not cell-aligned")
        }
        assertFullCoverage(tiles, imageWidth: 400, imageHeight: 320)
    }

    func testOverlapIsClampedBelowTileSize() {
        // An overlap >= tile size would produce a zero/negative stride;
        // planning must still terminate (with a small, positive stride) and
        // cover the image.
        let tiles = RasterTiler.plan(imageWidth: 40, imageHeight: 40, tileWidth: 20, tileHeight: 20, overlap: 100)
        assertFullCoverage(tiles, imageWidth: 40, imageHeight: 40)
    }

    func testTilesAreOrderedRowMajorWithMatchingRowColumnIndices() {
        let tiles = RasterTiler.plan(imageWidth: 250, imageHeight: 150, tileWidth: 100, tileHeight: 100, overlap: 10)
        let rows = Set(tiles.map(\.row)).sorted()
        let columns = Set(tiles.map(\.column)).sorted()
        XCTAssertEqual(rows, Array(0..<rows.count))
        XCTAssertEqual(columns, Array(0..<columns.count))
        XCTAssertEqual(tiles.count, rows.count * columns.count)
    }

    // MARK: - Extraction

    func testExtractCopiesTilePixelsFromSource() {
        // 4x2 image, each pixel a distinct color so extraction can be verified.
        let width = 4, height = 2
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let base = i * 4
            rgba[base] = UInt8(i); rgba[base + 1] = 0; rgba[base + 2] = 0; rgba[base + 3] = 255
        }
        let image = RGBAImage(width: width, height: height, rgba: rgba)

        let tile = TileSpec(x: 2, y: 1, width: 2, height: 1, row: 1, column: 1)
        let extracted = RasterTiler.extract(image, tile: tile)

        XCTAssertEqual(extracted.width, 2)
        XCTAssertEqual(extracted.height, 1)
        // Source row 1 starts at pixel index 4 (row-major); columns 2,3 -> pixel indices 6,7.
        XCTAssertEqual(extracted.rgba[0], 6)
        XCTAssertEqual(extracted.rgba[4], 7)
    }

    func testExtractedTileMatchesFullPlanRoundTrip() {
        let width = 30, height = 20
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = UInt8(i % 256)
            rgba[i * 4 + 3] = 255
        }
        let image = RGBAImage(width: width, height: height, rgba: rgba)
        let tiles = RasterTiler.plan(imageWidth: width, imageHeight: height, tileWidth: 15, tileHeight: 12, overlap: 3)

        for tile in tiles {
            let extracted = RasterTiler.extract(image, tile: tile)
            for y in 0..<tile.height {
                for x in 0..<tile.width {
                    let srcBase = ((tile.y + y) * width + (tile.x + x)) * 4
                    let dstBase = (y * tile.width + x) * 4
                    XCTAssertEqual(extracted.rgba[dstBase], image.rgba[srcBase])
                }
            }
        }
    }

    // MARK: - Helpers

    private func assertFullCoverage(_ tiles: [TileSpec], imageWidth: Int, imageHeight: Int, line: UInt = #line) {
        var covered = [Bool](repeating: false, count: imageWidth * imageHeight)
        for tile in tiles {
            for y in tile.y..<(tile.y + tile.height) {
                for x in tile.x..<(tile.x + tile.width) {
                    covered[y * imageWidth + x] = true
                }
            }
        }
        XCTAssertTrue(covered.allSatisfy { $0 }, "some pixels are not covered by any tile", line: line)
    }

    /// Verifies that for every pair of tiles in the same row (or column) of
    /// the tile grid that are horizontally (or vertically) adjacent, the
    /// shared overlap region is at least `requestedOverlap` pixels wide.
    private func assertMinimumOverlap(
        _ tiles: [TileSpec], imageWidth: Int, imageHeight: Int, requestedOverlap: Int, line: UInt = #line
    ) {
        let rows = Dictionary(grouping: tiles, by: \.row)
        for (_, rowTiles) in rows {
            let sorted = rowTiles.sorted { $0.column < $1.column }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let overlap = (a.x + a.width) - b.x
                XCTAssertGreaterThanOrEqual(overlap, requestedOverlap, line: line)
            }
        }
        let columns = Dictionary(grouping: tiles, by: \.column)
        for (_, columnTiles) in columns {
            let sorted = columnTiles.sorted { $0.row < $1.row }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let overlap = (a.y + a.height) - b.y
                XCTAssertGreaterThanOrEqual(overlap, requestedOverlap, line: line)
            }
        }
    }
}
