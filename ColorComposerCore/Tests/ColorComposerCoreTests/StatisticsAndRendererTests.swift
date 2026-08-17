import XCTest
@testable import ColorComposerCore

final class StatisticsAndRendererTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        PaletteColor(id: id, hex: hex, rgb: RGBColor(hex: hex)!,
                     responses: responses.mapValues { IlluminationResponse(brightness: $0) })
    }

    private func solve() throws -> CompositionResult {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        return try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
    }

    private func unmatchedResult() -> CompositionResult {
        CompositionResult(
            gridWidth: 1,
            gridHeight: 1,
            palette: [color(1, "#000000", [.red: 0.0])],
            weights: ChannelWeights(red: 1),
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            colorIndices: [nil],
            errors: [.infinity],
            excludedCandidateCount: 1
        )
    }

    func testErrorStatistics() throws {
        let result = try solve()
        let stats = ErrorStatistics(result: result)

        XCTAssertEqual(stats.matchedCellCount, 2)
        XCTAssertEqual(stats.mean, 0.0, accuracy: 1e-9) // exact matches
        XCTAssertEqual(stats.maximum, 0.0, accuracy: 1e-9)
    }

    func testFractionBelowThreshold() throws {
        let result = try solve()
        let stats = ErrorStatistics(result: result)
        XCTAssertEqual(stats.fractionBelow(threshold: 0.001, result: result), 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.fractionBelow(threshold: 0.0, result: result), 0.0, accuracy: 1e-9)
    }

    func testCompositeUsesSelectedPaletteColors() throws {
        let result = try solve()
        let image = CompositionRenderer.composite(result)

        XCTAssertEqual(image.width, 2)
        // Cell 0 -> black, cell 1 -> white.
        XCTAssertEqual(image.rgba[0], 0)   // R of black
        XCTAssertEqual(image.rgba[3], 255) // A of black
        XCTAssertEqual(image.rgba[4], 255) // R of white
        XCTAssertEqual(image.rgba[7], 255) // A of white
    }

    func testSoftProofLeavesNeutralColorInGamut() throws {
        let palette = [color(1, "#808080", [.red: 0.5])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [0.5])],
            weights: ChannelWeights(red: 1)
        )

        let preview = CompositionRenderer.softProof(result)

        XCTAssertFalse(preview.isOutOfGamut(x: 0, y: 0))
        XCTAssertEqual(preview.outOfGamutCount, 0)
        XCTAssertEqual(preview.image.rgba[3], 255)
        XCTAssertLessThan(abs(Int(preview.image.rgba[0]) - Int(preview.image.rgba[1])), 8)
        XCTAssertLessThan(abs(Int(preview.image.rgba[1]) - Int(preview.image.rgba[2])), 12)
    }

    func testSoftProofFlagsSaturatedColorAndAddsWarningTint() throws {
        let palette = [color(1, "#FF0000", [.red: 1.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            weights: ChannelWeights(red: 1)
        )

        let preview = CompositionRenderer.softProof(result)

        XCTAssertTrue(preview.isOutOfGamut(x: 0, y: 0))
        XCTAssertEqual(preview.outOfGamutCount, 1)
        XCTAssertLessThan(preview.image.rgba[0], 255)
        XCTAssertGreaterThan(preview.image.rgba[1], preview.image.rgba[2])
    }

    func testSoftProofTracksPerCellFlags() throws {
        let palette = [
            color(1, "#808080", [.red: 0.0]),
            color(2, "#FF0000", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )

        let preview = CompositionRenderer.softProof(result)

        XCTAssertEqual(preview.outOfGamutCells, [false, true])
    }

    func testSoftProofGamutFlagsAreRowMajor() throws {
        let palette = [
            color(1, "#808080", [.red: 0.0]),
            color(2, "#FF0000", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 2, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )

        let preview = CompositionRenderer.softProof(result)

        XCTAssertEqual(preview.image.width, 1)
        XCTAssertEqual(preview.image.height, 2)
        XCTAssertFalse(preview.isOutOfGamut(x: 0, y: 0))
        XCTAssertTrue(preview.isOutOfGamut(x: 0, y: 1))
        XCTAssertEqual(preview.outOfGamutCount, 1)
    }

    func testSoftProofUsesProvidedProfilePaperWhite() throws {
        let palette = [color(1, "#808080", [.red: 0.5])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [0.5])],
            weights: ChannelWeights(red: 1)
        )

        let warm = SoftProofProfile(
            paperWhite: RGBColor(red: 255, green: 128, blue: 128),
            paperBlend: 0.5,
            blackFloor: 0,
            contrastScale: 1,
            baseChromaLimit: 1,
            midtoneChromaPenalty: 0,
            shadowChromaPenalty: 0,
            warningOverlayOpacity: 0
        )
        let cool = SoftProofProfile(
            paperWhite: RGBColor(red: 128, green: 128, blue: 255),
            paperBlend: 0.5,
            blackFloor: 0,
            contrastScale: 1,
            baseChromaLimit: 1,
            midtoneChromaPenalty: 0,
            shadowChromaPenalty: 0,
            warningOverlayOpacity: 0
        )

        let warmPreview = CompositionRenderer.softProof(result, profile: warm)
        let coolPreview = CompositionRenderer.softProof(result, profile: cool)

        XCTAssertNotEqual(warmPreview.image, coolPreview.image)
        XCTAssertGreaterThan(warmPreview.image.rgba[0], warmPreview.image.rgba[2])
        XCTAssertLessThan(coolPreview.image.rgba[0], coolPreview.image.rgba[2])
    }

    func testSoftProofWideGamutProfileKeepsSaturatedColorUntinted() throws {
        let palette = [color(1, "#FF0000", [.red: 1.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            weights: ChannelWeights(red: 1)
        )
        let wideGamut = SoftProofProfile(
            paperWhite: RGBColor(red: 255, green: 255, blue: 255),
            paperBlend: 0,
            blackFloor: 0,
            contrastScale: 1,
            baseChromaLimit: 1,
            midtoneChromaPenalty: 0,
            shadowChromaPenalty: 0,
            warningOverlayOpacity: 0.5
        )

        let preview = CompositionRenderer.softProof(result, profile: wideGamut)

        XCTAssertFalse(preview.isOutOfGamut(x: 0, y: 0))
        XCTAssertEqual(Array(preview.image.rgba[0..<4]), [255, 0, 0, 255])
    }

    func testPrinterProfileDisplayNameIncludesPrinterPaperAndInk() {
        let profile = PrinterProfileDTO(
            id: 7,
            printerMakeModel: "Canon PRO-1000",
            paperType: "Photo Rag",
            inkType: "Pigment"
        )

        XCTAssertEqual(profile.displayName, "Canon PRO-1000 · Photo Rag · Pigment")
    }

    func testPrinterProfileDisplayNameFallsBackToIdentifier() {
        let profile = PrinterProfileDTO(
            id: 7,
            printerMakeModel: nil,
            paperType: "   ",
            inkType: nil
        )

        XCTAssertEqual(profile.displayName, "Profile #7")
    }

    func testPrinterProfileDisplayNameTrimsWhitespace() {
        let profile = PrinterProfileDTO(
            id: 7,
            printerMakeModel: "  Canon PRO-1000  ",
            paperType: "  Photo Rag ",
            inkType: " Pigment "
        )

        XCTAssertEqual(profile.displayName, "Canon PRO-1000 · Photo Rag · Pigment")
    }

    func testMattePrinterProfileSoftProofIsMoreConservativeThanGlossy() {
        let matte = PrinterProfileDTO(
            id: 1,
            printerMakeModel: "Epson P900",
            paperType: "Matte Rag",
            inkType: "Pigment"
        ).softProofProfile
        let glossy = PrinterProfileDTO(
            id: 2,
            printerMakeModel: "Canon PRO-100",
            paperType: "Glossy",
            inkType: "Dye"
        ).softProofProfile

        XCTAssertGreaterThan(matte.paperBlend, glossy.paperBlend)
        XCTAssertGreaterThan(matte.blackFloor, glossy.blackFloor)
        XCTAssertLessThan(matte.contrastScale, glossy.contrastScale)
        XCTAssertLessThan(matte.baseChromaLimit, glossy.baseChromaLimit)
    }

    func testPrinterProfileSoftProofMatchesGlossyNamesWithDiacritics() {
        let accented = PrinterProfileDTO(
            id: 1,
            printerMakeModel: "Canon PRO-100",
            paperType: "Lustré",
            inkType: "Dye"
        ).softProofProfile
        let plain = PrinterProfileDTO(
            id: 2,
            printerMakeModel: "Canon PRO-100",
            paperType: "Lustre",
            inkType: "Dye"
        ).softProofProfile

        XCTAssertEqual(accented, plain)
    }

    func testPrinterProfileSoftProofMatchesUppercasePaperAndInkNames() {
        let uppercased = PrinterProfileDTO(
            id: 1,
            printerMakeModel: "Canon PRO-100",
            paperType: "GLOSSY",
            inkType: "DYE"
        ).softProofProfile
        let mixedCase = PrinterProfileDTO(
            id: 2,
            printerMakeModel: "Canon PRO-100",
            paperType: "Glossy",
            inkType: "Dye"
        ).softProofProfile

        XCTAssertEqual(uppercased, mixedCase)
    }

    func testPrinterProfileSoftProofFallsBackToGenericWhenMetadataIsMissing() {
        let profile = PrinterProfileDTO(
            id: 1,
            printerMakeModel: nil,
            paperType: "   ",
            inkType: nil
        ).softProofProfile

        XCTAssertEqual(profile, .genericPrinter)
    }

    func testSoftProofProfileClampsInvalidParameters() {
        let profile = SoftProofProfile(
            paperWhite: RGBColor(red: 255, green: 255, blue: 255),
            paperBlend: -1,
            blackFloor: 2,
            contrastScale: 1.5,
            baseChromaLimit: -0.5,
            midtoneChromaPenalty: 3,
            shadowChromaPenalty: -2,
            warningOverlayOpacity: 4
        )

        XCTAssertEqual(profile.paperBlend, 0)
        XCTAssertEqual(profile.blackFloor, 1)
        XCTAssertEqual(profile.contrastScale, 1)
        XCTAssertEqual(profile.baseChromaLimit, 0)
        XCTAssertEqual(profile.midtoneChromaPenalty, 1)
        XCTAssertEqual(profile.shadowChromaPenalty, 0)
        XCTAssertEqual(profile.warningOverlayOpacity, 1)
    }

    func testSoftProofProfileTreatsNonFiniteParametersAsZero() {
        let profile = SoftProofProfile(
            paperWhite: RGBColor(red: 255, green: 255, blue: 255),
            paperBlend: .nan,
            blackFloor: .infinity,
            contrastScale: -.infinity,
            baseChromaLimit: .nan,
            midtoneChromaPenalty: .infinity,
            shadowChromaPenalty: -.infinity,
            warningOverlayOpacity: .nan
        )

        XCTAssertEqual(profile.paperBlend, 0)
        XCTAssertEqual(profile.blackFloor, 0)
        XCTAssertEqual(profile.contrastScale, 0)
        XCTAssertEqual(profile.baseChromaLimit, 0)
        XCTAssertEqual(profile.midtoneChromaPenalty, 0)
        XCTAssertEqual(profile.shadowChromaPenalty, 0)
        XCTAssertEqual(profile.warningOverlayOpacity, 0)
    }

    func testCompositePreviewMarksUnmatchedCellsMagenta() {
        let preview = CompositionRenderer.compositePreview(unmatchedResult())

        XCTAssertEqual(preview.rgba, [255, 0, 255, 255])
    }

    func testSoftProofPreviewMarksUnmatchedCellsWithoutGamutFlags() {
        let preview = CompositionRenderer.softProofPreview(unmatchedResult())

        XCTAssertEqual(preview.image.rgba, [255, 0, 255, 255])
        XCTAssertEqual(preview.outOfGamutCells, [false])
        XCTAssertEqual(preview.outOfGamutCount, 0)
    }

    func testLightingPreviewUsesMeasuredBrightness() throws {
        let result = try solve()
        let preview = CompositionRenderer.lightingPreview(result, for: .red)

        XCTAssertEqual(preview.value(x: 0, y: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(preview.value(x: 1, y: 0), 1.0, accuracy: 1e-9)
    }

    func testLightingPreviewMissingMeasurementIsBlack() throws {
        // Colors have no green measurement -> preview is black everywhere.
        let palette = [color(1, "#000000", [.red: 0.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [0.0])],
            weights: ChannelWeights(red: 1)
        )
        let preview = CompositionRenderer.lightingPreview(result, for: .green)
        XCTAssertEqual(preview.value(x: 0, y: 0), 0.0)
    }

    func testTintedLightingPreviewUsesChannelColor() throws {
        // Two cells: dark (0.0) and bright (1.0) under red.
        let palette = [color(1, "#ffffff", [.red: 0.0]), color(2, "#000000", [.red: 1.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
        let red = CompositionRenderer.lightingPreviewTinted(result, for: .red)
        // Bright cell -> full red, zero green/blue. Dark cell -> black.
        XCTAssertEqual(red.rgba[4], 255) // R
        XCTAssertEqual(red.rgba[5], 0)   // G
        XCTAssertEqual(red.rgba[6], 0)   // B
        XCTAssertEqual(red.rgba[0], 0)   // dark cell R

        let lps = CompositionRenderer.lightingPreviewTinted(result, for: .lps)
        // No lps measurements -> black, but still opaque.
        XCTAssertEqual(lps.rgba[7], 255)
    }

    func testLightingDifferenceIsSourceMinusPredicted() throws {
        // Palette: black (red 0.0) and a mid-gray (red 0.5). The gray caps how
        // bright red can get, so cell 1 under-shoots.
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#808080", [.red: 0.5])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
        // Predicted: cell0 -> black (0.0), cell1 -> gray (0.5).
        let diff = CompositionRenderer.lightingDifference(result, for: .red)

        XCTAssertEqual(diff.width, 2)
        XCTAssertEqual(diff.height, 1)
        // Element-wise: source − predicted = [0.0−0.0, 1.0−0.5].
        XCTAssertEqual(diff.value(x: 0, y: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(diff.value(x: 1, y: 0), 0.5, accuracy: 1e-9)

        // Verify the full element-wise identity holds against the stored grids.
        let source = try XCTUnwrap(result.sourceGrids[.red])
        let predicted = CompositionRenderer.lightingPreview(result, for: .red)
        for i in 0..<diff.values.count {
            XCTAssertEqual(diff.values[i], source.values[i] - predicted.values[i], accuracy: 1e-9)
        }
    }

    func testLightingDifferenceZeroWhenNoSourceGrid() throws {
        // Only a red source; asking for the green difference has nothing to
        // compare against, so every cell is 0.
        let palette = [color(1, "#000000", [.red: 0.0, .green: 0.3])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [0.0])],
            weights: ChannelWeights(red: 1)
        )
        let diff = CompositionRenderer.lightingDifference(result, for: .green)
        XCTAssertEqual(diff.value(x: 0, y: 0), 0.0, accuracy: 1e-9)
    }

    func testDifferenceTintedDivergingColors() throws {
        // One color (mid-gray under red, 0.5): every cell maps to it, so cell 0
        // over-shoots (predicted 0.5 > source 0.0) and cell 1 under-shoots.
        let palette = [color(1, "#808080", [.red: 0.5])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
        let img = CompositionRenderer.lightingDifferenceTinted(result, for: .red)
        // cell 0: over-shoot (negative) -> red: R > 0, B == 0.
        XCTAssertGreaterThan(img.rgba[0], 0)
        XCTAssertEqual(img.rgba[2], 0)
        // cell 1: under-shoot (positive) -> blue: R == 0, B > 0.
        XCTAssertEqual(img.rgba[4], 0)
        XCTAssertGreaterThan(img.rgba[6], 0)
        // Both cells opaque.
        XCTAssertEqual(img.rgba[3], 255)
        XCTAssertEqual(img.rgba[7], 255)
    }

    func testSourcePreviewTintedMirrorsPredicted() throws {
        let palette = [color(1, "#ffffff", [.red: 1.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            weights: ChannelWeights(red: 1)
        )
        // Source fully bright under red -> full red tint, opaque.
        let source = CompositionRenderer.sourcePreviewTinted(result, for: .red)
        XCTAssertEqual(source.rgba[0], 255)
        XCTAssertEqual(source.rgba[1], 0)
        XCTAssertEqual(source.rgba[2], 0)
        XCTAssertEqual(source.rgba[3], 255)
    }

    func testErrorMapNormalizesToUnitRange() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#808080", [.red: 0.5])
        ]
        // Target 1.0: color2 (0.5) is closest with error 0.25; color1 error 1.0.
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            weights: ChannelWeights(red: 1)
        )
        let map = CompositionRenderer.errorMap(result)
        // Single matched cell -> it is the max -> brightness 1.0.
        XCTAssertEqual(map.value(x: 0, y: 0), 1.0, accuracy: 1e-9)
    }

    func testBrightnessGridInversion() {
        let grid = BrightnessGrid(width: 2, height: 1, values: [0.2, 0.8])
        let inverted = grid.inverted()
        XCTAssertEqual(inverted.values.count, 2)
        XCTAssertEqual(inverted.values[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(inverted.values[1], 0.2, accuracy: 1e-9)
    }

    func testBrightnessGridUpsampleBlocksCells() {
        // 2x1 upsampled by 3 -> 6 wide x 3 tall, each cell a 3x3 block.
        let grid = BrightnessGrid(width: 2, height: 1, values: [0.1, 0.9])
        let up = grid.upsampled(by: 3)
        XCTAssertEqual(up.width, 6)
        XCTAssertEqual(up.height, 3)
        let expected = [Double](repeating: 0.1, count: 3) + [Double](repeating: 0.9, count: 3)
        XCTAssertEqual(up.values, expected + expected + expected)
    }
}
