import XCTest
import ColorComposerCore
@testable import ColorMatching

@MainActor
final class AppModelUndoTests: XCTestCase {
    func testWeightChangesUndoAndRedo() {
        let (model, undoManager) = makeModel()

        model.setWeight(\.red, to: 2.5)

        XCTAssertEqual(model.weights.red, 2.5, accuracy: 1e-9)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Change Weight")

        undoManager.undo()

        XCTAssertEqual(model.weights.red, 1.0, accuracy: 1e-9)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()

        XCTAssertEqual(model.weights.red, 2.5, accuracy: 1e-9)
    }

    func testResolutionAndExportScalingChangesUndoAndRedo() {
        let (model, undoManager) = makeModel()

        model.setLogicalSize(width: 500, height: 500)
        model.setPixelsPerCell(12)

        XCTAssertEqual(model.logicalWidth, 500)
        XCTAssertEqual(model.logicalHeight, 500)
        XCTAssertEqual(model.pixelsPerCell, 12)

        undoManager.undo()
        XCTAssertEqual(model.pixelsPerCell, 4)

        undoManager.undo()
        XCTAssertEqual(model.logicalWidth, 200)
        XCTAssertEqual(model.logicalHeight, 200)

        undoManager.redo()
        XCTAssertEqual(model.logicalWidth, 500)
        XCTAssertEqual(model.logicalHeight, 500)

        undoManager.redo()
        XCTAssertEqual(model.pixelsPerCell, 12)
    }

    func testLayerEditsUndoInReverseOrder() {
        let (model, undoManager) = makeModel()

        model.setLayerAssignedCondition(.red, for: 0)
        model.setLayerScalingMode(.fill, for: 0)
        model.setLayerInverted(true, for: 0)

        XCTAssertEqual(model.layers[0].assignedCondition, .red)
        XCTAssertEqual(model.layers[0].scalingMode, .fill)
        XCTAssertTrue(model.layers[0].inverted)

        undoManager.undo()
        XCTAssertFalse(model.layers[0].inverted)

        undoManager.undo()
        XCTAssertEqual(model.layers[0].scalingMode, .fit)

        undoManager.undo()
        XCTAssertNil(model.layers[0].assignedCondition)

        undoManager.redo()
        XCTAssertEqual(model.layers[0].assignedCondition, .red)

        undoManager.redo()
        XCTAssertEqual(model.layers[0].scalingMode, .fill)

        undoManager.redo()
        XCTAssertTrue(model.layers[0].inverted)
    }

    func testLoadingProjectClearsUndoHistory() throws {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        let projectURL = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let sourceModel = AppModel()
        sourceModel.setLogicalSize(width: 100, height: 100)
        try sourceModel.saveProject(to: projectURL)

        let (model, undoManager) = makeModel()
        model.setWeight(\.blue, to: 3.0)
        XCTAssertTrue(undoManager.canUndo)

        try model.loadProject(from: projectURL)

        XCTAssertEqual(model.logicalWidth, 100)
        XCTAssertEqual(model.logicalHeight, 100)
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
    }

    private func makeModel() -> (AppModel, UndoManager) {
        let model = AppModel()
        let undoManager = UndoManager()
        model.attachUndoManager(undoManager)
        return (model, undoManager)
    }
}
