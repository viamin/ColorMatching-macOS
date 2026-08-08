import Foundation

/// Errors thrown while solving a composition.
public enum CompositionSolverError: Error, Equatable, LocalizedError {
    /// No condition has a positive weight; at least one is required.
    case noActiveConditions
    /// An active condition (weight > 0) has no source-image grid.
    case missingSourceGrid(LightingCondition)
    /// Source grids disagree on output dimensions.
    case mismatchedGridDimensions
    /// The palette is empty.
    case emptyPalette

    public var errorDescription: String? {
        switch self {
        case .noActiveConditions:
            return "At least one channel must have a weight greater than zero."
        case .missingSourceGrid(let condition):
            return "No source image assigned to the active “\(condition.displayName)” channel."
        case .mismatchedGridDimensions:
            return "Source images must all share the same output dimensions."
        case .emptyPalette:
            return "The palette must contain at least one color."
        }
    }
}

/// Selects, for every logical output cell, the palette color whose measured
/// response vector best matches the target vector built from the source images.
///
/// The default scorer (`WeightedSquaredErrorScorer`) uses an optimized
/// contiguous-array fast path. Custom scorers fall back to a general path that
/// invokes the scorer per candidate. Both paths select the lowest score with
/// earliest-candidate tie-breaking, so results are deterministic for a given
/// input order — matching the Elixir `IlluminantMatching.best_match/4` policy.
public struct CompositionSolver: Sendable {
    public let scorer: CompositionScorer

    public init(scorer: CompositionScorer = WeightedSquaredErrorScorer()) {
        self.scorer = scorer
    }

    /// Solves a composition.
    ///
    /// - Parameters:
    ///   - palette: Eligible palette colors (the caller may pre-filter; colors
    ///     missing a required measurement are also excluded internally).
    ///   - sourceGrids: One brightness grid per lighting condition, already
    ///     scaled to the common output dimensions and inverted if requested.
    ///   - weights: Per-channel weights. Conditions with weight `> 0` are
    ///     required and must have a grid in `sourceGrids`.
    ///   - dithering: Optional post-solve error-diffusion pass. The default
    ///     (`.off`) leaves plain nearest-neighbor behavior unchanged; pass
    ///     `.floydSteinberg` to de-posterize palettes that cannot reproduce a
    ///     target tone exactly. See ``Dithering``.
    public func solve(
        palette: [PaletteColor],
        sourceGrids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights,
        dithering: Dithering = .off
    ) throws -> CompositionResult {
        guard !palette.isEmpty else { throw CompositionSolverError.emptyPalette }

        let active = weights.activeEntries
        guard !active.isEmpty else { throw CompositionSolverError.noActiveConditions }

        // Every active condition must have a source grid of common dimensions.
        var gridWidth = 0
        var gridHeight = 0
        for (condition, _) in active {
            guard let grid = sourceGrids[condition] else {
                throw CompositionSolverError.missingSourceGrid(condition)
            }
            if gridWidth == 0 {
                gridWidth = grid.width
                gridHeight = grid.height
            } else if grid.width != gridWidth || grid.height != gridHeight {
                throw CompositionSolverError.mismatchedGridDimensions
            }
        }

        if dithering == .floydSteinberg {
            return solveDithered(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights,
                active: active,
                gridWidth: gridWidth,
                gridHeight: gridHeight
            )
        }

        if scorer is WeightedSquaredErrorScorer {
            return try solveFast(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights,
                active: active,
                gridWidth: gridWidth,
                gridHeight: gridHeight
            )
        } else {
            return solveGeneral(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights,
                active: active,
                gridWidth: gridWidth,
                gridHeight: gridHeight
            )
        }
    }

    // MARK: - Fast path (default scorer)

    private func solveFast(
        palette: [PaletteColor],
        sourceGrids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights,
        active: [(condition: LightingCondition, weight: Double)],
        gridWidth: Int,
        gridHeight: Int
    ) throws -> CompositionResult {
        let activeConditions = active.map(\.condition)
        let activeWeights = active.map(\.weight)
        let channelCount = activeConditions.count

        // Precompute eligible candidate brightness into contiguous storage.
        // A candidate is eligible only if it has every active condition.
        var eligibleBrightness: [Double] = []
        var eligiblePaletteIndex: [Int] = []
        eligibleBrightness.reserveCapacity(palette.count * channelCount)
        eligiblePaletteIndex.reserveCapacity(palette.count)

        for (index, color) in palette.enumerated() {
            var row = [Double](repeating: 0, count: channelCount)
            var eligible = true
            for (c, condition) in activeConditions.enumerated() {
                guard let value = color.brightness(for: condition) else {
                    eligible = false
                    break
                }
                row[c] = value
            }
            if eligible {
                eligibleBrightness.append(contentsOf: row)
                eligiblePaletteIndex.append(index)
            }
        }

        let eligibleCount = eligiblePaletteIndex.count
        let excludedCandidateCount = palette.count - eligibleCount

        // Precompute per-channel planar source buffers for cache-friendly access.
        let sourceBuffers: [[Double]] = activeConditions.map { sourceGrids[$0]!.values }
        let cellCount = gridWidth * gridHeight

        var colorIndices = [Int?](repeating: nil, count: cellCount)
        var errors = [Double](repeating: .infinity, count: cellCount)

        // Parallelize across rows; per-cell selection is independent and
        // earliest-wins tie-breaking is preserved within each row.
        DispatchQueue.concurrentPerform(iterations: gridHeight) { y in
            for x in 0..<gridWidth {
                let cellBase = y * gridWidth + x
                var bestError = Double.infinity
                var bestEligible = -1

                for e in 0..<eligibleCount {
                    let candidateBase = e * channelCount
                    var sum = 0.0
                    for c in 0..<channelCount {
                        let diff = eligibleBrightness[candidateBase + c] - sourceBuffers[c][cellBase]
                        sum += diff * diff * activeWeights[c]
                    }
                    if sum < bestError {
                        bestError = sum
                        bestEligible = e
                    }
                }

                if bestEligible >= 0 {
                    colorIndices[cellBase] = eligiblePaletteIndex[bestEligible]
                    errors[cellBase] = bestError
                }
            }
        }

        return CompositionResult(
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            palette: palette,
            weights: weights,
            colorIndices: colorIndices,
            errors: errors,
            excludedCandidateCount: excludedCandidateCount
        )
    }

    // MARK: - General path (custom scorers)

    private func solveGeneral(
        palette: [PaletteColor],
        sourceGrids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights,
        active: [(condition: LightingCondition, weight: Double)],
        gridWidth: Int,
        gridHeight: Int
    ) -> CompositionResult {
        let activeConditions = active.map(\.condition)
        let cellCount = gridWidth * gridHeight
        var colorIndices = [Int?](repeating: nil, count: cellCount)
        var errors = [Double](repeating: .infinity, count: cellCount)
        var excludedCandidateCount = 0

        // Pre-scan exclusion once for diagnostics.
        for color in palette {
            if scorer.score(candidate: color, target: TargetResponseVector([:]), weights: weights) == .excluded,
               !activeConditions.allSatisfy({ color.brightness(for: $0) != nil })
            {
                excludedCandidateCount += 1
            }
        }

        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                let cell = y * gridWidth + x
                var brightness: [LightingCondition: Double] = [:]
                for condition in activeConditions {
                    brightness[condition] = sourceGrids[condition]!.value(x: x, y: y)
                }
                let target = TargetResponseVector(brightness)

                var bestError = Double.infinity
                var bestIndex: Int? = nil
                for (index, color) in palette.enumerated() {
                    switch scorer.score(candidate: color, target: target, weights: weights) {
                    case .excluded:
                        continue
                    case .score(let value):
                        if value < bestError {
                            bestError = value
                            bestIndex = index
                        }
                    }
                }
                colorIndices[cell] = bestIndex
                errors[cell] = bestError
            }
        }

        return CompositionResult(
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            palette: palette,
            weights: weights,
            colorIndices: colorIndices,
            errors: errors,
            excludedCandidateCount: excludedCandidateCount
        )
    }

    // MARK: - Error diffusion (vector Floyd–Steinberg)

    /// Vector Floyd–Steinberg error diffusion. Walks the grid once in raster
    /// order, matching each cell against a working target that absorbs diffused
    /// error from already-visited neighbors, then pushes the cell's signed
    /// per-channel error forward. Per-cell `errors` are recorded against the
    /// *original* target so the field stays comparable with the nearest-neighbor
    /// result; diffusion improves local (block) averages rather than per-cell
    /// scores. Kept as one cohesive pass — splitting the raster walk would only
    /// redistribute the sequential coupling without reducing complexity.
    private func solveDithered(
        palette: [PaletteColor],
        sourceGrids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights,
        active: [(condition: LightingCondition, weight: Double)],
        gridWidth: Int,
        gridHeight: Int
    ) -> CompositionResult {
        let activeConditions = active.map(\.condition)
        let cellCount = gridWidth * gridHeight

        let originals: [[Double]] = activeConditions.map { sourceGrids[$0]!.values }
        var adjusted: [[Double]] = originals.map { $0 }

        var colorIndices = [Int?](repeating: nil, count: cellCount)
        var errors = [Double](repeating: .infinity, count: cellCount)

        // Captures the mutable working buffers so the four Floyd–Steinberg
        // pushes read cleanly at each call site.
        let diffuse: (Double, Int, Int, Int) -> Void = { delta, channel, x, y in
            func push(_ nx: Int, _ ny: Int, _ fraction: Double) {
                guard (0..<gridWidth).contains(nx), (0..<gridHeight).contains(ny) else { return }
                adjusted[channel][ny * gridWidth + nx] += delta * fraction
            }
            push(x + 1, y, 7.0 / 16.0)
            push(x - 1, y + 1, 3.0 / 16.0)
            push(x, y + 1, 5.0 / 16.0)
            push(x + 1, y + 1, 1.0 / 16.0)
        }

        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                let cell = y * gridWidth + x
                let target = Self.targetVector(at: cell, from: adjusted, conditions: activeConditions)
                guard let chosen = bestCandidate(in: palette, for: target, weights: weights) else {
                    continue
                }
                colorIndices[cell] = chosen
                let original = Self.targetVector(at: cell, from: originals, conditions: activeConditions)
                errors[cell] = recordedError(for: chosen, in: palette, versus: original, weights: weights)

                for (channel, condition) in activeConditions.enumerated() {
                    let candidate = palette[chosen].brightness(for: condition) ?? 0
                    diffuse(adjusted[channel][cell] - candidate, channel, x, y)
                }
            }
        }

        let excludedCandidateCount = palette.filter {
            !$0.hasMeasurements(for: Set(activeConditions))
        }.count

        return CompositionResult(
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            palette: palette,
            weights: weights,
            colorIndices: colorIndices,
            errors: errors,
            excludedCandidateCount: excludedCandidateCount
        )
    }

    /// Assembles the per-channel vector stored in `buffers` for one cell into a
    /// target the scorer can consume.
    private static func targetVector(
        at cell: Int,
        from buffers: [[Double]],
        conditions: [LightingCondition]
    ) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (index, condition) in conditions.enumerated() {
            brightness[condition] = buffers[index][cell]
        }
        return TargetResponseVector(brightness)
    }

    /// Lowest-error eligible palette index for `target`, earliest-wins on ties;
    /// `nil` when every candidate is excluded.
    private func bestCandidate(
        in palette: [PaletteColor],
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Int? {
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, color) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Weighted error of `palette[index]` against `target`, or `.infinity` when
    /// the candidate is excluded (only possible if `target` lacks a condition).
    private func recordedError(
        for index: Int,
        in palette: [PaletteColor],
        versus target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Double {
        guard case .score(let score) = scorer.score(candidate: palette[index], target: target, weights: weights) else {
            return .infinity
        }
        return score
    }
}
