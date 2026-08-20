import Foundation

/// A lightweight, generic "printer-like" preview profile.
///
/// This is intentionally heuristic rather than ICC-based: it slightly warms the
/// paper white, lifts blacks, compresses saturation into a conservative
/// printable envelope, and highlights colors that exceed that envelope.
public struct SoftProofProfile: Sendable, Equatable {
    public let paperWhite: RGBColor
    public let paperBlend: Double
    public let blackFloor: Double
    public let contrastScale: Double
    public let baseChromaLimit: Double
    public let midtoneChromaPenalty: Double
    public let shadowChromaPenalty: Double
    public let warningOverlayOpacity: Double

    public init(
        paperWhite: RGBColor,
        paperBlend: Double,
        blackFloor: Double,
        contrastScale: Double,
        baseChromaLimit: Double,
        midtoneChromaPenalty: Double,
        shadowChromaPenalty: Double,
        warningOverlayOpacity: Double
    ) {
        self.paperWhite = paperWhite
        self.paperBlend = SoftProofing.clamp(paperBlend)
        self.blackFloor = SoftProofing.clamp(blackFloor)
        self.contrastScale = SoftProofing.clamp(contrastScale)
        self.baseChromaLimit = SoftProofing.clamp(baseChromaLimit)
        self.midtoneChromaPenalty = SoftProofing.clamp(midtoneChromaPenalty)
        self.shadowChromaPenalty = SoftProofing.clamp(shadowChromaPenalty)
        self.warningOverlayOpacity = SoftProofing.clamp(warningOverlayOpacity)
    }

    public static let genericPrinter = SoftProofProfile(
        paperWhite: RGBColor(red: 246, green: 242, blue: 232),
        paperBlend: 0.08,
        blackFloor: 0.03,
        contrastScale: 0.90,
        baseChromaLimit: 0.78,
        midtoneChromaPenalty: 0.28,
        shadowChromaPenalty: 0.18,
        warningOverlayOpacity: 0.35
    )
}

/// A soft-proofed raster plus one gamut-warning bit per rendered pixel.
public struct SoftProofPreview: Sendable, Equatable {
    public let image: RGBAImage
    public let outOfGamutCells: [Bool]

    /// Number of *logical* cells containing at least one out-of-gamut pixel.
    /// Tracked separately from `outOfGamutCells` (which is pixel-resolution,
    /// since halftone/two-color modes rasterize each cell into several
    /// pixels) so the count reported to users stays in cell units regardless
    /// of `pixelsPerCell`.
    public let outOfGamutCount: Int

    public init(image: RGBAImage, outOfGamutCells: [Bool], outOfGamutCount: Int) {
        precondition(outOfGamutCells.count == image.width * image.height)
        self.image = image
        self.outOfGamutCells = outOfGamutCells
        self.outOfGamutCount = outOfGamutCount
    }

    public func isOutOfGamut(x: Int, y: Int) -> Bool {
        precondition(x >= 0 && x < image.width && y >= 0 && y < image.height)
        return outOfGamutCells[y * image.width + x]
    }
}

enum SoftProofing {
    private static let warningColor = (red: 1.0, green: 0.55, blue: 0.0)

    /// Renders the same rasterized composite used for export/print (so
    /// halftone dots and two-color mixes are proofed pixel-by-pixel, not just
    /// the flat one-color-per-cell baseline), then proofs each opaque pixel's
    /// color independently. Fully-transparent pixels (unmatched cells in flat
    /// mode) are left as-is; the caller overlays the unmatched marker.
    static func preview(
        _ result: CompositionResult,
        profile: SoftProofProfile,
        mode: RasterMode = .flat,
        pixelsPerCell: Int = 1
    ) -> SoftProofPreview {
        let base = CompositionRenderer.composite(result, mode: mode, pixelsPerCell: pixelsPerCell)
        var rgba = base.rgba
        var outOfGamut = [Bool](repeating: false, count: base.width * base.height)

        for pixel in 0..<(base.width * base.height) {
            let offset = pixel * 4
            guard rgba[offset + 3] != 0 else { continue }

            let color = RGBColor(red: rgba[offset], green: rgba[offset + 1], blue: rgba[offset + 2])
            let proof = proofedColor(for: color, profile: profile)
            rgba[offset] = proof.rgb.red
            rgba[offset + 1] = proof.rgb.green
            rgba[offset + 2] = proof.rgb.blue
            outOfGamut[pixel] = proof.isOutOfGamut
        }

        return SoftProofPreview(
            image: RGBAImage(width: base.width, height: base.height, rgba: rgba),
            outOfGamutCells: outOfGamut,
            outOfGamutCount: outOfGamutCellCount(
                outOfGamut,
                imageWidth: base.width,
                for: result,
                factor: max(pixelsPerCell, 1)
            )
        )
    }

    /// Counts logical cells with at least one out-of-gamut pixel in their
    /// `factor × factor` rasterized block.
    private static func outOfGamutCellCount(
        _ pixelFlags: [Bool],
        imageWidth: Int,
        for result: CompositionResult,
        factor: Int
    ) -> Int {
        var count = 0
        for cell in 0..<result.cellCount {
            let cellX = (cell % result.gridWidth) * factor
            let cellY = (cell / result.gridWidth) * factor
            let flagged = (0..<factor).contains { dy in
                (0..<factor).contains { dx in
                    pixelFlags[(cellY + dy) * imageWidth + cellX + dx]
                }
            }
            if flagged { count += 1 }
        }
        return count
    }

    private static func proofedColor(
        for color: RGBColor,
        profile: SoftProofProfile
    ) -> (rgb: RGBColor, isOutOfGamut: Bool) {
        let normalized = color.normalized
        let luminance = (0.2126 * normalized.red) + (0.7152 * normalized.green) + (0.0722 * normalized.blue)
        let maximum = max(normalized.red, normalized.green, normalized.blue)
        let minimum = min(normalized.red, normalized.green, normalized.blue)
        let chroma = maximum - minimum
        let limit = chromaLimit(for: luminance, profile: profile)
        let isOutOfGamut = chroma > (limit + 0.02)
        let compression = chroma > 0 ? min(1.0, limit / chroma) : 1.0

        var proof = (
            red: compress(normalized.red, toward: luminance, by: compression),
            green: compress(normalized.green, toward: luminance, by: compression),
            blue: compress(normalized.blue, toward: luminance, by: compression)
        )

        proof.red = profile.blackFloor + (proof.red * profile.contrastScale)
        proof.green = profile.blackFloor + (proof.green * profile.contrastScale)
        proof.blue = profile.blackFloor + (proof.blue * profile.contrastScale)

        let paperWhite = profile.paperWhite.normalized
        proof.red = blend(proof.red, paperWhite.red, amount: profile.paperBlend)
        proof.green = blend(proof.green, paperWhite.green, amount: profile.paperBlend)
        proof.blue = blend(proof.blue, paperWhite.blue, amount: profile.paperBlend)

        if isOutOfGamut {
            proof.red = blend(proof.red, warningColor.red, amount: profile.warningOverlayOpacity)
            proof.green = blend(proof.green, warningColor.green, amount: profile.warningOverlayOpacity)
            proof.blue = blend(proof.blue, warningColor.blue, amount: profile.warningOverlayOpacity)
        }

        return (rgb: toRGBColor(proof), isOutOfGamut: isOutOfGamut)
    }

    private static func chromaLimit(
        for luminance: Double,
        profile: SoftProofProfile
    ) -> Double {
        let midtonePenalty = abs(luminance - 0.55) * profile.midtoneChromaPenalty
        let shadowPenalty = max(0, 0.35 - luminance) * profile.shadowChromaPenalty
        return clamp(profile.baseChromaLimit - midtonePenalty - shadowPenalty)
    }

    private static func compress(_ value: Double, toward neutral: Double, by factor: Double) -> Double {
        neutral + ((value - neutral) * factor)
    }

    private static func blend(_ value: Double, _ other: Double, amount: Double) -> Double {
        (value * (1 - amount)) + (other * amount)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func toRGBColor(_ value: (red: Double, green: Double, blue: Double)) -> RGBColor {
        RGBColor(
            red: UInt8(clamp(value.red) * 255),
            green: UInt8(clamp(value.green) * 255),
            blue: UInt8(clamp(value.blue) * 255)
        )
    }
}
