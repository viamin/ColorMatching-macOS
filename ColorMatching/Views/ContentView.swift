import SwiftUI
import ColorComposerCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let modelIdentity = ObjectIdentifier(model)
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            PreviewPaneView()
                // A brand-new project swaps in a new AppModel; rebuilding the
                // preview pane resets its per-window tab/compare state to the
                // default Composite / Predicted selection for that project.
                .id(modelIdentity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    FilePanels.openImages { urls in
                        model.appendImages(from: urls)
                    }
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
                .disabled(!model.canExportComposite)

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
                    .disabled(!model.canExportTiles)
                }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ServerConfigurationSection()
                ProfileSection()
                SourceImagesSection()
                CompositionSettingsSection()
                TilingSettingsSection()
            }
            .padding()
        }
    }
}
