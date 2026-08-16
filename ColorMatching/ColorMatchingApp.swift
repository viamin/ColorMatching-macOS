import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ColorMatchingApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { newProject() }.keyboardShortcut("n")
                Button("Open Project…") { openProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                // ⇧⌘E matches Apple's Export convention (Notes, Pages); plain ⌘E
                // would shadow the system-wide "Use Selection for Find".
                Button("Export Composite…") { exportComposite() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExportComposite)
                if model.tilingEnabled {
                    Divider()
                    Button("Export Tiles…") { exportTiles() }
                        .disabled(!model.canExportTiles)
                    Button("Print Tiles") { model.printTiles() }
                        .disabled(!model.canExportTiles)
                }
            }
            // Replaces the default ⌘P print item so the File menu carries only
            // one Print… command, bound to the generated composition.
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.printComposite() }.keyboardShortcut("p")
                    .disabled(!model.canExportComposite)
            }
            PreviewCommands()
            WorkflowCommands(model: model, addImages: addImages)
        }
    }

    private func newProject() {
        model.cancelPendingWork()
        model = AppModel()
    }

    private func openProject() {
        FilePanels.openProject { url in
            do { try model.loadProject(from: url) }
            catch { NSApp.presentError(error) }
        }
    }

    private func saveProject() {
        if let url = model.projectURL {
            do { try model.saveProject(to: url) }
            catch { NSApp.presentError(error) }
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        FilePanels.saveProject { url in
            do { try model.saveProject(to: url) }
            catch { NSApp.presentError(error) }
        }
    }

    private func exportComposite() {
        FilePanels.exportImage { url in
            do { try model.exportComposite(to: url) }
            catch { NSApp.presentError(error) }
        }
    }

    private func exportTiles() {
        FilePanels.chooseDirectory { url in
            do { try model.exportTiles(to: url) }
            catch { NSApp.presentError(error) }
        }
    }

    private func addImages() {
        FilePanels.openImages { urls in
            model.appendImages(from: urls)
        }
    }
}

private struct WorkflowCommands: Commands {
    let model: AppModel
    let addImages: () -> Void

    var body: some Commands {
        CommandMenu("Actions") {
            Button("Add Images…") { addImages() }
                .keyboardShortcut("o", modifiers: [.command, .option])

            Button("Generate") { model.runSolve() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canGenerate)
        }
    }
}

private struct PreviewCommands: Commands {
    @FocusedValue(\.previewModeBinding) private var previewModeBinding

    var body: some Commands {
        CommandMenu("Preview") {
            // Keep numbering explicit in the menu so the visible order always
            // matches the documented shortcuts and the LightingCondition test.
            Button(PreviewMode.composite.menuTitle) { setPreview(.composite) }.keyboardShortcut("1")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.errorMap.menuTitle) { setPreview(.errorMap) }.keyboardShortcut("2")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.gamut.menuTitle) { setPreview(.gamut) }.keyboardShortcut("3")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.lighting(.white).menuTitle) { setPreview(.lighting(.white)) }.keyboardShortcut("4")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.lighting(.red).menuTitle) { setPreview(.lighting(.red)) }.keyboardShortcut("5")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.lighting(.green).menuTitle) { setPreview(.lighting(.green)) }.keyboardShortcut("6")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.lighting(.blue).menuTitle) { setPreview(.lighting(.blue)) }.keyboardShortcut("7")
                .disabled(!hasFocusedPreview)
            Button(PreviewMode.lighting(.lps).menuTitle) { setPreview(.lighting(.lps)) }.keyboardShortcut("8")
                .disabled(!hasFocusedPreview)
        }
    }

    private var hasFocusedPreview: Bool {
        previewModeBinding != nil
    }

    private func setPreview(_ mode: PreviewMode) {
        previewModeBinding?.wrappedValue = mode
    }
}

/// Native file-panel helpers.
enum FilePanels {
    static func openProject(onComplete: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cmpj") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { onComplete(url) }
    }

    static func saveProject(onComplete: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cmpj") ?? .json]
        panel.nameFieldStringValue = "Composition.cmpj"
        if panel.runModal() == .OK, let url = panel.url { onComplete(url) }
    }

    static func exportImage(onComplete: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff]
        panel.nameFieldStringValue = "Composite.png"
        if panel.runModal() == .OK, let url = panel.url { onComplete(url) }
    }

    static func openImages(onComplete: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { onComplete(panel.urls) }
    }

    /// Prompts for a destination folder, used to export one image file per
    /// tile for large-format artwork.
    static func chooseDirectory(onComplete: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { onComplete(url) }
    }
}
