import Foundation

/// A raw RGBA8 raster buffer (row-major, 4 bytes per pixel, unpremultiplied).
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public extension BrightnessGrid {
    /// Nearest-neighbor upsample by an integer block factor (each cell becomes a
    /// `factor × factor` block). Used to render the logical solution to a larger
    /// export/print raster without introducing new colors.
    func upsampled(by factor: Int) -> BrightnessGrid {
        guard factor > 1 else { return self }
        let outW = width * factor
        let outH = height * factor
        var out = [Double](repeating: 0, count: outW * outH)
        for y in 0..<height {
            for x in 0..<width {
                let v = values[y * width + x]
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        out[(y * factor + dy) * outW + (x * factor + dx)] = v
                    }
                }
            }
        }
        return BrightnessGrid(width: outW, height: outH, values: out)
    }
}

/// Renders a solved composition into raster outputs:
/// the printable color composite, a normalized error map, and per-condition
/// predicted lighting previews.
public enum CompositionRenderer {

    /// The printable color composite: each cell is its selected palette color.
    /// Unmatched cells are fully transparent.
    public static func composite(_ result: CompositionResult) -> RGBAImage {
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            guard let index = result.colorIndices[cell] else {
                // Transparent marker — no palette color was eligible.
                rgba[cell * 4 + 3] = 0
                continue
            }
            let color = result.palette[index].rgb
            rgba[cell * 4 + 0] = color.red
            rgba[cell * 4 + 1] = color.green
            rgba[cell * 4 + 2] = color.blue
            rgba[cell * 4 + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// On-screen composite preview with unmatched cells replaced by a visible
    /// magenta marker so missing measurements are never invisible.
    public static func compositePreview(_ result: CompositionResult) -> RGBAImage {
        previewImage(composite(result), for: result)
    }

    /// Generic soft-proof preview of the printable composite. This is a
    /// lightweight approximation of how the palette may compress on paper, not
    /// an ICC-managed conversion. Cells that exceed the conservative printable
    /// envelope are flagged in `outOfGamutCells` and tinted with a warning wash.
    public static func softProof(
        _ result: CompositionResult,
        profile: SoftProofProfile = .genericPrinter
    ) -> SoftProofPreview {
        SoftProofing.preview(result, profile: profile)
    }

    /// On-screen soft-proof preview with the same unmatched-cell marker used by
    /// `compositePreview(_:)`, so proofing does not hide measurement gaps.
    public static func softProofPreview(
        _ result: CompositionResult,
        profile: SoftProofProfile = .genericPrinter
    ) -> SoftProofPreview {
        let preview = softProof(result, profile: profile)
        return SoftProofPreview(
            image: previewImage(preview.image, for: result),
            outOfGamutCells: preview.outOfGamutCells
        )
    }

    /// Normalized error map. Brighter means larger matching error; unmatched
    /// cells are the brightest.
    public static func errorMap(_ result: CompositionResult) -> BrightnessGrid {
        let finite = result.errors.filter { $0.isFinite }
        let maxError = max(finite.max() ?? 0, 1e-9)

        let values = result.errors.map { error -> Double in
            guard error.isFinite else { return 1.0 }
            return min(error / maxError, 1.0)
        }
        return BrightnessGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// Predicted grayscale appearance under one lighting condition: each cell
    /// shows the selected palette color's measured brightness for that
    /// condition. Colors without that measurement render as black.
    public static func lightingPreview(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> BrightnessGrid {
        let values = (0..<result.cellCount).map { cell -> Double in
            guard let index = result.colorIndices[cell] else { return 0 }
            return result.palette[index].brightness(for: condition) ?? 0
        }
        return BrightnessGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// Predicted appearance under one lighting condition, tinted by the
    /// condition's representative color (`LightingCondition.displayTint`) so the
    /// preview reads like the image viewed under that colored light. Each cell
    /// maps from black to the tint by the selected color's measured brightness.
    public static func lightingPreviewTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        let tint = condition.displayTint
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)

        for cell in 0..<result.cellCount {
            let base = cell * 4
            let brightness: Double
            if let index = result.colorIndices[cell] {
                brightness = result.palette[index].brightness(for: condition) ?? 0
            } else {
                brightness = 0
            }
            let scaled = max(0, min(1, brightness))
            rgba[base] = UInt8((scaled * tint.red) * 255)
            rgba[base + 1] = UInt8((scaled * tint.green) * 255)
            rgba[base + 2] = UInt8((scaled * tint.blue) * 255)
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// Signed per-cell difference between the source brightness for a condition
    /// and the predicted brightness of the selected color: `source − predicted`.
    ///
    /// Positive values mean the palette under-shoots (source brighter than the
    /// achievable prediction); negative values mean it over-shoots. When no
    /// source grid exists for the condition the difference is `0` everywhere.
    public static func lightingDifference(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> DifferenceGrid {
        let predicted = lightingPreview(result, for: condition)
        guard let source = result.sourceGrids[condition] else {
            return DifferenceGrid(
                width: result.gridWidth,
                height: result.gridHeight,
                values: [Double](repeating: 0, count: result.cellCount)
            )
        }
        let values = (0..<result.cellCount).map { source.values[$0] - predicted.values[$0] }
        return DifferenceGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// The source-vs-prediction difference for one condition, rendered with a
    /// diverging colormap so the direction and magnitude of each cell's error
    /// are readable at a glance:
    /// - under-shoots (source brighter, positive difference) trend **blue**;
    /// - over-shoots (predicted brighter, negative difference) trend **red**;
    /// - near-zero stays dark.
    ///
    /// Cells with no selected color (unmatched) render as a neutral gray marker.
    public static func lightingDifferenceTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        let difference = lightingDifference(result, for: condition)
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            let base = cell * 4
            let rgb = divergingColor(for: difference.values[cell], matched: result.colorIndices[cell] != nil)
            rgba[base] = rgb.red
            rgba[base + 1] = rgb.green
            rgba[base + 2] = rgb.blue
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// The source brightness grid for a condition, tinted by the condition's
    /// representative color — the counterpart to `lightingPreviewTinted`, so
    /// source and prediction render in the same style for side-by-side
    /// comparison. Returns transparent black when no source grid exists.
    public static func sourcePreviewTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        guard let source = result.sourceGrids[condition] else {
            return RGBAImage(width: result.gridWidth, height: result.gridHeight,
                             rgba: [UInt8](repeating: 0, count: result.cellCount * 4))
        }
        let tint = condition.displayTint
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            let base = cell * 4
            let scaled = max(0, min(1, source.values[cell]))
            rgba[base] = UInt8((scaled * tint.red) * 255)
            rgba[base + 1] = UInt8((scaled * tint.green) * 255)
            rgba[base + 2] = UInt8((scaled * tint.blue) * 255)
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// Maps a signed difference to a diverging RGBA-free RGB triple: under-shoots
    /// (positive) trend blue, over-shoots (negative) trend red, zero is black.
    /// Unmatched cells get a neutral gray so they read as "no prediction".
    private static func divergingColor(for difference: Double, matched: Bool) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard matched else { return (64, 64, 64) }
        let clamped = max(-1, min(1, difference))
        let magnitude = abs(clamped)
        if clamped >= 0 {
            return (0, UInt8(magnitude * 120), UInt8(magnitude * 255))
        } else {
            return (UInt8(magnitude * 255), UInt8(magnitude * 60), 0)
        }
    }

    private static func previewImage(_ image: RGBAImage, for result: CompositionResult) -> RGBAImage {
        precondition(image.width == result.gridWidth && image.height == result.gridHeight)

        var rgba = image.rgba
        for cell in 0..<result.cellCount where result.colorIndices[cell] == nil {
            let base = cell * 4
            rgba[base] = 255
            rgba[base + 1] = 0
            rgba[base + 2] = 255
            rgba[base + 3] = 255
        }
        return RGBAImage(width: image.width, height: image.height, rgba: rgba)
    }
}
