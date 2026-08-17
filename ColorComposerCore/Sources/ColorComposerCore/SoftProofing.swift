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
        self.paperBlend = paperBlend
        self.blackFloor = blackFloor
        self.contrastScale = contrastScale
        self.baseChromaLimit = baseChromaLimit
        self.midtoneChromaPenalty = midtoneChromaPenalty
        self.shadowChromaPenalty = shadowChromaPenalty
        self.warningOverlayOpacity = warningOverlayOpacity
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

/// A soft-proofed raster plus one gamut-warning bit per logical output cell.
public struct SoftProofPreview: Sendable, Equatable {
    public let image: RGBAImage
    public let outOfGamutCells: [Bool]

    public init(image: RGBAImage, outOfGamutCells: [Bool]) {
        precondition(outOfGamutCells.count == image.width * image.height)
        self.image = image
        self.outOfGamutCells = outOfGamutCells
    }

    public var outOfGamutCount: Int {
        outOfGamutCells.lazy.filter { $0 }.count
    }

    public func isOutOfGamut(x: Int, y: Int) -> Bool {
        outOfGamutCells[y * image.width + x]
    }
}

enum SoftProofing {
    private static let warningColor = (red: 1.0, green: 0.55, blue: 0.0)

    static func preview(
        _ result: CompositionResult,
        profile: SoftProofProfile
    ) -> SoftProofPreview {
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        var outOfGamut = [Bool](repeating: false, count: result.cellCount)

        for cell in 0..<result.cellCount {
            guard let index = result.colorIndices[cell] else { continue }

            let proof = proofedColor(for: result.palette[index].rgb, profile: profile)
            let base = cell * 4
            rgba[base] = proof.rgb.red
            rgba[base + 1] = proof.rgb.green
            rgba[base + 2] = proof.rgb.blue
            rgba[base + 3] = 255
            outOfGamut[cell] = proof.isOutOfGamut
        }

        return SoftProofPreview(
            image: RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba),
            outOfGamutCells: outOfGamut
        )
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

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func toRGBColor(_ value: (red: Double, green: Double, blue: Double)) -> RGBColor {
        RGBColor(
            red: UInt8(clamp(value.red) * 255),
            green: UInt8(clamp(value.green) * 255),
            blue: UInt8(clamp(value.blue) * 255)
        )
    }
}
