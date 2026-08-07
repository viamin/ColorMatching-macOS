import Foundation
import AppKit
import CoreGraphics
import ColorComposerCore

/// One grayscale source image and how it is mapped into the composition.
@Observable
final class SourceLayer: Identifiable {
    let id = UUID()

    var imageData: Data? {
        didSet { cachedCGImage = imageData.flatMap { ImageUtilities.makeCGImage(from: $0) } }
    }
    var filename: String?
    var assignedCondition: LightingCondition?
    var inverted: Bool = false
    var scalingMode: ImageScalingMode = .fit

    private var cachedCGImage: CGImage?

    var cgImage: CGImage? { cachedCGImage }
    var hasImage: Bool { cachedCGImage != nil }

    var displayName: String { filename ?? "Untitled image" }

    var sizeText: String? {
        guard let image = cachedCGImage else { return nil }
        return "\(image.width) × \(image.height)"
    }

    /// Samples this layer into a brightness grid at the logical output size.
    func brightnessGrid(width: Int, height: Int) -> BrightnessGrid? {
        guard let cgImage else { return nil }
        return BrightnessGridSampler.sample(
            cgImage: cgImage,
            targetWidth: width,
            targetHeight: height,
            scalingMode: scalingMode,
            invert: inverted
        )
    }
}
