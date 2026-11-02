import Foundation
@testable import ColorComposerCore

/// A corpus case converted to solver-ready domain types and validated against
/// the corpus contract. Building one throws `ParityCorpusError` with the case
/// name on any schema violation, so a malformed corpus fails loudly instead of
/// being quietly skipped.
struct PreparedParityCase {
    let name: String
    let weights: ChannelWeights
    let palette: [PaletteColor]
    /// Target brightness per active condition (the 1×1 source grid values).
    let target: [LightingCondition: Double]
    let expectedSelectionID: Int?
    let expectedScore: Double?
    let expectedTieIDs: Set<Int>
    let expectedExcludedIDs: Set<Int>
}

extension PreparedParityCase {
    init(_ corpusCase: ParityCorpus.Case) throws {
        let name = corpusCase.name

        let weights = try Self.weights(from: corpusCase.weights, caseName: name)
        let active = weights.activeEntries
        guard !active.isEmpty else { throw ParityCorpusError.noActiveWeights(caseName: name) }

        let target = try Self.conditions(from: corpusCase.target, caseName: name)
        for (condition, _) in active {
            guard target[condition] != nil else {
                throw ParityCorpusError.targetMissingActiveCondition(condition: condition.rawValue, caseName: name)
            }
        }

        let palette = try Self.palette(from: corpusCase.palette, caseName: name)
        let idSet = Set(palette.map(\.id))

        guard let selectedID = corpusCase.expected.selectedId else {
            self.init(
                name: name, weights: weights, palette: palette, target: target,
                expectedSelectionID: nil, expectedScore: nil,
                expectedTieIDs: [], expectedExcludedIDs: Set(corpusCase.expected.excludedIds ?? [])
            )
            return
        }

        guard idSet.contains(selectedID) else {
            throw ParityCorpusError.unknownPaletteID(id: selectedID, caseName: name)
        }
        guard let score = corpusCase.expected.score else {
            throw ParityCorpusError.missingExpectedScore(caseName: name)
        }

        var tieIDs = Set(corpusCase.expected.tieIds ?? [selectedID])
        guard tieIDs.isSubset(of: idSet) else {
            throw ParityCorpusError.unknownPaletteID(id: tieIDs.subtracting(idSet).first ?? selectedID, caseName: name)
        }
        // The selection is by definition part of its own tie set.
        tieIDs.insert(selectedID)

        self.init(
            name: name, weights: weights, palette: palette, target: target,
            expectedSelectionID: selectedID, expectedScore: score,
            expectedTieIDs: tieIDs,
            expectedExcludedIDs: Set(corpusCase.expected.excludedIds ?? [])
        )
    }

    // MARK: - Conversion helpers

    /// Maps light-source strings onto `LightingCondition`s, rejecting keys the
    /// client does not know so an upstream vocabulary change surfaces here.
    private static func conditions(
        from values: [String: Double],
        caseName: String
    ) throws -> [LightingCondition: Double] {
        var mapped: [LightingCondition: Double] = [:]
        for (key, value) in values {
            guard let condition = LightingCondition(rawValue: key) else {
                throw ParityCorpusError.unknownLightSource(key: key, caseName: caseName)
            }
            mapped[condition] = value
        }
        return mapped
    }

    private static func weights(from values: [String: Double], caseName: String) throws -> ChannelWeights {
        let mapped = try conditions(from: values, caseName: caseName)
        return ChannelWeights(
            white: mapped[.white] ?? 0,
            red: mapped[.red] ?? 0,
            green: mapped[.green] ?? 0,
            blue: mapped[.blue] ?? 0,
            lps: mapped[.lps] ?? 0
        )
    }

    private static func palette(from entries: [ParityCorpus.PaletteEntry], caseName: String) throws -> [PaletteColor] {
        guard !entries.isEmpty else { throw ParityCorpusError.emptyPalette(caseName: caseName) }

        var seenIDs = Set<Int>()
        var colors: [PaletteColor] = []
        colors.reserveCapacity(entries.count)
        for entry in entries {
            guard seenIDs.insert(entry.id).inserted else {
                throw ParityCorpusError.duplicatePaletteID(id: entry.id, caseName: caseName)
            }
            guard let rgb = RGBColor(hex: entry.hex) else {
                throw ParityCorpusError.unparseableHex(id: entry.id, caseName: caseName)
            }
            let responses = try conditions(from: entry.responses, caseName: caseName)
                .mapValues { IlluminationResponse(brightness: $0) }
            colors.append(
                PaletteColor(
                    id: entry.id, name: entry.name, hex: entry.hex, rgb: rgb,
                    responses: responses
                )
            )
        }
        return colors
    }
}
