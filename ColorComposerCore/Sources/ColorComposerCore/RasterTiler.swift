import Foundation

/// One tile's placement within a larger raster, produced by `RasterTiler`.
public struct TileSpec: Sendable, Equatable {
    /// Origin of this tile within the source image, in pixels.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    /// Position within the tile grid (row-major), for job/file naming.
    public let row: Int
    public let column: Int

    public init(x: Int, y: Int, width: Int, height: Int, row: Int, column: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.row = row
        self.column = column
    }
}

/// Splits a raster composite into page-sized tiles with overlap, so artwork
/// larger than the printer's paper can be printed (or exported) one tile at a
/// time and reassembled afterward.
public enum RasterTiler {

    /// Computes the tile layout for an `imageWidth` × `imageHeight` raster.
    ///
    /// - Parameters:
    ///   - tileWidth / tileHeight: the maximum size of a single tile, in
    ///     pixels (typically derived from the printer's page size).
    ///   - overlap: pixels shared between adjacent tiles, so the printed
    ///     sheets can be aligned and trimmed during reassembly. Clamped so it
    ///     never reaches the full tile size.
    ///   - cellSize: the pixel size of one logical composition cell (i.e.
    ///     `pixelsPerCell`). When greater than 1, tile edges are snapped to
    ///     multiples of `cellSize` so a logical cell is not split across two
    ///     tiles.
    /// - Returns: tiles in row-major order, fully covering the image. A
    ///   single tile is returned when the image already fits on one page.
    public static func plan(
        imageWidth: Int,
        imageHeight: Int,
        tileWidth: Int,
        tileHeight: Int,
        overlap: Int,
        cellSize: Int = 1
    ) -> [TileSpec] {
        guard imageWidth > 0, imageHeight > 0, tileWidth > 0, tileHeight > 0 else { return [] }

        let snap = max(1, cellSize)
        let tileExtentX = max(snap, (tileWidth / snap) * snap)
        let tileExtentY = max(snap, (tileHeight / snap) * snap)
        let clampedOverlap = max(0, min(overlap, min(tileExtentX, tileExtentY) - 1))

        let originsX = tileOrigins(extent: imageWidth, tileExtent: tileExtentX, overlap: clampedOverlap, snap: snap)
        let originsY = tileOrigins(extent: imageHeight, tileExtent: tileExtentY, overlap: clampedOverlap, snap: snap)

        var tiles: [TileSpec] = []
        for (row, y) in originsY.enumerated() {
            let height = row == originsY.count - 1 ? imageHeight - y : tileExtentY
            for (column, x) in originsX.enumerated() {
                let width = column == originsX.count - 1 ? imageWidth - x : tileExtentX
                tiles.append(TileSpec(x: x, y: y, width: width, height: height, row: row, column: column))
            }
        }
        return tiles
    }

    /// Copies the pixels covered by `tile` out of `image` into a standalone
    /// raster, suitable for a single print job or exported tile file.
    public static func extract(_ image: RGBAImage, tile: TileSpec) -> RGBAImage {
        var rgba = [UInt8](repeating: 0, count: tile.width * tile.height * 4)
        let rowBytes = tile.width * 4
        for row in 0..<tile.height {
            let srcStart = ((tile.y + row) * image.width + tile.x) * 4
            let dstStart = row * rowBytes
            rgba.replaceSubrange(dstStart..<(dstStart + rowBytes), with: image.rgba[srcStart..<(srcStart + rowBytes)])
        }
        return RGBAImage(width: tile.width, height: tile.height, rgba: rgba)
    }

    /// Tile origins along one axis: `0, stride, 2*stride, ...` for every tile
    /// that has more image beyond it, then a final tile flush with the far
    /// edge. `stride` (and the final origin) are snapped down to a multiple of
    /// `snap` so a cut lands on a logical-cell boundary rather than inside
    /// one. Snapping only ever increases the effective overlap, never shrinks
    /// it below what was requested.
    private static func tileOrigins(extent: Int, tileExtent: Int, overlap: Int, snap: Int) -> [Int] {
        guard extent > tileExtent else { return [0] }

        let stride = max(snap, ((tileExtent - overlap) / snap) * snap)

        var origins: [Int] = []
        var origin = 0
        while origin + tileExtent < extent {
            origins.append(origin)
            origin += stride
        }
        let last = ((extent - tileExtent) / snap) * snap
        if origins.last != last {
            origins.append(last)
        }
        return origins
    }
}
