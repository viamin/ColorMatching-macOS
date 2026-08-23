import SwiftUI
import ColorComposerCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var previewMode: PreviewMode = .composite
    let addImages: () -> Void

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(addImages: addImages)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            PreviewPaneView(previewMode: $previewMode)
        }
        // Keep preview shortcuts active for the whole frontmost document
        // window, even while focus is in the sidebar or toolbar.
        .focusedSceneValue(\.previewModeBinding, $previewMode)
        // Reset the selected preview only when this window loads a different
        // document. Normal input edits should preserve the chosen tab.
        .onChange(of: model.documentStateID) {
            previewMode = .composite
        }
        .onAppear {
            model.attachUndoManager(undoManager)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addImages()
                } label: {
                    Label("Add Images", systemImage: "photo.on.rectangle.angled")
                }

                Button {
                    model.runSolve()
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .disabled(!model.canGenerate)

                Button {
                    FilePanels.exportImage { url in
                        do { try model.exportComposite(to: url) }
                        catch { NSAlert(error: error).runModal() }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExportComposite)

                Button {
                    model.printComposite()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(!model.canPrintComposite)

                if model.tilingEnabled {
                    Button {
                        FilePanels.chooseDirectory { url in
                            do { try model.exportTiles(to: url) }
                            catch { NSAlert(error: error).runModal() }
                        }
                    } label: {
                        Label("Export Tiles", systemImage: "square.grid.3x3")
                    }
                    .disabled(!model.canExportTiles)

                    Button {
                        model.printTiles()
                    } label: {
                        Label("Print Tiles", systemImage: "printer.filled.and.paper")
                    }
                    .disabled(!model.canPrintTiles)
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let addImages: () -> Void

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServerConfigurationSection()
                ProfileSection()
                SourceImagesSection(addImages: addImages)
                CompositionSettingsSection()
                TilingSettingsSection()
            }
            .padding()
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
