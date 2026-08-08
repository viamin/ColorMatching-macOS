import XCTest
@testable import ColorComposerCore

final class ScorerTests: XCTestCase {
    private func color(
        white: Double? = nil, red: Double? = nil, green: Double? = nil,
        blue: Double? = nil, lps: Double? = nil, hex: String = "#000000"
    ) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        func put(_ c: LightingCondition, _ v: Double?) {
            if let v { responses[c] = IlluminationResponse(brightness: v) }
        }
        put(.white, white); put(.red, red); put(.green, green); put(.blue, blue); put(.lps, lps)
        return PaletteColor(id: 0, hex: hex, rgb: RGBColor(hex: hex)!, responses: responses)
    }

    private func target(
        white: Double? = nil, red: Double? = nil, green: Double? = nil,
        blue: Double? = nil, lps: Double? = nil
    ) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        func put(_ c: LightingCondition, _ v: Double?) { if let v { brightness[c] = v } }
        put(.white, white); put(.red, red); put(.green, green); put(.blue, blue); put(.lps, lps)
        return TargetResponseVector(brightness)
    }

    private func assertScore(
        _ result: ScorerResult,
        _ expected: Double,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .score(let value):
            XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
        case .excluded:
            XCTFail("Expected .score(\(expected)) but received .excluded", file: file, line: line)
        }
    }

    /// Mirrors the Elixir `WeightedSquaredError` doctest exactly: expected 0.205.
    func testMatchesElixirDoctestExample() {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(white: 0.5, red: 1.0, green: 1.0, blue: 0.0, lps: 1.5)

        let candidate = color(white: 0.5, red: 0.1, green: 0.4, blue: 0.0, lps: 0.3)
        let target = target(white: 0.8, red: 0.2, green: 0.7, blue: 0.1, lps: 0.5)

        assertScore(scorer.score(candidate: candidate, target: target, weights: weights), 0.205, accuracy: 1e-9)
    }

    func testZeroWeightChannelsIgnored() {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(white: 1.0, red: 0.0, green: 0.0, blue: 0.0, lps: 0.0)
        let candidate = color(white: 0.5)            // missing red/green/blue/lps
        let target = target(white: 0.8)

        // Only white is active, so missing other channels must not exclude.
        assertScore(scorer.score(candidate: candidate, target: target, weights: weights), 0.09, accuracy: 1e-9)
    }

    func testCandidateMissingRequiredChannelExcluded() {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(red: 1.0, green: 1.0)
        let candidate = color(red: 0.5)              // missing green
        let target = target(red: 0.5, green: 0.5)

        XCTAssertEqual(scorer.score(candidate: candidate, target: target, weights: weights), .excluded)
    }

    func testTargetMissingRequiredChannelExcluded() {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(red: 1.0, green: 1.0)
        let candidate = color(red: 0.5, green: 0.5)
        let target = target(red: 0.5)                // missing green

        XCTAssertEqual(scorer.score(candidate: candidate, target: target, weights: weights), .excluded)
    }

    func testExactMatchScoresZero() {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(white: 2.0, red: 1.0)
        let candidate = color(white: 0.3, red: 0.7)
        let target = target(white: 0.3, red: 0.7)

        assertScore(scorer.score(candidate: candidate, target: target, weights: weights), 0, accuracy: 1e-12)
    }

    func testChannelWeightingScalesError() {
        let scorer = WeightedSquaredErrorScorer()
        let candidate = color(white: 0.0, red: 1.0)
        let target = target(white: 1.0, red: 0.0)

        // Each channel differs by 1.0; weight scales the squared contribution.
        let whiteHeavy = scorer.score(
            candidate: candidate, target: target,
            weights: ChannelWeights(white: 10, red: 1)
        )
        let redHeavy = scorer.score(
            candidate: candidate, target: target,
            weights: ChannelWeights(white: 1, red: 10)
        )
        assertScore(whiteHeavy, 11, accuracy: 1e-9)
        assertScore(redHeavy, 11, accuracy: 1e-9)
    }

    // MARK: - WorstCaseChannelScorer

    func testWorstCaseReturnsMaxChannelError() {
        let scorer = WorstCaseChannelScorer()
        // white diff = 0.3, red diff = 0.1; both weights = 1.
        // Per-channel squared errors: white = 0.09, red = 0.01 → max = 0.09.
        let candidate = color(white: 0.5, red: 0.9)
        let t = target(white: 0.8, red: 1.0)
        let weights = ChannelWeights(white: 1, red: 1)
        assertScore(scorer.score(candidate: candidate, target: t, weights: weights), 0.09, accuracy: 1e-9)
    }

    func testWorstCaseScoreIsBoundedByMaxChannel() {
        // Verify: worst-case score ≤ sum (i.e. it never exceeds mean scorer on
        // the worst channel, and is always the per-channel maximum, not the sum).
        let wce = WeightedSquaredErrorScorer()
        let wcc = WorstCaseChannelScorer()
        let weights = ChannelWeights(white: 1, red: 1, green: 1)

        let candidate = color(white: 0.0, red: 0.5, green: 0.9)
        let t = target(white: 1.0, red: 0.5, green: 0.0)

        guard case .score(let sumScore) = wce.score(candidate: candidate, target: t, weights: weights),
              case .score(let maxScore) = wcc.score(candidate: candidate, target: t, weights: weights)
        else {
            return XCTFail("Expected .score for both scorers")
        }
        // The max-channel score must be ≤ the total sum score.
        XCTAssertLessThanOrEqual(maxScore, sumScore)
        // And equal to the largest individual channel error (white: 1.0, green: 0.81).
        XCTAssertEqual(maxScore, 1.0, accuracy: 1e-9)
    }

    func testWorstCaseExcludesMissingChannel() {
        let scorer = WorstCaseChannelScorer()
        let weights = ChannelWeights(red: 1.0, green: 1.0)
        let candidate = color(red: 0.5)          // missing green
        let t = target(red: 0.5, green: 0.5)
        XCTAssertEqual(scorer.score(candidate: candidate, target: t, weights: weights), .excluded)
    }

    func testWorstCaseExactMatchScoresZero() {
        let scorer = WorstCaseChannelScorer()
        let weights = ChannelWeights(white: 1, red: 2)
        let candidate = color(white: 0.4, red: 0.6)
        let t = target(white: 0.4, red: 0.6)
        assertScore(scorer.score(candidate: candidate, target: t, weights: weights), 0, accuracy: 1e-12)
    }

    // MARK: - PerceptualScorer

    func testPerceptualUsesFixedWeightsNotUserWeights() {
        // Candidate matches green perfectly but misses white — with equal user
        // weights the WCE score only sees diff on white. The perceptual scorer
        // should produce a different value because it uses CIE weights.
        let scorer = PerceptualScorer()
        let weights = ChannelWeights(white: 1, green: 1)
        let candidate = color(white: 0.0, green: 0.5)
        let t = target(white: 1.0, green: 0.5)
        // white perceptual weight = 1.0, diff = 1.0 → contribution = 1.0.
        // green perceptual weight = 0.7152, diff = 0.0 → contribution = 0.0.
        assertScore(scorer.score(candidate: candidate, target: t, weights: weights), 1.0, accuracy: 1e-9)
    }

    func testPerceptualGreenOutweighsBlue() {
        let scorer = PerceptualScorer()
        // Both differ by 1.0; green weight (0.7152) > blue weight (0.0722).
        let candidate = color(green: 0.0, blue: 0.0)
        let t = target(green: 1.0, blue: 1.0)
        let weights = ChannelWeights(green: 1, blue: 1)

        guard case .score(let score) = scorer.score(candidate: candidate, target: t, weights: weights) else {
            return XCTFail("Expected .score")
        }
        // score = 1*0.7152 + 1*0.0722 = 0.7874
        XCTAssertEqual(score, 0.7874, accuracy: 1e-9)
    }

    func testPerceptualExcludesMissingChannel() {
        let scorer = PerceptualScorer()
        let weights = ChannelWeights(red: 1.0, blue: 1.0)
        let candidate = color(red: 0.5)          // missing blue
        let t = target(red: 0.5, blue: 0.5)
        XCTAssertEqual(scorer.score(candidate: candidate, target: t, weights: weights), .excluded)
    }

    // MARK: - ScorerKind

    func testScorerKindMakesCorrectType() {
        XCTAssert(ScorerKind.weightedSquaredError.makeScorer() is WeightedSquaredErrorScorer)
        XCTAssert(ScorerKind.worstCaseChannel.makeScorer() is WorstCaseChannelScorer)
        XCTAssert(ScorerKind.perceptual.makeScorer() is PerceptualScorer)
    }

    func testScorerKindRoundTrips() throws {
        for kind in ScorerKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(ScorerKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }
}
