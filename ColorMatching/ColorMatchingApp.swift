import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum SceneIDs {
    static let document = "document"
}

@MainActor
@Observable
private final class PendingProjectOpen {
    static let shared = PendingProjectOpen()

    private var pendingURLs: [URL] = []

    func stage(_ url: URL) {
        pendingURLs.append(url)
    }

    func consume() -> URL? {
        guard !pendingURLs.isEmpty else { return nil }
        return pendingURLs.removeFirst()
    }
}

@main
struct ColorMatchingApp: App {
    var body: some Scene {
        WindowGroup(id: SceneIDs.document) {
            DocumentSceneView()
        }
        .commands {
            DocumentCommands()
            PreviewCommands()
            WorkflowCommands()
        }
    }
}

private struct DocumentSceneView: View {
    @State private var model = AppModel()

    var body: some View {
        ContentView(addImages: addImages)
            .environment(model)
            .frame(minWidth: 1100, minHeight: 720)
            // Route menu shortcuts through the frontmost window's document
            // state instead of a process-wide model shared by every scene.
            .focusedSceneValue(\.documentCommandContext, commandContext)
            .task {
                consumePendingProjectIfNeeded()
            }
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

    private func consumePendingProjectIfNeeded() {
        // Only a newly created scene should consume a staged open request.
        // Existing windows observing a shared "pending open" signal can race the
        // new window and load the project into the wrong document.
        guard let url = PendingProjectOpen.shared.consume() else { return }
        do { try model.loadProject(from: url) }
        catch { NSApp.presentError(error) }
    }

    private var commandContext: DocumentCommandContext {
        DocumentCommandContext(
            openProject: openProject,
            saveProject: saveProject,
            saveProjectAs: saveProjectAs,
            exportComposite: exportComposite,
            exportTiles: exportTiles,
            printComposite: model.printComposite,
            printTiles: model.printTiles,
            addImages: addImages,
            generate: model.runSolve,
            tilingEnabled: model.tilingEnabled,
            canGenerate: model.canGenerate,
            canExportComposite: model.canExportComposite,
            canExportTiles: model.canExportTiles
        )
    }
}

private struct DocumentCommandContext {
    let openProject: () -> Void
    let saveProject: () -> Void
    let saveProjectAs: () -> Void
    let exportComposite: () -> Void
    let exportTiles: () -> Void
    let printComposite: () -> Void
    let printTiles: () -> Void
    let addImages: () -> Void
    let generate: () -> Void
    let tilingEnabled: Bool
    let canGenerate: Bool
    let canExportComposite: Bool
    let canExportTiles: Bool
}

private struct DocumentCommandContextKey: FocusedValueKey {
    typealias Value = DocumentCommandContext
}

extension FocusedValues {
    var documentCommandContext: DocumentCommandContext? {
        get { self[DocumentCommandContextKey.self] }
        set { self[DocumentCommandContextKey.self] = newValue }
    }
}

private struct DocumentCommands: Commands {
    @FocusedValue(\.documentCommandContext) private var context
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { newProject() }
                .keyboardShortcut("n")
            Button("Open Project…") { openProject() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { context?.saveProject() }
                .keyboardShortcut("s")
                .disabled(context == nil)
            Button("Save Project As…") { context?.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(context == nil)
            Divider()
            // ⇧⌘E matches Apple's Export convention (Notes, Pages); plain ⌘E
            // would shadow the system-wide "Use Selection for Find".
            Button("Export Composite…") { context?.exportComposite() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(context?.canExportComposite ?? false))
            if context?.tilingEnabled == true {
                Divider()
                Button("Export Tiles…") { context?.exportTiles() }
                    .disabled(!(context?.canExportTiles ?? false))
                Button("Print Tiles") { context?.printTiles() }
                    .disabled(!(context?.canExportTiles ?? false))
            }
        }
        // Replaces the default ⌘P print item so the File menu carries only
        // one Print… command, bound to the generated composition.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { context?.printComposite() }
                .keyboardShortcut("p")
                .disabled(!(context?.canExportComposite ?? false))
        }
    }

    private func newProject() {
        openWindow(id: SceneIDs.document)
    }

    private func openProject() {
        if let context {
            context.openProject()
            return
        }
        FilePanels.openProject { url in
            PendingProjectOpen.shared.stage(url)
            openWindow(id: SceneIDs.document)
        }
    }
}

private struct WorkflowCommands: Commands {
    @FocusedValue(\.documentCommandContext) private var context

    var body: some Commands {
        CommandMenu("Actions") {
            Button("Add Images…") { context?.addImages() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(context == nil)

            Button("Generate") { context?.generate() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!(context?.canGenerate ?? false))
        }
    }
}

private struct PreviewCommands: Commands {
    @FocusedValue(\.previewModeBinding) private var previewModeBinding

    var body: some Commands {
        CommandMenu("Preview") {
            ForEach(PreviewMode.orderedModes) { mode in
                Button(mode.menuTitle) { setPreview(mode) }
                    .keyboardShortcut(mode.shortcutKey)
                    .disabled(!hasFocusedPreview)
            }
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
