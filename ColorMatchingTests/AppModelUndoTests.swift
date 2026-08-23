import XCTest
import AppKit
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

    func testLoadProjectClearsUndoHistoryBeforeReplacingDocument() throws {
        let model = AppModel()
        let undoManager = UndoManager()
        let replacement = AppModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        model.setUndoManager(undoManager)
        model.setWeight(\.red, to: 2.5)
        replacement.setLogicalSize(width: 320, height: 180)
        try replacement.saveProject(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try model.loadProject(from: url)

        XCTAssertEqual(model.logicalWidth, 320)
        XCTAssertEqual(model.logicalHeight, 180)
        XCTAssertFalse(model.canUndo)

        model.undo()

        XCTAssertEqual(model.logicalWidth, 320)
        XCTAssertEqual(model.logicalHeight, 180)
        XCTAssertEqual(model.weights.red, 1)
        XCTAssertFalse(model.canRedo)
    }

    func testReplacingLayerUndoesToPreviousLayerStateBeforeOlderLayerEdits() throws {
        let model = AppModel()
        let undoManager = UndoManager()
        let firstURL = try makeImageFile(named: "first", color: .white)
        let secondURL = try makeImageFile(named: "second", color: .black)

        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        model.setUndoManager(undoManager)
        XCTAssertTrue(model.loadLayer(0, from: firstURL))
        model.setLayerScalingMode(0, to: .fill)
        XCTAssertTrue(model.loadLayer(0, from: secondURL))

        XCTAssertEqual(model.layers[0].filename, secondURL.lastPathComponent)
        XCTAssertEqual(model.layers[0].scalingMode, .fill)
        XCTAssertEqual(model.layers[0].imageData, try Data(contentsOf: secondURL))

        model.undo()

        XCTAssertEqual(model.layers[0].filename, firstURL.lastPathComponent)
        XCTAssertEqual(model.layers[0].scalingMode, .fill)
        XCTAssertEqual(model.layers[0].imageData, try Data(contentsOf: firstURL))

        model.undo()

        XCTAssertEqual(model.layers[0].scalingMode, .fit)
    }

    func testRemovingLayerUndoesToPreviousLayerStateBeforeOlderLayerEdits() throws {
        let model = AppModel()
        let undoManager = UndoManager()
        let imageURL = try makeImageFile(named: "source", color: .white)

        defer { try? FileManager.default.removeItem(at: imageURL) }

        model.setUndoManager(undoManager)
        XCTAssertTrue(model.loadLayer(0, from: imageURL))
        model.setLayerInverted(0, to: true)
        model.removeLayer(0)

        XCTAssertNil(model.layers[0].imageData)

        model.undo()

        XCTAssertEqual(model.layers[0].filename, imageURL.lastPathComponent)
        XCTAssertTrue(model.layers[0].inverted)

        model.undo()

        XCTAssertFalse(model.layers[0].inverted)
    }

    private func makeImageFile(named name: String, color: NSColor) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("png")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Failed to build test image")
            throw TestImageError.buildFailed
        }

        try pngData.write(to: url)
        return url
    }

    private enum TestImageError: Error {
        case buildFailed
    }
}
