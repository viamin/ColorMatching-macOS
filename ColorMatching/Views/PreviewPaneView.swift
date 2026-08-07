import SwiftUI
import ColorComposerCore

enum PreviewMode: Hashable, CaseIterable, Identifiable {
    case composite
    case errorMap
    case lighting(LightingCondition)

    var id: Self { self }

    var label: String {
        switch self {
        case .composite: return "Composite"
        case .errorMap: return "Error Map"
        case .lighting(let condition): return "Preview · \(condition.displayName)"
        }
    }

    static var allCases: [PreviewMode] {
        [.composite, .errorMap] + LightingCondition.all.map { .lighting($0) }
    }
}

struct PreviewPaneView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: PreviewMode = .composite

    var body: some View {
        VStack(spacing: 0) {
            previewPicker
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasResult {
                Divider()
                StatisticsBar()
                    .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var previewPicker: some View {
        Picker("Preview", selection: $mode) {
            ForEach(PreviewMode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasResult {
            ContentUnavailableView(
                "No composition yet",
                systemImage: "wand.and.stars",
                description: Text("Add source images, assign lighting channels, then Generate.")
            )
        } else if model.allCellsUnmatched {
            ContentUnavailableView(
                "No cells could be matched",
                systemImage: "exclamationmark.triangle",
                description: Text("The loaded palette has no measurements for the active channels, so every color was excluded. Choose a palette/profile with measurements (e.g. “Cool” on “Generic Inkjet”), or reduce the active channel weights.")
            )
        } else {
            switch mode {
            case .composite:
                PreviewImage(image: model.compositePreviewRGBA.flatMap { ImageUtilities.nsImage(from: $0) })
            case .errorMap:
                PreviewImage(image: model.errorMapGrid.flatMap { ImageUtilities.nsImage(from: $0) })
            case .lighting(let condition):
                PreviewImage(image: model.lightingPreviewTinted(for: condition).flatMap { ImageUtilities.nsImage(from: $0) })
            }
        }
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
