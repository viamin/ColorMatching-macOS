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

            HStack(spacing: 8) {
                Button("Test") { Task { await catalog.testConnection() } }
                    .disabled(catalog.isWorking)
                Button("Refresh") { Task { await catalog.refreshAll() } }
                    .disabled(catalog.isWorking)
                Button("Clear Cache") { catalog.clearCache() }
                    .disabled(catalog.isWorking)
            }
            .controlSize(.small)
            if let message = catalog.connectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(profile.displayName).tag(Int?.some(profile.id))
                }
                if let missingSelectedProfileID {
                    Text("Saved profile #\(missingSelectedProfileID)")
                        .tag(Int?.some(missingSelectedProfileID))
                }
            }

            LabeledContent("Colors loaded", value: "\(catalog.colors.count)")
            LabeledContent("Eligible for current weights", value: "\(model.eligibleColorCount)")
            if catalog.isServingFromCache {
                Label("Offline — cached colors", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The last fetch failed, so these colors were loaded from the local cache and may be stale.")
            } else if catalog.colorsLoadedFromProject {
                Label("Loaded from project snapshot", systemImage: "doc.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("These colors came from the opened project file rather than a live server fetch.")
            }
            if let refreshed = catalog.lastRefresh {
                LabeledContent(
                    catalog.isServingFromCache ? "Cached from" : "Last refreshed",
                    value: refreshed.formatted(.dateTime.month().day().hour().minute())
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: catalog.selectedPrinterProfileID) { _, _ in
            model.handleUpstreamChange()
        }
    }

    private var missingSelectedProfileID: Int? {
        guard let selectedProfileID = model.catalog.selectedPrinterProfileID else { return nil }
        guard !model.catalog.printerProfiles.contains(where: { $0.id == selectedProfileID }) else { return nil }
        return selectedProfileID
    }
}

// MARK: - Source images

struct SourceImagesSection: View {
    @Environment(AppModel.self) private var model
    let addImages: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source images").font(.headline)
                Spacer()
                Button(action: addImages) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(model.layers.enumerated()), id: \.element.id) { index, layer in
                SourceLayerRow(index: index, layer: layer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SourceLayerRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    @Bindable var layer: SourceLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if layer.hasImage, let cg = layer.cgImage {
                    ThumbnailView(cgImage: cg)
                } else {
                    Rectangle().fill(.quaternary).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.hasImage ? layer.displayName : "Empty slot \(index + 1)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = layer.sizeText {
                        Text(size).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                if layer.hasImage {
                    Button { model.removeLayer(index) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Channel")
                        .foregroundStyle(.secondary)
                    Picker("Channel", selection: assignedConditionBinding) {
                        Text("—").tag(LightingCondition?.none)
                        ForEach(LightingCondition.all, id: \.self) { c in
                            Text(c.displayName).tag(LightingCondition?.some(c))
                        }
                    }
                    .labelsHidden()
                    .disabled(!layer.hasImage)
                }
                GridRow {
                    Text("Fit")
                        .foregroundStyle(.secondary)
                    Picker("Fit", selection: scalingModeBinding) {
                        ForEach(ImageScalingMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .disabled(!layer.hasImage)
                }
                GridRow {
                    Text("Color")
                        .foregroundStyle(.secondary)
                    Picker("Color", selection: $layer.colorSpace) {
                        ForEach(BrightnessColorSpace.allCases, id: \.self) { space in
                            Text(space.rawValue.capitalized).tag(space)
                        }
                    }
                    .labelsHidden()
                    .disabled(!layer.hasImage)
                }
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                        .frame(width: 0, height: 0)
                    Toggle("Invert", isOn: invertedBinding)
                        .toggleStyle(.checkbox)
                        .disabled(!layer.hasImage)
                }
            }
            .font(.caption)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: layer.colorSpace) {
            guard layer.hasImage else { return }
            model.handleUpstreamChange()
        }
    }

    private var assignedConditionBinding: Binding<LightingCondition?> {
        Binding(
            get: { layer.assignedCondition },
            set: { model.setLayerAssignedCondition(index, to: $0) }
        )
    }

    private var scalingModeBinding: Binding<ImageScalingMode> {
        Binding(
            get: { layer.scalingMode },
            set: { model.setLayerScalingMode(index, to: $0) }
        )
    }

    private var invertedBinding: Binding<Bool> {
        Binding(
            get: { layer.inverted },
            set: { model.setLayerInverted(index, to: $0) }
        )
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

            VStack(alignment: .leading, spacing: 4) {
                Stepper("Logical width: \(model.logicalWidth)", value: logicalWidthBinding, in: 10...1000, step: 10)
                Stepper("Logical height: \(model.logicalHeight)", value: logicalHeightBinding, in: 10...1000, step: 10)
            }
            Picker("Preset", selection: Binding(
                get: { model.logicalWidth },
                set: { model.setLogicalSize(width: $0, height: $0) }
            )) {
                ForEach(model.presetSizes, id: \.size) { preset in
                    Text(preset.label).tag(preset.size)
                }
            }

            Stepper("Export pixels/cell: \(model.pixelsPerCell)", value: pixelsPerCellBinding, in: 1...32)

            Picker("Raster mode", selection: $model.rasterMode) {
                ForEach(RasterMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Stepper("Print size (mm): \(Int(model.physicalWidthMM))", value: $model.physicalWidthMM, in: 10...2000, step: 5)
                Stepper("Print height (mm): \(Int(model.physicalHeightMM))", value: $model.physicalHeightMM, in: 10...2000, step: 5)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.scorerKind) { model.handleUpstreamChange() }
    }

    private func weightBinding(_ keyPath: WritableKeyPath<ChannelWeights, Double>) -> Binding<Double> {
        Binding(
            get: { model.weights[keyPath: keyPath] },
            set: { model.setWeight(keyPath, to: $0) }
        )
    }

    private var logicalWidthBinding: Binding<Int> {
        Binding(
            get: { model.logicalWidth },
            set: { model.setLogicalWidth($0) }
        )
    }

    private var logicalHeightBinding: Binding<Int> {
        Binding(
            get: { model.logicalHeight },
            set: { model.setLogicalHeight($0) }
        )
    }

    private var pixelsPerCellBinding: Binding<Int> {
        Binding(
            get: { model.pixelsPerCell },
            set: { model.setPixelsPerCell($0) }
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
                VStack(alignment: .leading, spacing: 4) {
                    Stepper("Tile size (mm): \(Int(model.tileWidthMM))", value: $model.tileWidthMM, in: 10...2000, step: 5)
                    Stepper("Tile height (mm): \(Int(model.tileHeightMM))", value: $model.tileHeightMM, in: 10...2000, step: 5)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
