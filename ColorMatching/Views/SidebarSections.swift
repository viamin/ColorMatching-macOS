import SwiftUI
import ColorComposerCore

// MARK: - Server configuration

struct ServerConfigurationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var palette = model.palette
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.headline)
            TextField("Base URL", text: $model.serverBaseURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API token (optional)", text: $model.serverToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Test") { Task { await palette.testConnection() } }
                    .disabled(palette.isWorking)
                Button("Refresh") { Task { await palette.refreshAll() } }
                    .disabled(palette.isWorking)
            }
            if let message = palette.connectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Palette

struct PaletteSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var palette = model.palette
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette").font(.headline)

            Picker("Printer profile", selection: $palette.selectedPrinterProfileID) {
                Text("None").tag(Int?.none)
                ForEach(palette.printerProfiles) { profile in
                    Text(profileLabel(profile)).tag(Int?.some(profile.id))
                }
            }

            Picker("Palette", selection: $palette.selectedPaletteID) {
                Text("All colors").tag(Int?.none)
                ForEach(palette.palettes) { p in
                    Text("\(p.name) (\(p.colorCount))").tag(Int?.some(p.id))
                }
            }
            .onChange(of: palette.selectedPaletteID) { _, _ in
                Task { await palette.refreshAll() }
            }

            LabeledContent("Colors loaded", value: "\(palette.colors.count)")
            LabeledContent("Eligible for current weights", value: "\(model.eligiblePaletteCount)")
            if let refreshed = palette.lastRefresh {
                LabeledContent("Last refreshed", value: refreshed.formatted(.dateTime.month().day().hour().minute()))
            }
        }
    }

    private func profileLabel(_ profile: PrinterProfileDTO) -> String {
        let parts = [profile.printerMakeModel, profile.paperType].compactMap { $0 }
        return parts.isEmpty ? "Profile #\(profile.id)" : parts.joined(separator: " · ")
    }
}

// MARK: - Source images

struct SourceImagesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source images").font(.headline)
                Spacer()
                Button {
                    FilePanels.openImages { urls in
                        model.appendImages(from: urls)
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(model.layers.enumerated()), id: \.element.id) { index, layer in
                SourceLayerRow(index: index, layer: layer)
            }
        }
    }
}

struct SourceLayerRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    @Bindable var layer: SourceLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if layer.hasImage, let cg = layer.cgImage {
                    ThumbnailView(cgImage: cg)
                } else {
                    Rectangle().fill(.quaternary).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading) {
                    Text(layer.hasImage ? layer.displayName : "Empty slot \(index + 1)")
                        .font(.callout)
                    if let size = layer.sizeText {
                        Text(size).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if layer.hasImage {
                    Button { model.removeLayer(index) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Picker("Channel", selection: $layer.assignedCondition) {
                    Text("—").tag(LightingCondition?.none)
                    ForEach(LightingCondition.all, id: \.self) { c in
                        Text(c.displayName).tag(LightingCondition?.some(c))
                    }
                }
                .labelsHidden()
                .disabled(!layer.hasImage)

                Picker("Fit", selection: $layer.scalingMode) {
                    ForEach(ImageScalingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .labelsHidden()
                .disabled(!layer.hasImage)

                Toggle("Invert", isOn: $layer.inverted)
                    .toggleStyle(.checkbox)
                    .disabled(!layer.hasImage)
            }
        }
        .padding(6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ThumbnailView: NSViewRepresentable {
    let cgImage: CGImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(cgImage: cgImage, size: NSSize(width: 40, height: 40))
        view.imageScaling = .scaleProportionallyDown
        return view
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

// MARK: - Composition settings

struct CompositionSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Composition").font(.headline)

            HStack {
                Stepper("Logical width: \(model.logicalWidth)", value: $model.logicalWidth, in: 10...1000, step: 10)
                Stepper("height: \(model.logicalHeight)", value: $model.logicalHeight, in: 10...1000, step: 10)
            }
            Picker("Preset", selection: Binding(
                get: { model.logicalWidth },
                set: { model.logicalWidth = $0; model.logicalHeight = $0 }
            )) {
                ForEach(model.presetSizes, id: \.size) { preset in
                    Text(preset.label).tag(preset.size)
                }
            }

            Stepper("Export pixels/cell: \(model.pixelsPerCell)", value: $model.pixelsPerCell, in: 1...32)

            HStack {
                Stepper("Print size (mm): \(Int(model.physicalWidthMM))", value: $model.physicalWidthMM, in: 10...2000, step: 5)
                Stepper("× \(Int(model.physicalHeightMM))", value: $model.physicalHeightMM, in: 10...2000, step: 5)
            }

            Divider()
            Text("Channel weights").font(.subheadline)
            WeightSlider("White", value: weightBinding(\.white))
            WeightSlider("Red", value: weightBinding(\.red))
            WeightSlider("Green", value: weightBinding(\.green))
            WeightSlider("Blue", value: weightBinding(\.blue))
            WeightSlider("LPS", value: weightBinding(\.lps))

            if model.palette.colors.count > 0 && model.eligiblePaletteCount == 0 {
                Label(
                    "No loaded colors have measurements for all active channels. Generate will produce no output — pick a palette/profile with measurements (e.g. “Cool” on “Generic Inkjet”) or lower the active weights.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func weightBinding(_ keyPath: WritableKeyPath<ChannelWeights, Double>) -> Binding<Double> {
        Binding(
            get: { model.weights[keyPath: keyPath] },
            set: { model.weights[keyPath: keyPath] = $0 }
        )
    }
}

private struct WeightSlider: View {
    let label: String
    @Binding var value: Double

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 50, alignment: .leading)
            Slider(value: $value, in: 0...5)
            Text(String(format: "%.2f", value))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }
}
