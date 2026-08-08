import SwiftUI
import ColorComposerCore

/// Maps response-vector values into Canvas coordinates for a parallel-
/// coordinates plot: one vertical axis per lighting condition, brightness
/// running 0 at the bottom to 1 at the top.
struct GamutPlotGeometry {
    let size: CGSize
    let axisCount: Int

    private static let insetX: CGFloat = 46
    private static let insetTop: CGFloat = 12
    private static let insetBottom: CGFloat = 26
    private static let tickHalfWidth: CGFloat = 18

    /// Widest a target-density bar may grow, for the most populated level.
    static let maxDensityWidth: CGFloat = 34

    func x(forAxis axis: Int) -> CGFloat {
        guard axisCount > 1 else { return size.width / 2 }
        let span = max(0, size.width - 2 * Self.insetX)
        return Self.insetX + span * CGFloat(axis) / CGFloat(axisCount - 1)
    }

    func y(forBrightness value: Double) -> CGFloat {
        Self.insetTop + plotHeight * (1 - CGFloat(value))
    }

    func point(axis: Int, brightness: Double) -> CGPoint {
        CGPoint(x: x(forAxis: axis), y: y(forBrightness: brightness))
    }

    var plotHeight: CGFloat {
        max(1, size.height - Self.insetTop - Self.insetBottom)
    }

    /// Height of a density bar — a fraction of the plot so bars stay separated
    /// whatever the bin count.
    var densityBandHeight: CGFloat {
        max(3, plotHeight / 26)
    }

    /// The polyline linking one response vector's value on every axis.
    func polyline(_ brightness: [Double]) -> Path {
        Path { path in
            guard let first = brightness.first else { return }
            // A single active channel has no second axis to connect to, so draw
            // a tick instead of an invisible zero-length line.
            guard brightness.count > 1 else {
                let center = point(axis: 0, brightness: first)
                path.move(to: CGPoint(x: center.x - Self.tickHalfWidth, y: center.y))
                path.addLine(to: CGPoint(x: center.x + Self.tickHalfWidth, y: center.y))
                return
            }
            for (axis, value) in brightness.enumerated() {
                let vertex = point(axis: axis, brightness: value)
                if axis == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
            }
        }
    }
}

/// Paints a `ResponseGamut`: target demand behind, the palette's reach and each
/// color's vector in the middle, and unreachable targets highlighted on top.
struct GamutPlotRenderer {
    let gamut: ResponseGamut
    let threshold: Double
    let geometry: GamutPlotGeometry

    /// Cap on highlighted target polylines. The heaviest clusters explain the
    /// error map; drawing every one of thousands would just be noise.
    private static let maxHighlightedClusters = 150

    func draw(into context: inout GraphicsContext) {
        drawTargetDensity(into: &context)
        drawPaletteReach(into: &context)
        drawPaletteVectors(into: &context)
        drawUnreachableTargets(into: &context)
        drawAxes(into: &context)
    }

    // MARK: - Targets

    private func drawTargetDensity(into context: inout GraphicsContext) {
        let total = gamut.targetCellCount
        guard total > 0 else { return }
        for axis in gamut.conditions.indices {
            for (brightness, count) in density(forAxis: axis) {
                let share = Double(count) / Double(total)
                context.fill(
                    densityBar(axis: axis, brightness: brightness, share: share),
                    with: .color(.blue.opacity(0.22))
                )
            }
        }
    }

    /// Output cells per distinct brightness level on one axis.
    private func density(forAxis axis: Int) -> [Double: Int] {
        gamut.clusters.reduce(into: [Double: Int]()) { totals, cluster in
            totals[cluster.brightness[axis], default: 0] += cluster.cellCount
        }
    }

    private func densityBar(axis: Int, brightness: Double, share: Double) -> Path {
        let center = geometry.point(axis: axis, brightness: brightness)
        let height = geometry.densityBandHeight
        // Square-root scaling keeps a rare-but-real target visible beside a
        // level that dominates the image.
        let width = GamutPlotGeometry.maxDensityWidth * CGFloat(share.squareRoot())
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        return Path(CGRect(origin: origin, size: CGSize(width: width, height: height)))
    }

    private func drawUnreachableTargets(into context: inout GraphicsContext) {
        let ranked = gamut.unreachableClusters(threshold: threshold)
            .sorted { $0.cellCount > $1.cellCount }
            .prefix(Self.maxHighlightedClusters)

        for cluster in ranked {
            context.stroke(
                geometry.polyline(cluster.brightness),
                with: .color(.red.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }
    }

    // MARK: - Palette

    private func drawPaletteReach(into context: inout GraphicsContext) {
        for (axis, coverage) in gamut.coverage.enumerated() {
            guard let span = coverage.palette else { continue }
            let top = geometry.y(forBrightness: span.highest)
            let bottom = geometry.y(forBrightness: span.lowest)
            let rect = CGRect(
                x: geometry.x(forAxis: axis) - 6,
                y: top,
                width: 12,
                height: max(1, bottom - top)
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.accentColor.opacity(0.16)))
        }
    }

    private func drawPaletteVectors(into context: inout GraphicsContext) {
        let opacity = Self.lineOpacity(forCount: gamut.vectors.count)
        for vector in gamut.vectors {
            context.stroke(
                geometry.polyline(vector.brightness),
                with: .color(swatch(vector).opacity(opacity)),
                lineWidth: 1
            )
        }
    }

    /// Hundreds of overlapping polylines read as a solid mass at full opacity;
    /// fading them turns overlap into visible density while a lone outlier
    /// stays traceable.
    private static func lineOpacity(forCount count: Int) -> Double {
        guard count > 1 else { return 0.9 }
        return max(0.08, min(0.9, 24.0 / Double(count)))
    }

    private func swatch(_ vector: GamutVector) -> Color {
        let rgb = vector.rgb.normalized
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: - Axes

    private func drawAxes(into context: inout GraphicsContext) {
        for (axis, condition) in gamut.conditions.enumerated() {
            let x = geometry.x(forAxis: axis)
            var line = Path()
            line.move(to: CGPoint(x: x, y: geometry.y(forBrightness: 1)))
            line.addLine(to: CGPoint(x: x, y: geometry.y(forBrightness: 0)))
            context.stroke(line, with: .color(.gray.opacity(0.55)), lineWidth: 1)

            context.draw(
                Text(condition.displayName).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: geometry.y(forBrightness: 0) + 13)
            )
        }
        drawScaleLabels(into: &context)
    }

    private func drawScaleLabels(into context: inout GraphicsContext) {
        for value in [0.0, 0.5, 1.0] {
            context.draw(
                Text(String(format: "%.1f", value)).font(.caption2).foregroundStyle(.tertiary),
                at: CGPoint(x: 22, y: geometry.y(forBrightness: value)),
                anchor: .trailing
            )
        }
    }
}
