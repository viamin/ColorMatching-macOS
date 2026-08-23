import XCTest
@testable import ColorMatching
import ColorComposerCore

@MainActor
final class AppModelUndoTests: XCTestCase {
    func testWeightChangesUndoAndRedo() {
        let model = AppModel()
        let undoManager = UndoManager()

        model.setUndoManager(undoManager)
        model.setWeight(\.red, to: 2.5)

        XCTAssertEqual(model.weights.red, 2.5)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(model.undoMenuTitle, "Undo Change Weight")

        model.undo()

        XCTAssertEqual(model.weights.red, 1)
        XCTAssertTrue(model.canRedo)
        XCTAssertEqual(model.redoMenuTitle, "Redo Change Weight")

        model.redo()

        XCTAssertEqual(model.weights.red, 2.5)
    }

    func testResolutionPresetUndoesAsSingleEdit() {
        let model = AppModel()
        let undoManager = UndoManager()

        model.setUndoManager(undoManager)
        model.setLogicalSize(width: 500, height: 500)

        XCTAssertEqual(model.logicalWidth, 500)
        XCTAssertEqual(model.logicalHeight, 500)

        model.undo()

        XCTAssertEqual(model.logicalWidth, 200)
        XCTAssertEqual(model.logicalHeight, 200)
    }

    func testLayerEditUndoRestoresAssignmentScalingAndInversion() {
        let model = AppModel()
        let undoManager = UndoManager()

        model.setUndoManager(undoManager)
        model.setLayerAssignedCondition(0, to: .blue)
        model.setLayerScalingMode(0, to: .fill)
        model.setLayerInverted(0, to: true)

        XCTAssertEqual(model.layers[0].assignedCondition, .blue)
        XCTAssertEqual(model.layers[0].scalingMode, .fill)
        XCTAssertTrue(model.layers[0].inverted)

        model.undo()
        XCTAssertFalse(model.layers[0].inverted)

        model.undo()
        XCTAssertEqual(model.layers[0].scalingMode, .fit)

        model.undo()
        XCTAssertNil(model.layers[0].assignedCondition)
    }
}
