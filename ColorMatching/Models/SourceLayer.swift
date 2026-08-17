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

    /// Informs the owner when an undoable field changes so the edit can be
    /// registered with the undo manager (issue #14).
    var onUndoableEdit: ((SourceLayer, LayerEdit) -> Void)?

    var assignedCondition: LightingCondition? {
        didSet {
            guard oldValue != assignedCondition else { return }
            onUndoableEdit?(self, .assignedCondition(oldValue))
        }
    }
    var inverted: Bool = false {
        didSet {
            guard oldValue != inverted else { return }
            onUndoableEdit?(self, .inverted(oldValue))
        }
    }
    var scalingMode: ImageScalingMode = .fit {
        didSet {
            guard oldValue != scalingMode else { return }
            onUndoableEdit?(self, .scalingMode(oldValue))
        }
    }
    var colorSpace: BrightnessColorSpace = .gamma {
        didSet {
            guard oldValue != colorSpace else { return }
            onUndoableEdit?(self, .colorSpace(oldValue))
        }
    }

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
            invert: inverted,
            colorSpace: colorSpace
        )
    }
}
