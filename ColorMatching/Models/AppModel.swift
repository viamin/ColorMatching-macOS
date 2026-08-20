import Foundation
import AppKit
import Observation
import ColorComposerCore

/// The root application state: server/profile & color sync, source layers, composition
/// settings, and the solved result with derived preview images.
@MainActor
@Observable
final class AppModel {
    /// Keep the interactive preview bounded; 200×200 logical cells still fit in
    /// a 1600×1600 preview at this cap, while export/print retain the full raster.
    private static let maxPreviewPixelsPerCell = 8

    @ObservationIgnored
    private var previewRevision = 0

    @ObservationIgnored
    private var cachedCompositePreview: (key: CompositePreviewKey, image: RGBAImage)?

    @ObservationIgnored
    private var cachedSoftProofPreview: (key: SoftProofPreviewKey, preview: SoftProofPreview)?

    init() {
        catalog.configure(baseURL: URL(string: serverBaseURL), token: serverToken)
        catalog.onPaletteChanged = { [weak self] in
            self?.clearCompositionState()
        }
        catalog.onAuthenticationRequired = {
            await MainActor.run { ReauthPrompt.promptForToken() }
        }
        catalog.onTokenUpdated = { [weak self] newToken in
            self?.serverToken = newToken
        }
    }

    // MARK: - Catalog / server

    let catalog = ColorCatalog()

    var serverBaseURL: String {
        get { UserDefaults.standard.string(forKey: "serverBaseURL") ?? "http://localhost:4000" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverBaseURL")
            catalog.configure(baseURL: URL(string: newValue), token: serverToken)
        }
    }

    var serverToken: String {
        get { UserDefaults.standard.string(forKey: "serverToken") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverToken")
            catalog.configure(baseURL: URL(string: serverBaseURL), token: newValue)
        }
    }

    // MARK: - Source layers

    private(set) var layers: [SourceLayer] = [SourceLayer(), SourceLayer(), SourceLayer(), SourceLayer()]

    static let maxLayers = 4

    func loadLayer(_ index: Int, from url: URL) {
        guard index >= 0 && index < layers.count else { return }
        do {
            let (data, filename, _) = try ImageUtilities.load(from: url)
            layers[index].imageData = data
            layers[index].filename = filename
            // Auto-assign a condition if none yet, preferring unused ones.
            if layers[index].assignedCondition == nil {
                layers[index].assignedCondition = nextUnassignedCondition()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the given images into the next available empty slots, preserving
    /// images already loaded. Excess images are dropped once all slots are full.
    func appendImages(from urls: [URL]) {
        var slot = 0
        for url in urls {
            while slot < layers.count && layers[slot].hasImage { slot += 1 }
            guard slot < layers.count else { return }
            loadLayer(slot, from: url)
            slot += 1
        }
    }

    func removeLayer(_ index: Int) {
        guard index >= 0 && index < layers.count else { return }
        layers[index].imageData = nil
        layers[index].filename = nil
    }

    private func nextUnassignedCondition() -> LightingCondition? {
        let used = Set(layers.compactMap { $0.assignedCondition })
        return LightingCondition.all.first { !used.contains($0) }
    }

    var assignedConditions: Set<LightingCondition> {
        Set(layers.compactMap { $0.hasImage ? $0.assignedCondition : nil })
    }

    // MARK: - Composition settings

    var weights = ChannelWeights(red: 1, green: 1, blue: 1, lps: 1)
    var scorerKind: ScorerKind = .weightedSquaredError
    var logicalWidth = 200
    var logicalHeight = 200
    var pixelsPerCell = 4
    var rasterMode: RasterMode = .flat
    var physicalWidthMM = 200.0
    var physicalHeightMM = 200.0
    var showsPrintMarks = false
    var printMarksInsetMM = 3.0
    var printBleedMM = 0.0

    var presetSizes: [(label: String, size: Int)] {
        [("100 × 100", 100), ("200 × 200", 200), ("500 × 500", 500)]
    }

    private struct CompositePreviewKey: Equatable {
        let revision: Int
        let mode: RasterMode
        let pixelsPerCell: Int
    }

    private struct SoftProofPreviewKey: Equatable {
        let revision: Int
        let mode: RasterMode
        let pixelsPerCell: Int
        let profile: SoftProofProfile
    }


    // MARK: - Auto-regenerate

    /// When enabled, composition settings changes trigger a debounced background solve.
    var autoRegenerate: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRegenerate") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRegenerate") }
    }

    private var solveTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Schedules a debounced background solve. Safe to call on every settings
    /// change — earlier pending solves are canceled, so only the latest input
    /// produces a result.
    func scheduleAutoRegenerate() {
        guard autoRegenerate, hasResult, !catalog.colors.isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch { return }
            runSolve()
        }
    }

    /// Cancels any in-flight solve and starts a new one. Both the manual
    /// Generate action and the debounced auto-regenerate pipeline go through
    /// here so the prior task is always canceled *before* the new task is
    /// launched — and so `solveTask` never points to the task currently
    /// executing `generate()` (which would cancel itself).
    func runSolve() {
        solveTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.generate()
        }
        solveTask = task
    }

    // MARK: - Result

    private(set) var result: CompositionResult?
    private(set) var errorStatistics: ErrorStatistics?
    private(set) var isSolving = false
    private(set) var lastError: String?
    private var solvedGamut: ResponseGamut?

    var hasResult: Bool { result != nil }

    var eligibleColorCount: Int {
        catalog.eligibleColors(activeConditions: weights.activeConditions).count
    }

    /// Response-vector gamut to visualize: the solved one once a composition
    /// exists, otherwise the loaded colors alone. The palette-only form is what
    /// guides data entry before Generate has ever run, and it is cheap enough
    /// (no target grids to bin) to rebuild whenever the weights change.
    var responseGamut: ResponseGamut {
        solvedGamut ?? ResponseGamutAnalyzer().analyze(
            palette: catalog.colors,
            sourceGrids: [:],
            weights: weights
        )
    }

    // MARK: - Generation

    /// Builds source grids from layers and solves the composition.
    func generate() async {
        // Cancel any pending debounce; a manual Generate overrides it.
        // We intentionally do not cancel `solveTask` here: `runSolve` already
        // cancels the prior task before launching this one, and when
        // `generate()` is invoked via `runSolve`, `solveTask` IS the task
        // currently executing this method — cancelling it would cancel
        // ourselves, the solver would bail at the cancellation guard below,
        // and the result would never reach the UI.
        debounceTask?.cancel()

        let active = weights.activeConditions
        guard !active.isEmpty else {
            lastError = "Set at least one channel weight above zero."
            return
        }
        guard !catalog.colors.isEmpty else {
            lastError = "Load colors from the server, cache, or a project first."
            return
        }
        guard let grids = sourceGrids(for: active) else { return }

        let candidateColors = catalog.colors
        let weights = self.weights
        let solver = CompositionSolver(scorer: scorerKind.makeScorer())
        isSolving = true
        lastError = nil

        let solved: Result<CompositionResult, Error>
        do {
            let r = try solver.solve(palette: candidateColors, sourceGrids: grids, weights: weights)
            guard !Task.isCancelled else {
                isSolving = false
                return
            }
            solved = .success(r)
        } catch {
            solved = .failure(error)
        }

        guard !Task.isCancelled else {
            isSolving = false
            return
        }
        isSolving = false
        switch solved {
        case .success(let r):
            result = r
            errorStatistics = ErrorStatistics(result: r)
            solvedGamut = ResponseGamutAnalyzer().analyze(
                palette: candidateColors,
                sourceGrids: grids,
                weights: weights
            )
            invalidatePreviewCaches()
        case .failure(let error):
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One brightness grid per active condition, or `nil` (having set
    /// `lastError`) when an active channel has no assigned source image.
    private func sourceGrids(for active: [LightingCondition]) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in active {
            guard let layer = layers.first(where: { $0.hasImage && $0.assignedCondition == condition }),
                  let grid = layer.brightnessGrid(width: logicalWidth, height: logicalHeight) else {
                lastError = "No source image is assigned to the active “\(condition.displayName)” channel."
                return nil
            }
            grids[condition] = grid
        }
        return grids
    }

    private func clearCompositionState() {
        solveTask?.cancel()
        solveTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        result = nil
        errorStatistics = nil
        lastError = nil
        solvedGamut = nil
        isSolving = false
        invalidatePreviewCaches()
    }

    // MARK: - Derived images

    var compositeRGBA: RGBAImage? {
        guard let result else { return nil }
        return CompositionRenderer.composite(result)
    }

    var canPrintComposite: Bool {
        hasResult && exportRaster != nil && hasFinitePositivePhysicalPrintSize
    }

    var canPrintTiles: Bool {
        hasResult && hasFinitePositiveTileSize && tilePlan != nil
    }

    /// On-screen composite that visibly marks unmatched cells (magenta) so a
    /// no-data or partial-match result is never invisible. The preview uses
    /// the selected raster mode, but caps the per-cell rasterization cost and
    /// caches the resulting image so SwiftUI refreshes do not re-render large
    /// export-sized rasters on the main actor. Export/print keep using
    /// `compositeRGBA` (transparent for unmatched, flat mode).
    var compositePreviewRGBA: RGBAImage? {
        guard let result else { return nil }
        let key = CompositePreviewKey(
            revision: previewRevision,
            mode: rasterMode,
            pixelsPerCell: previewPixelsPerCell
        )
        if let cachedCompositePreview, cachedCompositePreview.key == key {
            return cachedCompositePreview.image
        }

        let image = CompositionRenderer.compositePreview(
            result,
            mode: rasterMode,
            pixelsPerCell: previewPixelsPerCell
        )
        cachedCompositePreview = (key, image)
        return image
    }

    var softProofProfileName: String {
        activePrinterProfile?.displayName ?? "Generic printer"
    }

    var softProofPreview: SoftProofPreview? {
        guard let result else { return nil }
        let profile = activePrinterProfile?.softProofProfile ?? .genericPrinter
        let key = SoftProofPreviewKey(
            revision: previewRevision,
            mode: rasterMode,
            pixelsPerCell: previewPixelsPerCell,
            profile: profile
        )
        if let cachedSoftProofPreview, cachedSoftProofPreview.key == key {
            return cachedSoftProofPreview.preview
        }

        let preview = CompositionRenderer.softProofPreview(
            result,
            profile: profile,
            mode: rasterMode,
            pixelsPerCell: previewPixelsPerCell
        )
        cachedSoftProofPreview = (key, preview)
        return preview
    }

    /// True when every cell failed to match — usually a missing-measurement gap.
    var allCellsUnmatched: Bool {
        guard let result, result.cellCount > 0 else { return false }
        return result.unmatchedCellCount == result.cellCount
    }

    var errorMapGrid: BrightnessGrid? {
        guard let result else { return nil }
        return CompositionRenderer.errorMap(result)
    }

    func lightingPreview(for condition: LightingCondition) -> BrightnessGrid? {
        guard let result else { return nil }
        return CompositionRenderer.lightingPreview(result, for: condition)
    }

    /// Per-channel lighting preview tinted by the channel's color (red/green/
    /// blue/amber), so previews read like the image under each colored light.
    func lightingPreviewTinted(for condition: LightingCondition) -> RGBAImage? {
        guard let result else { return nil }
        return CompositionRenderer.lightingPreviewTinted(result, for: condition)
    }

    /// True when the solved result carries a source grid for this condition, so
    /// the comparison view can show source / difference for that channel.
    func hasSource(for condition: LightingCondition) -> Bool {
        result?.sourceGrids[condition] != nil
    }

    /// Source brightness for a condition, tinted by the channel's color — the
    /// counterpart to `lightingPreviewTinted`, for side-by-side comparison.
    func sourcePreviewTinted(for condition: LightingCondition) -> RGBAImage? {
        guard let result, result.sourceGrids[condition] != nil else { return nil }
        return CompositionRenderer.sourcePreviewTinted(result, for: condition)
    }

    /// Source-vs-prediction difference for a condition, rendered with a
    /// diverging colormap (blue = palette under-shoots, red = over-shoots).
    func lightingDifferenceTinted(for condition: LightingCondition) -> RGBAImage? {
        guard let result, result.sourceGrids[condition] != nil else { return nil }
        return CompositionRenderer.lightingDifferenceTinted(result, for: condition)
    }

    /// The export/print raster: the solved composition rendered in the
    /// selected `rasterMode` at `pixelsPerCell` resolution. Flat mode is the
    /// v1 one-color-per-cell baseline; halftone and two-color turn each cell
    /// into a sub-cell pattern that better matches targets no single color
    /// can hit.
    var exportRaster: RGBAImage? {
        guard let result else { return nil }
        return CompositionRenderer.composite(
            result,
            mode: rasterMode,
            pixelsPerCell: pixelsPerCell
        )
    }

    private var activePrinterProfile: PrinterProfileDTO? {
        guard let id = catalog.selectedPrinterProfileID else { return nil }
        if let profile = catalog.colorsForProfile, profile.id == id {
            return profile
        }
        return catalog.printerProfiles.first(where: { $0.id == id })
    }

    // MARK: - Export / print

    func exportComposite(to url: URL) throws {
        guard let raster = exportRaster,
              let cgImage = ImageUtilities.makeCGImage(from: raster) else {
            throw ImageWriteError.writeFailed
        }
        try ImageUtilities.write(cgImage, to: url)
    }

    func printComposite() {
        guard hasFinitePositivePhysicalPrintSize, let raster = exportRaster else { return }
        PrintSupport.print(
            raster,
            physicalSizeMM: CGSize(width: physicalWidthMM, height: physicalHeightMM),
            overlay: printOverlayOptions
        )
    }

    // MARK: - Large-format tiling

    /// When enabled, `exportTiles`/`printTiles` split the export raster into
    /// page-sized tiles instead of producing one oversized file/job — for
    /// artwork larger than the printer's paper (issue #11).
    var tilingEnabled = false
    var tileWidthMM = 200.0
    var tileHeightMM = 200.0
    var tileOverlapMM = 10.0

    /// The planned tile layout for the current export raster, in image pixel
    /// coordinates. `nil` when tiling is disabled or there is no result yet.
    /// Tile edges snap to `pixelsPerCell` boundaries so a logical cell is not
    /// split across two tiles.
    var tilePlan: [TileSpec]? {
        guard tilingEnabled, let raster = exportRaster else { return nil }
        guard hasFinitePositivePhysicalPrintSize else { return nil }
        guard hasFinitePositiveTileSize else { return nil }
        let scaleX = Double(raster.width) / physicalWidthMM
        let scaleY = Double(raster.height) / physicalHeightMM
        let tileWidthPx = max(1, Int((tileWidthMM * scaleX).rounded()))
        let tileHeightPx = max(1, Int((tileHeightMM * scaleY).rounded()))
        let overlapPx = max(0, Int((tileOverlapMM * scaleX).rounded()))
        return RasterTiler.plan(
            imageWidth: raster.width,
            imageHeight: raster.height,
            tileWidth: tileWidthPx,
            tileHeight: tileHeightPx,
            overlap: overlapPx,
            cellSize: pixelsPerCell
        )
    }

    /// Exports one image file per tile into `directoryURL`, named
    /// `tile_<row>_<column>.png`.
    func exportTiles(to directoryURL: URL) throws {
        guard let raster = exportRaster, let tiles = tilePlan else { return }
        for tile in tiles {
            let tileImage = RasterTiler.extract(raster, tile: tile)
            guard let cgImage = ImageUtilities.makeCGImage(from: tileImage) else {
                throw ImageWriteError.writeFailed
            }
            let url = directoryURL.appendingPathComponent("tile_\(tile.row)_\(tile.column).png")
            try ImageUtilities.write(cgImage, to: url)
        }
    }

    /// Presents one native print job per tile, in row-major order.
    func printTiles() {
        guard let raster = exportRaster, let tiles = tilePlan else { return }
        guard raster.width > 0, raster.height > 0 else { return }
        let scaleX = physicalWidthMM / Double(raster.width)
        let scaleY = physicalHeightMM / Double(raster.height)
        for tile in tiles {
            let tileImage = RasterTiler.extract(raster, tile: tile)
            let size = CGSize(width: Double(tile.width) * scaleX, height: Double(tile.height) * scaleY)
            PrintSupport.print(
                tileImage,
                physicalSizeMM: size,
                overlay: tilePrintOverlayOptions,
                title: "ColorMatching – Tile \(tile.row + 1)×\(tile.column + 1)"
            )
        }
    }

    // MARK: - Project persistence

    var projectURL: URL?

    func saveProject(to url: URL) throws {
        let snapshot = makeSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        projectURL = url
    }

    func loadProject(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(ProjectDocument.self, from: data)
        applySnapshot(snapshot)
        projectURL = url
    }

    private func makeSnapshot() -> ProjectDocument {
        let layerSnaps = layers.compactMap { layer -> LayerSnapshot? in
            guard let data = layer.imageData else { return nil }
            return LayerSnapshot(
                imageData: data,
                filename: layer.filename,
                assignedCondition: layer.assignedCondition,
                inverted: layer.inverted,
                scalingMode: layer.scalingMode,
                colorSpace: layer.colorSpace
            )
        }
        return ProjectDocument(
            serverBaseURL: serverBaseURL,
            apiToken: serverToken,
            printerProfileID: catalog.selectedPrinterProfileID,
            printerProfileSnapshot: activePrinterProfile,
            colorSnapshot: catalog.colors.map { ColorSnapshot($0) },
            weights: weights,
            scorerKind: scorerKind,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelsPerCell: pixelsPerCell,
            rasterMode: rasterMode,
            physicalWidthMM: physicalWidthMM,
            physicalHeightMM: physicalHeightMM,
            printOverlayOptions: printOverlayOptions,
            tilingEnabled: tilingEnabled,
            tileWidthMM: tileWidthMM,
            tileHeightMM: tileHeightMM,
            tileOverlapMM: tileOverlapMM,
            layers: layerSnaps
        )
    }

    private func applySnapshot(_ s: ProjectDocument) {
        clearCompositionState()
        serverBaseURL = s.serverBaseURL
        serverToken = s.apiToken
        catalog.restoreSnapshot(
            printerProfileID: s.printerProfileID,
            printerProfile: s.printerProfileSnapshot,
            colors: s.colorSnapshot.map { $0.toColor() }
        )

        weights = s.weights
        scorerKind = s.scorerKind
        logicalWidth = s.logicalWidth
        logicalHeight = s.logicalHeight
        pixelsPerCell = s.pixelsPerCell
        rasterMode = s.rasterMode
        physicalWidthMM = Self.sanitizedMeasurement(s.physicalWidthMM)
        physicalHeightMM = Self.sanitizedMeasurement(s.physicalHeightMM)
        showsPrintMarks = s.printOverlayOptions.showsMarks
        printMarksInsetMM = Self.sanitizedMeasurement(s.printOverlayOptions.markInsetMM)
        printBleedMM = Self.sanitizedMeasurement(s.printOverlayOptions.bleedMM)
        tilingEnabled = s.tilingEnabled
        tileWidthMM = Self.sanitizedMeasurement(s.tileWidthMM)
        tileHeightMM = Self.sanitizedMeasurement(s.tileHeightMM)
        tileOverlapMM = Self.sanitizedMeasurement(s.tileOverlapMM)

        let restored = s.layers.enumerated().map { (index, snap) -> SourceLayer in
            let layer = index < layers.count ? layers[index] : SourceLayer()
            layer.imageData = snap.imageData
            layer.filename = snap.filename
            layer.assignedCondition = snap.assignedCondition
            layer.inverted = snap.inverted
            layer.scalingMode = snap.scalingMode
            layer.colorSpace = snap.colorSpace
            return layer
        }
        while layers.count < Self.maxLayers { layers.append(SourceLayer()) }
        for i in 0..<Self.maxLayers {
            layers[i] = i < restored.count ? restored[i] : SourceLayer()
        }
    }

    private var printOverlayOptions: PrintOverlayOptions {
        PrintOverlayOptions(
            showsMarks: showsPrintMarks,
            markInsetMM: Self.sanitizedMeasurement(printMarksInsetMM),
            bleedMM: Self.sanitizedMeasurement(printBleedMM)
        )
    }

    private var tilePrintOverlayOptions: PrintOverlayOptions {
        // Tile sizes are planned against the configured page size, so overlays
        // must stay off here or macOS will enlarge/clamp each printed sheet.
        PrintOverlayOptions()
    }

    private var hasFinitePositivePhysicalPrintSize: Bool {
        physicalWidthMM.isFinite && physicalWidthMM > 0 &&
            physicalHeightMM.isFinite && physicalHeightMM > 0
    }

    private var hasFinitePositiveTileSize: Bool {
        tileWidthMM.isFinite && tileWidthMM > 0 &&
            tileHeightMM.isFinite && tileHeightMM > 0
    }

    private static func sanitizedMeasurement(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private var previewPixelsPerCell: Int {
        min(max(pixelsPerCell, 1), Self.maxPreviewPixelsPerCell)
    }

    private func invalidatePreviewCaches() {
        previewRevision += 1
        cachedCompositePreview = nil
        cachedSoftProofPreview = nil
    }
}
