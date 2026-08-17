import SwiftUI
import ColorComposerCore

enum PreviewMode: Hashable, CaseIterable, Identifiable {
    case composite
    case errorMap
    case gamut
    case lighting(LightingCondition)

    var id: Self { self }

    var label: String {
        switch self {
        case .composite: return "Composite"
        case .errorMap: return "Error Map"
        case .gamut: return "Gamut"
        case .lighting(let condition): return "Preview · \(condition.displayName)"
        }
    }

    static var allCases: [PreviewMode] {
        [.composite, .errorMap, .gamut] + LightingCondition.all.map { .lighting($0) }
    }
}

/// Per-channel comparison options, shown when a lighting preview is selected so
/// the predicted appearance can be switched against the source it came from and
/// their signed difference.
enum LightingCompareMode: Hashable, CaseIterable, Identifiable {
    case predicted
    case source
    case difference

    var id: Self { self }

    var label: String {
        switch self {
        case .predicted: return "Predicted"
        case .source: return "Source"
        case .difference: return "Difference"
        }
    }
}

struct PreviewPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: PreviewMode = .composite
    @State private var compareMode: LightingCompareMode = .predicted
    @State private var softProofEnabled = false

    var body: some View {
        let softProofPreview = softProofPreviewSelection

        VStack(spacing: 0) {
            previewPicker(softProofPreview: softProofPreview)
            Divider()
            content(softProofPreview: softProofPreview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasResult {
                Divider()
                StatisticsBar()
                    .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func previewPicker(softProofPreview: SoftProofPreview?) -> some View {
        VStack(spacing: 8) {
            Picker("Preview", selection: $mode) {
                ForEach(PreviewMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if mode == .composite, model.hasResult {
                HStack(spacing: 12) {
                    Toggle("Soft Proof", isOn: $softProofEnabled)
                        .toggleStyle(.switch)
                    Spacer()
                    if let preview = softProofPreview {
                        Text(softProofStatus(for: preview, profileName: model.softProofProfileName))
                            .font(.caption)
                            .foregroundStyle(preview.outOfGamutCount > 0 ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func content(softProofPreview: SoftProofPreview?) -> some View {
        if mode == .gamut {
            // The gamut explains why a solve will struggle, so it stays useful
            // before Generate and when nothing could be matched at all.
            ResponseGamutView()
        } else if !model.hasResult {
            ContentUnavailableView(
                "No composition yet",
                systemImage: "wand.and.stars",
                description: Text("Add source images, assign lighting channels, then Generate.")
            )
        } else if model.allCellsUnmatched {
            ContentUnavailableView(
                "No cells could be matched",
                systemImage: "exclamationmark.triangle",
                description: Text("The selected profile has no colors with measurements for the active channels, so every color was excluded. Pick a profile whose colors are measured for those channels, or reduce the active channel weights.")
            )
        } else {
            switch mode {
            case .composite:
                let image = softProofPreview?.image ?? model.compositePreviewRGBA
                PreviewImage(image: image.flatMap { ImageUtilities.nsImage(from: $0) })
            case .errorMap:
                PreviewImage(image: model.errorMapGrid.flatMap { ImageUtilities.nsImage(from: $0) })
            case .gamut:
                ResponseGamutView()
            case .lighting(let condition):
                lightingCompareView(for: condition)
            }
        }
    }

    private var softProofPreviewSelection: SoftProofPreview? {
        guard mode == .composite, softProofEnabled else { return nil }
        return model.softProofPreview
    }

    /// Per-channel comparison: a switch between Predicted, Source, and
    /// Difference when a source grid exists for the channel; otherwise the
    /// predicted preview alone (no comparison is possible without a source).
    @ViewBuilder
    private func lightingCompareView(for condition: LightingCondition) -> some View {
        if model.hasSource(for: condition) {
            VStack(spacing: 0) {
                Picker("Compare", selection: $compareMode) {
                    ForEach(LightingCompareMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)
                Divider()
                compareImage(for: condition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            PreviewImage(image: model.lightingPreviewTinted(for: condition).flatMap { ImageUtilities.nsImage(from: $0) })
        }
    }

    @ViewBuilder
    private func compareImage(for condition: LightingCondition) -> some View {
        let image: NSImage?
        switch compareMode {
        case .predicted:
            image = model.lightingPreviewTinted(for: condition).flatMap { ImageUtilities.nsImage(from: $0) }
        case .source:
            image = model.sourcePreviewTinted(for: condition).flatMap { ImageUtilities.nsImage(from: $0) }
        case .difference:
            image = model.lightingDifferenceTinted(for: condition).flatMap { ImageUtilities.nsImage(from: $0) }
        }
        PreviewImage(image: image)
    }

    private func softProofStatus(for preview: SoftProofPreview, profileName: String) -> String {
        if preview.outOfGamutCount == 0 {
            return "\(profileName) preview"
        }
        let noun = preview.outOfGamutCount == 1 ? "cell" : "cells"
        return "\(preview.outOfGamutCount) out-of-gamut \(noun) · \(profileName)"
    }
}

struct PreviewImage: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
        } else {
            Text("Preview unavailable")
                .foregroundStyle(.secondary)
        }
    }
}

struct StatisticsBar: View {
    @Environment(AppModel.self) private var model
    @State private var threshold = 0.05

    var body: some View {
        @Bindable var model = model
        if let result = model.result, let stats = model.errorStatistics {
            HStack(alignment: .top, spacing: 24) {
                StatisticItem("Cells", value: "\(result.cellCount)")
                StatisticItem("Matched", value: "\(stats.matchedCellCount)")
                if result.unmatchedCellCount > 0 {
                    StatisticItem("Unmatched", value: "\(result.unmatchedCellCount)", highlight: true)
                }
                StatisticItem("Mean error", value: String(format: "%.5f", stats.mean))
                StatisticItem("Median error", value: String(format: "%.5f", stats.median))
                StatisticItem("Max error", value: String(format: "%.5f", stats.maximum))
                Divider().frame(height: 32)
                VStack(alignment: .leading) {
                    Text("Quality threshold").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $threshold, in: 0...0.5)
                            .frame(width: 120)
                        Text(String(format: "%.0f%% below", stats.fractionBelow(threshold: threshold, result: result) * 100))
                            .monospacedDigit()
                            .frame(width: 80, alignment: .leading)
                    }
                }
            }
            .font(.caption)
        }
    }
}

private struct StatisticItem: View {
    let label: String
    let value: String
    var highlight = false

    init(_ label: String, value: String, highlight: Bool = false) {
        self.label = label
        self.value = value
        self.highlight = highlight
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(highlight ? .red : .primary)
        }
    }
}
