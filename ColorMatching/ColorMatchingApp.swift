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
                .task { model.catalog.configure(baseURL: URL(string: model.serverBaseURL), token: model.serverToken) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { newProject() }.keyboardShortcut("n")
                Button("Open Project…") { openProject() }.keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Save Project") { saveProject() }.keyboardShortcut("s")
                Button("Save Project As…") { saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Export Composite…") { exportComposite() }.keyboardShortcut("e")
                Button("Print…") { model.printComposite() }.keyboardShortcut("p")
                    .disabled(!model.hasResult)
            }
            PreviewCommands(model: model)
            WorkflowCommands(model: model, addImages: addImages)
        }
    }

    private func newProject() {
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
            Button("Add Images…", action: addImages)
                .keyboardShortcut("o", modifiers: [.command, .option])

            Button("Generate") { model.runSolve() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.catalog.colors.isEmpty)
        }
    }
}

private struct PreviewCommands: Commands {
    let model: AppModel
    @FocusedBinding(\.selectedPreviewMode) private var selectedPreviewMode: PreviewMode?

    var body: some Commands {
        CommandMenu("Preview") {
            previewButton("Composite", mode: .composite, key: "1")
            previewButton("Error Map", mode: .errorMap, key: "2")
            Divider()
            previewButton("Red", mode: .lighting(.red), key: "3")
            previewButton("Green", mode: .lighting(.green), key: "4")
            previewButton("Blue", mode: .lighting(.blue), key: "5")
            previewButton("LPS", mode: .lighting(.lps), key: "6")
            Button("White") { selectedPreviewMode = .lighting(.white) }
                .disabled(!canSelect(.lighting(.white)))
            Divider()
            Button("Gamut") { selectedPreviewMode = .gamut }
                .disabled(!canSelect(.gamut))
        }
    }

    private func previewButton(_ title: String, mode: PreviewMode, key: KeyEquivalent) -> some View {
        Button(title) { selectedPreviewMode = mode }
            .keyboardShortcut(key)
            .disabled(!canSelect(mode))
    }

    private func canSelect(_ mode: PreviewMode) -> Bool {
        guard selectedPreviewMode != nil else { return false }
        guard model.hasResult else { return mode == .composite || mode == .errorMap || mode == .gamut }
        return true
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
}
