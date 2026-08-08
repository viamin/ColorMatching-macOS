import SwiftUI
import ColorComposerCore

/// Plots the response vectors the loaded colors can actually produce against
/// the vectors the source images ask for.
///
/// The error map shows *where* a composition fails; this shows *why* — the
/// targets that fall outside the palette's reach, and on which lighting
/// condition the palette runs out.
struct ResponseGamutView: View {
    @Environment(AppModel.self) private var model
    @State private var threshold = ResponseGamut.defaultReachabilityThreshold

    var body: some View {
        let gamut = model.responseGamut
        if gamut.conditions.isEmpty {
            ContentUnavailableView(
                "No active channels",
                systemImage: "slider.horizontal.3",
                description: Text("Give at least one channel a weight above zero to compare colors against targets.")
            )
        } else if gamut.isEmpty {
            ContentUnavailableView(
                "No colors loaded",
                systemImage: "eyedropper",
                description: Text("Load colors from the server to see which response vectors are within reach.")
            )
        } else {
            VStack(spacing: 0) {
                GamutChart(gamut: gamut, threshold: threshold)
                Divider()
                GamutSummary(gamut: gamut, threshold: $threshold)
                    .padding(8)
            }
        }
    }
}

private struct GamutChart: View {
    let gamut: ResponseGamut
    let threshold: Double

    var body: some View {
        Canvas { context, size in
            GamutPlotRenderer(
                gamut: gamut,
                threshold: threshold,
                geometry: GamutPlotGeometry(size: size, axisCount: gamut.conditions.count)
            )
            .draw(into: &context)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GamutSummary: View {
    let gamut: ResponseGamut
    @Binding var threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 20) {
                counts
                Spacer()
                reachControl
            }
            legend
            gapList
        }
        .font(.caption)
    }

    private var counts: some View {
        HStack(alignment: .top, spacing: 20) {
            GamutStatistic("Colors plotted", value: gamut.vectors.count.formatted())
            if gamut.excludedColorCount > 0 {
                GamutStatistic("Unmeasured", value: gamut.excludedColorCount.formatted(), highlight: true)
            }
            if !gamut.clusters.isEmpty {
                GamutStatistic("Target groups", value: gamut.clusters.count.formatted())
            }
        }
    }

    @ViewBuilder
    private var reachControl: some View {
        if gamut.clusters.isEmpty {
            Text("Generate a composition to compare against source targets.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Match tolerance").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $threshold, in: 0...0.25)
                        .frame(width: 120)
                    Text(unreachableText)
                        .monospacedDigit()
                        .foregroundStyle(gamut.unreachableCellCount(threshold: threshold) > 0 ? .red : .secondary)
                }
            }
        }
    }

    private var unreachableText: String {
        let cells = gamut.unreachableCellCount(threshold: threshold)
        let percent = gamut.unreachableFraction(threshold: threshold) * 100
        return "\(cells.formatted()) cells (\(String(format: "%.0f", percent))%) out of reach"
    }

    private var legend: some View {
        HStack(spacing: 16) {
            GamutLegendItem(color: .accentColor.opacity(0.35), label: "Palette reach")
            GamutLegendItem(color: .blue.opacity(0.35), label: "Target density")
            GamutLegendItem(color: .red.opacity(0.8), label: "Unreachable targets", dashed: true)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var gapList: some View {
        // Naming the axis that runs out is the actionable part: it says which
        // color to measure or acquire next.
        ForEach(gamut.gaps, id: \.condition) { axis in
            if let summary = axis.gapSummary {
                Label(summary, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GamutStatistic: View {
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
            Text(value).monospacedDigit().foregroundStyle(highlight ? .orange : .primary)
        }
    }
}

private struct GamutLegendItem: View {
    let color: Color
    let label: String
    var dashed = false

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 20, height: 6)
            Text(label)
        }
    }
}
