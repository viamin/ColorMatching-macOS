import SwiftUI
import ColorComposerCore

// MARK: - Server configuration

struct ServerConfigurationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var catalog = model.catalog
        VStack(alignment: .leading, spacing: 8) {
            Text("Server").font(.headline)
            TextField("Base URL", text: $model.serverBaseURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API token (optional)", text: $model.serverToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Test") { Task { await catalog.testConnection() } }
                    .disabled(catalog.isWorking)
                Button("Refresh") { Task { await catalog.refreshAll() } }
                    .disabled(catalog.isWorking)
            }
            if let message = catalog.connectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Profile & colors

struct ProfileSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var catalog = model.catalog
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile & colors").font(.headline)

            Picker("Printer profile", selection: $catalog.selectedPrinterProfileID) {
                Text("None").tag(Int?.none)
                ForEach(catalog.printerProfiles) { profile in
                    Text(profileLabel(profile)).tag(Int?.some(profile.id))
                }
            }

            LabeledContent("Colors loaded", value: "\(catalog.colors.count)")
            LabeledContent("Eligible for current weights", value: "\(model.eligibleColorCount)")
            if let refreshed = catalog.lastRefresh {
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

                Picker("Color", selection: $layer.colorSpace) {
                    ForEach(BrightnessColorSpace.allCases, id: \.self) { space in
                        Text(space.rawValue.capitalized).tag(space)
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
        .onChange(of: layer.inverted) { model.scheduleAutoRegenerate() }
        .onChange(of: layer.scalingMode) { model.scheduleAutoRegenerate() }
        .onChange(of: layer.assignedCondition) { model.scheduleAutoRegenerate() }
        .onChange(of: layer.colorSpace) { model.scheduleAutoRegenerate() }
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
            Stepper("Bleed (mm): \(Int(model.printBleedMM))", value: $model.printBleedMM, in: 0...50, step: 1)
            Toggle("Crop + registration marks", isOn: $model.showsPrintMarks)
            Stepper("Mark inset (mm): \(Int(model.printMarksInsetMM))", value: $model.printMarksInsetMM, in: 0...50, step: 1)
                .disabled(!model.showsPrintMarks)

            Divider()
            Picker("Scorer", selection: $model.scorerKind) {
                ForEach(ScorerKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            Toggle("Auto-regenerate on settings change", isOn: $model.autoRegenerate)
                .font(.subheadline)

            Divider()
            Text("Channel weights").font(.subheadline)
            WeightSlider("White", value: weightBinding(\.white))
            WeightSlider("Red", value: weightBinding(\.red))
            WeightSlider("Green", value: weightBinding(\.green))
            WeightSlider("Blue", value: weightBinding(\.blue))
            WeightSlider("LPS", value: weightBinding(\.lps))

            if model.catalog.colors.count > 0 && model.eligibleColorCount == 0 {
                Label(
                    "No loaded colors have measurements for all active channels. Generate will produce no output — pick a profile whose colors have measurements, or lower the active weights.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: model.weights) { model.scheduleAutoRegenerate() }
        .onChange(of: model.logicalWidth) { model.scheduleAutoRegenerate() }
        .onChange(of: model.logicalHeight) { model.scheduleAutoRegenerate() }
        .onChange(of: model.scorerKind) { model.scheduleAutoRegenerate() }
    }

    private func weightBinding(_ keyPath: WritableKeyPath<ChannelWeights, Double>) -> Binding<Double> {
        Binding(
            get: { model.weights[keyPath: keyPath] },
            set: { model.weights[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Large-format tiling

struct TilingSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("Large-format tiling").font(.headline)

            Toggle("Split into page-sized tiles", isOn: $model.tilingEnabled)

            if model.tilingEnabled {
                HStack {
                    Stepper("Tile size (mm): \(Int(model.tileWidthMM))", value: $model.tileWidthMM, in: 10...2000, step: 5)
                    Stepper("× \(Int(model.tileHeightMM))", value: $model.tileHeightMM, in: 10...2000, step: 5)
                }
                Stepper("Overlap (mm): \(Int(model.tileOverlapMM))", value: $model.tileOverlapMM, in: 0...200, step: 1)

                if let tiles = model.tilePlan {
                    let columns = Set(tiles.map(\.column)).count
                    let rows = Set(tiles.map(\.row)).count
                    Text("\(tiles.count) tile(s) — \(columns) × \(rows)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
