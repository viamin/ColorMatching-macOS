import Foundation

/// Builds a `ResponseGamut` from a palette and the source images' target
/// vectors.
///
/// Targets are quantized to `binsPerAxis` bins per condition before the
/// nearest-color search, so cost scales with the number of *distinct* target
/// vectors (at most `binsPerAxis ^ conditions`) rather than the cell count.
/// Without that collapse a 500×500 composition would repeat the same search
/// 250 000 times for a few thousand genuinely different targets.
public struct ResponseGamutAnalyzer: Sendable {
    public let binsPerAxis: Int

    public init(binsPerAxis: Int = 12) {
        precondition(binsPerAxis > 0, "binsPerAxis must be positive")
        self.binsPerAxis = binsPerAxis
    }

    /// Analyzes the palette against the targets implied by `sourceGrids`.
    ///
    /// Pass empty `sourceGrids` to describe the palette alone — the result then
    /// has no clusters but still reports each color's reachable vector, which is
    /// what guides data entry before a composition has ever been solved.
    public func analyze(
        palette: [PaletteColor],
        sourceGrids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights
    ) -> ResponseGamut {
        let active = weights.activeEntries
        let vectors = gamutVectors(palette: palette, conditions: active.map(\.condition))
        return ResponseGamut(
            conditions: active.map(\.condition),
            vectors: vectors,
            clusters: targetClusters(sourceGrids: sourceGrids, active: active, vectors: vectors),
            excludedColorCount: palette.count - vectors.count
        )
    }

    // MARK: - Palette side

    /// Colors measured for every analyzed condition — the solver's eligible set.
    private func gamutVectors(palette: [PaletteColor], conditions: [LightingCondition]) -> [GamutVector] {
        palette.compactMap { color in
            let brightness = conditions.compactMap { color.brightness(for: $0) }
            guard brightness.count == conditions.count else { return nil }
            return GamutVector(id: color.id, name: color.name, rgb: color.rgb, brightness: brightness)
        }
    }

    // MARK: - Target side

    private func targetClusters(
        sourceGrids: [LightingCondition: BrightnessGrid],
        active: [(condition: LightingCondition, weight: Double)],
        vectors: [GamutVector]
    ) -> [TargetCluster] {
        guard let counts = binCounts(sourceGrids: sourceGrids, conditions: active.map(\.condition)) else {
            return []
        }
        // Sorted by packed key so the plot draws in a stable order run to run.
        let entries = counts.sorted { $0.key < $1.key }
        let weights = active.map(\.weight)
        let targets = entries.map { brightness(fromKey: $0.key, channelCount: weights.count) }
        let errors = nearestErrors(targets: targets, weights: weights, vectors: vectors)

        return entries.enumerated().map { index, entry in
            TargetCluster(brightness: targets[index], cellCount: entry.value, nearestError: errors[index])
        }
    }

    /// Occupied bins keyed by their packed per-axis indices, with cell counts.
    /// `nil` when the targets are not well defined — no active condition, a
    /// condition without a source grid, or grids of disagreeing size.
    private func binCounts(
        sourceGrids: [LightingCondition: BrightnessGrid],
        conditions: [LightingCondition]
    ) -> [Int: Int]? {
        guard !conditions.isEmpty else { return nil }
        var buffers: [[Double]] = []
        for condition in conditions {
            guard let grid = sourceGrids[condition] else { return nil }
            buffers.append(grid.values)
        }
        guard let cellCount = buffers.first?.count, cellCount > 0,
              buffers.allSatisfy({ $0.count == cellCount })
        else { return nil }

        var counts: [Int: Int] = [:]
        for cell in 0..<cellCount {
            var key = 0
            for buffer in buffers { key = key * binsPerAxis + bin(for: buffer[cell]) }
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func bin(for value: Double) -> Int {
        let clamped = max(0, min(1, value))
        return min(binsPerAxis - 1, Int(clamped * Double(binsPerAxis)))
    }

    /// Unpacks a bin key back into per-axis bin-center brightness.
    private func brightness(fromKey key: Int, channelCount: Int) -> [Double] {
        var remaining = key
        var result = [Double](repeating: 0, count: channelCount)
        for axis in stride(from: channelCount - 1, through: 0, by: -1) {
            result[axis] = (Double(remaining % binsPerAxis) + 0.5) / Double(binsPerAxis)
            remaining /= binsPerAxis
        }
        return result
    }

    // MARK: - Reachability

    private func nearestErrors(
        targets: [[Double]],
        weights: [Double],
        vectors: [GamutVector]
    ) -> [Double] {
        guard !vectors.isEmpty, !targets.isEmpty else {
            return [Double](repeating: .infinity, count: targets.count)
        }
        // Flatten candidates into one contiguous row-per-color buffer, mirroring
        // the solver's fast path, so the inner loop stays cache-friendly.
        let candidates = vectors.flatMap(\.brightness)
        var errors = [Double](repeating: .infinity, count: targets.count)

        // Each iteration owns exactly one index, so the writes never overlap.
        errors.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                buffer[index] = Self.lowestError(for: targets[index], candidates: candidates, weights: weights)
            }
        }
        return errors
    }

    /// Lowest weighted squared error between `target` and any candidate row in
    /// the flattened `candidates` buffer.
    private static func lowestError(for target: [Double], candidates: [Double], weights: [Double]) -> Double {
        let channelCount = weights.count
        guard channelCount > 0 else { return .infinity }

        var best = Double.infinity
        for base in stride(from: 0, to: candidates.count, by: channelCount) {
            var sum = 0.0
            for channel in 0..<channelCount {
                let diff = candidates[base + channel] - target[channel]
                sum += diff * diff * weights[channel]
            }
            if sum < best { best = sum }
        }
        return best
    }
}
