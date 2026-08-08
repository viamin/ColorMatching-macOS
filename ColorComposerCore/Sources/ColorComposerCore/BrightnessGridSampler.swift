import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

/// Samples a `CGImage` into a normalized brightness grid (`0.0 ... 1.0`) at the
/// logical output resolution, applying a scaling mode, optional inversion, and a
/// color space for interpreting the sampled brightness.
///
/// Brightness is computed by drawing the image into an 8-bit grayscale Core
/// Graphics context and normalizing the raw channel value by 255. By default
/// this stays in gamma space — matching the `color_matching` mapper — but pass
/// `colorSpace: .linear` to decode each value to linear luminance via the sRGB
/// transfer function for physically-correct matching under colored light.
public enum BrightnessGridSampler {

    public static func sample(
        cgImage: CGImage,
        targetWidth: Int,
        targetHeight: Int,
        scalingMode: ImageScalingMode,
        invert: Bool = false,
        colorSpace: BrightnessColorSpace = .gamma
    ) -> BrightnessGrid {
        precondition(targetWidth > 0 && targetHeight > 0)

        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = targetWidth
        var bytes = [UInt8](repeating: 0, count: targetWidth * targetHeight)

        guard let context = CGContext(
            data: &bytes,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return BrightnessGrid(width: targetWidth, height: targetHeight, fill: 0)
        }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        let drawRect = Self.drawRect(
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            scalingMode: scalingMode
        )

        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(cgImage, in: drawRect)

        // Core Graphics uses a top-left origin in device space but contexts are
        // bottom-left by default; flip vertically so row 0 is the top of the image.
        var values = [Double](repeating: 0, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let srcRow = (targetHeight - 1 - y)
            for x in 0..<targetWidth {
                let raw = bytes[srcRow * bytesPerRow + x]
                var brightness = colorSpace.decode(Double(raw) / 255.0)
                if invert { brightness = 1.0 - brightness }
                values[y * targetWidth + x] = brightness
            }
        }

        return BrightnessGrid(width: targetWidth, height: targetHeight, values: values)
    }

    /// Computes the rectangle (in output pixels) into which the source image is
    /// drawn for the given scaling mode.
    static func drawRect(
        imageWidth: Int,
        imageHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        scalingMode: ImageScalingMode
    ) -> CGRect {
        let output = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        switch scalingMode {
        case .stretch:
            return output

        case .fit:
            let scale = min(
                Double(targetWidth) / Double(imageWidth),
                Double(targetHeight) / Double(imageHeight)
            )
            return centeredRect(
                width: Double(imageWidth) * scale,
                height: Double(imageHeight) * scale,
                in: output
            )

        case .fill:
            let scale = max(
                Double(targetWidth) / Double(imageWidth),
                Double(targetHeight) / Double(imageHeight)
            )
            return centeredRect(
                width: Double(imageWidth) * scale,
                height: Double(imageHeight) * scale,
                in: output
            )
        }
    }

    private static func centeredRect(width: Double, height: Double, in bounds: CGRect) -> CGRect {
        let x = bounds.midX - width / 2
        let y = bounds.midY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
#endif
