import SwiftUI
import ColorComposerCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            PreviewPaneView()
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
                .disabled(model.catalog.colors.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])

                Button {
                    FilePanels.exportImage { url in
                        do { try model.exportComposite(to: url) }
                        catch { NSAlert(error: error).runModal() }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasResult)

                Button {
                    model.printComposite()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(!model.hasResult)
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
            }
            .padding()
        }
    }
}
