import Foundation
import ColorComposerCore

/// A value snapshot of the user-editable composition settings that participate
/// in undo/redo (issue #14). Images, server state, and solve results are
/// deliberately excluded — only tuning edits are undoable.
struct CompositionEdit: Sendable {
    var weights: ChannelWeights
    var scorerKind: ScorerKind
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelsPerCell: Int
    var layers: [Layer]

    /// The undoable per-layer settings, matched to a `SourceLayer` by identity.
    struct Layer: Sendable, Equatable {
        var id: UUID
        var assignedCondition: LightingCondition?
        var inverted: Bool
        var scalingMode: ImageScalingMode
        var colorSpace: BrightnessColorSpace
    }
}

/// One undoable layer-field change, carrying the pre-edit value so a restore
/// snapshot can be built after the fact.
enum LayerEdit: Sendable {
    case assignedCondition(LightingCondition?)
    case inverted(Bool)
    case scalingMode(ImageScalingMode)
    case colorSpace(BrightnessColorSpace)

    /// Identifies the field, distinguishing bursts of the same edit per layer.
    var key: String {
        switch self {
        case .assignedCondition: return "assignedCondition"
        case .inverted: return "inverted"
        case .scalingMode: return "scalingMode"
        case .colorSpace: return "colorSpace"
        }
    }

    /// Short Edit-menu action name, as in “Undo Invert”.
    var actionName: String {
        switch self {
        case .assignedCondition: return "Channel"
        case .inverted: return "Invert"
        case .scalingMode: return "Fit"
        case .colorSpace: return "Color"
        }
    }

    /// `layer` with this edit's field set back to its pre-edit value.
    func reverted(_ layer: CompositionEdit.Layer) -> CompositionEdit.Layer {
        var restored = layer
        switch self {
        case .assignedCondition(let oldValue): restored.assignedCondition = oldValue
        case .inverted(let oldValue): restored.inverted = oldValue
        case .scalingMode(let oldValue): restored.scalingMode = oldValue
        case .colorSpace(let oldValue): restored.colorSpace = oldValue
        }
        return restored
    }
}
