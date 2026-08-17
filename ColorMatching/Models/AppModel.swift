import Foundation
import AppKit
import ColorComposerCore

private struct SourceLayerSnapshot: Sendable {
    let assignedCondition: LightingCondition?
    let imageData: Data?
    let scalingMode: ImageScalingMode
    let inverted: Bool
    let colorSpace: BrightnessColorSpace
}

private enum SourceGridBuildError: LocalizedError {
    case missingSourceImage(LightingCondition)
    case unreadableSourceImage(LightingCondition)

    var errorDescription: String? {
        switch self {
        case .missingSourceImage(let condition):
            return "No source image is assigned to the active “\(condition.displayName)” channel."
        case .unreadableSourceImage(let condition):
            return "The source image assigned to the active “\(condition.displayName)” channel could not be read."
        }
    }
}

/// The root application state: server/profile & color sync, source layers, composition
/// settings, and the solved result with derived preview images.
///
/// Main-actor isolated so it can register edits with the main-actor-isolated
/// `UndoManager` (issue #14); the heavy solve runs off the main actor in
/// `solveComposition(_:…)`.
@MainActor
@Observable
final class AppModel {
    init() {
        catalog.onPaletteChanged = { [weak self] in
            self?.clearCompositionState()
        }
        wireUndoHooks()
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
            // Importing an image is not a user composition edit, so the
            // auto-assigned channel must not register an undo action.
            undo.performWithoutRegistration {
                layers[index].imageData = data
                layers[index].filename = filename
                // Auto-assign a condition if none yet, preferring unused ones.
                if layers[index].assignedCondition == nil {
                    layers[index].assignedCondition = nextUnassignedCondition()
                }
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

    var weights: ChannelWeights = ChannelWeights(red: 1, green: 1, blue: 1, lps: 1) {
        didSet {
            guard oldValue != weights else { return }
            noteEdit(kind: "weights", actionName: "Weights") { $0.weights = oldValue }
        }
    }
    var scorerKind: ScorerKind = .weightedSquaredError {
        didSet {
            guard oldValue != scorerKind else { return }
            noteEdit(kind: "scorer", actionName: "Scorer") { $0.scorerKind = oldValue }
        }
    }
    var logicalWidth = 200 {
        didSet {
            guard oldValue != logicalWidth else { return }
            noteEdit(kind: "resolution", actionName: "Resolution") { $0.logicalWidth = oldValue }
        }
    }
    var logicalHeight = 200 {
        didSet {
            guard oldValue != logicalHeight else { return }
            noteEdit(kind: "resolution", actionName: "Resolution") { $0.logicalHeight = oldValue }
        }
    }
    var pixelsPerCell = 4 {
        didSet {
            guard oldValue != pixelsPerCell else { return }
            noteEdit(kind: "exportScale", actionName: "Export Scale") { $0.pixelsPerCell = oldValue }
        }
    }
    var physicalWidthMM = 200.0
    var physicalHeightMM = 200.0
    var showsPrintMarks = false
    var printMarksInsetMM = 3.0
    var printBleedMM = 0.0

    var presetSizes: [(label: String, size: Int)] {
        [("100 × 100", 100), ("200 × 200", 200), ("500 × 500", 500)]
    }

    // MARK: - Undo support (issue #14)

    /// Registers user composition edits with the window's undo manager so
    /// ⌘Z / ⇧⌘Z and the Edit menu's Undo/Redo drive them. Only edits noted
    /// here reach the undo stack — solves and results never do.
    let undo = CompositionUndo()

    /// Connects window undo support; called when the window's undo manager
    /// becomes available and again when a fresh model takes over.
    func attachUndoManager(_ manager: UndoManager?) {
        undo.attach(manager)
    }

    /// Builds the pre-edit snapshot for a settings edit by reverting one
    /// field of the current snapshot.
    private func noteEdit(kind: String, actionName: String, revert: (inout CompositionEdit) -> Void) {
        var restore = compositionEdit()
        revert(&restore)
        undo.noteUserEdit(kind: kind, actionName: actionName, restore: restore, swap: editSwap)
    }

    /// Builds the pre-edit snapshot for a layer-field edit.
    private func noteLayerEdit(_ layer: SourceLayer, edit: LayerEdit) {
        guard let index = layers.firstIndex(where: { $0 === layer }) else { return }
        var restore = compositionEdit()
        restore.layers[index] = edit.reverted(restore.layers[index])
        undo.noteUserEdit(
            kind: "layer.\(layer.id.uuidString).\(edit.key)",
            actionName: edit.actionName,
            restore: restore,
            swap: editSwap
        )
    }

    /// The current undoable settings, mirrored per layer by identity.
    private func compositionEdit() -> CompositionEdit {
        CompositionEdit(
            weights: weights,
            scorerKind: scorerKind,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelsPerCell: pixelsPerCell,
            layers: layers.map {
                CompositionEdit.Layer(
                    id: $0.id,
                    assignedCondition: $0.assignedCondition,
                    inverted: $0.inverted,
                    scalingMode: $0.scalingMode,
                    colorSpace: $0.colorSpace
                )
            }
        )
    }

    /// Applies `edit` and returns the snapshot it replaced; undo and redo both
    /// run through here so the inverse is always the displaced state. May
    /// exceed the size target: it is a flat field-by-field copy.
    private func swapEdit(_ edit: CompositionEdit) -> CompositionEdit {
        let previous = compositionEdit()
        weights = edit.weights
        scorerKind = edit.scorerKind
        logicalWidth = edit.logicalWidth
        logicalHeight = edit.logicalHeight
        pixelsPerCell = edit.pixelsPerCell
        for layerEdit in edit.layers {
            guard let index = layers.firstIndex(where: { $0.id == layerEdit.id }) else { continue }
            layers[index].assignedCondition = layerEdit.assignedCondition
            layers[index].inverted = layerEdit.inverted
            layers[index].scalingMode = layerEdit.scalingMode
            layers[index].colorSpace = layerEdit.colorSpace
        }
        scheduleAutoRegenerate()
        return previous
    }

    /// Weak wrapper: undo closures live in the window's undo manager and must
    /// not keep a replaced model (and its images) alive.
    private var editSwap: (CompositionEdit) -> CompositionEdit {
        { [weak self] edit in
            guard let self else { return edit }
            return self.swapEdit(edit)
        }
    }

    private func wireUndoHooks() {
        for layer in layers {
            layer.onUndoableEdit = { [weak self] layer, edit in
                self?.noteLayerEdit(layer, edit: edit)
            }
        }
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
            lastError = "Load colors from the server first."
            return
        }
        let layerSnapshots = sourceLayerSnapshots()

        isSolving = true
        lastError = nil
        let outcome = await Self.solveComposition(
            palette: catalog.colors,
            activeConditions: active,
            layerSnapshots: layerSnapshots,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            weights: weights,
            scorerKind: scorerKind
        )

        guard !Task.isCancelled else {
            isSolving = false
            return
        }
        isSolving = false
        switch outcome {
        case .success(let solved):
            result = solved.result
            errorStatistics = solved.statistics
            solvedGamut = solved.gamut
        case .failure(let error):
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private struct SolvedComposition {
        let result: CompositionResult
        let statistics: ErrorStatistics
        let gamut: ResponseGamut
    }

    private enum SolveOutcome {
        case success(SolvedComposition)
        case failure(Error)
    }

    /// Runs the solve and the analyses derived from it off the main actor.
    /// `AppModel` is main-actor isolated to host undo registration (issue
    /// #14), so the heavy work is funneled through this nonisolated helper.
    private nonisolated static func solveComposition(
        palette: [PaletteColor],
        activeConditions: [LightingCondition],
        layerSnapshots: [SourceLayerSnapshot],
        logicalWidth: Int,
        logicalHeight: Int,
        weights: ChannelWeights,
        scorerKind: ScorerKind
    ) async -> SolveOutcome {
        do {
            let sourceGrids = try sourceGrids(
                for: activeConditions,
                from: layerSnapshots,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight
            )
            let solver = CompositionSolver(scorer: scorerKind.makeScorer())
            let solved = try solver.solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            return .success(SolvedComposition(
                result: solved,
                statistics: ErrorStatistics(result: solved),
                gamut: ResponseGamutAnalyzer().analyze(palette: palette, sourceGrids: sourceGrids, weights: weights)
            ))
        } catch {
            return .failure(error)
        }
    }

    /// Captures the current layer settings on the main actor so image decoding
    /// and resampling can run off-actor in `solveComposition`.
    private func sourceLayerSnapshots() -> [SourceLayerSnapshot] {
        layers.map {
            SourceLayerSnapshot(
                assignedCondition: $0.assignedCondition,
                imageData: $0.imageData,
                scalingMode: $0.scalingMode,
                inverted: $0.inverted,
                colorSpace: $0.colorSpace
            )
        }
    }

    /// One brightness grid per active condition, or throws when an active
    /// channel has no assigned source image or its image data is unreadable.
    private nonisolated static func sourceGrids(
        for active: [LightingCondition],
        from layers: [SourceLayerSnapshot],
        logicalWidth: Int,
        logicalHeight: Int
    ) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in active {
            guard let layer = layers.first(where: { $0.imageData != nil && $0.assignedCondition == condition }) else {
                throw SourceGridBuildError.missingSourceImage(condition)
            }
            guard let grid = brightnessGrid(for: layer, logicalWidth: logicalWidth, logicalHeight: logicalHeight) else {
                throw layer.imageData == nil
                    ? SourceGridBuildError.missingSourceImage(condition)
                    : SourceGridBuildError.unreadableSourceImage(condition)
            }
            grids[condition] = grid
        }
        return grids
    }

    private nonisolated static func brightnessGrid(
        for layer: SourceLayerSnapshot,
        logicalWidth: Int,
        logicalHeight: Int
    ) -> BrightnessGrid? {
        guard let imageData = layer.imageData,
              let cgImage = ImageUtilities.makeCGImage(from: imageData) else { return nil }
        return BrightnessGridSampler.sample(
            cgImage: cgImage,
            targetWidth: logicalWidth,
            targetHeight: logicalHeight,
            scalingMode: layer.scalingMode,
            invert: layer.inverted,
            colorSpace: layer.colorSpace
        )
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
    /// no-data or partial-match result is never invisible. Export/print keep
    /// using `compositeRGBA` (transparent for unmatched).
    var compositePreviewRGBA: RGBAImage? {
        guard let result else { return nil }
        return CompositionRenderer.compositePreview(result)
    }

    var softProofProfileName: String {
        activePrinterProfile?.displayName ?? "Generic printer"
    }

    var softProofPreview: SoftProofPreview? {
        guard let result else { return nil }
        let profile = activePrinterProfile?.softProofProfile ?? .genericPrinter
        return CompositionRenderer.softProofPreview(result, profile: profile)
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

    /// The upscaled composite raster (logical size × pixelsPerCell), suitable
    /// for export and printing.
    var exportRaster: RGBAImage? {
        guard let result else { return nil }
        let base = CompositionRenderer.composite(result)
        guard pixelsPerCell > 1 else { return base }
        return upscale(base, by: pixelsPerCell)
    }

    private func upscale(_ image: RGBAImage, by factor: Int) -> RGBAImage {
        let outW = image.width * factor
        let outH = image.height * factor
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let base = (y * image.width + x) * 4
                let (r, g, b, a) = (image.rgba[base], image.rgba[base+1], image.rgba[base+2], image.rgba[base+3])
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let o = ((y*factor+dy)*outW + (x*factor+dx)) * 4
                        rgba[o] = r; rgba[o+1] = g; rgba[o+2] = b; rgba[o+3] = a
                    }
                }
            }
        }
        return RGBAImage(width: outW, height: outH, rgba: rgba)
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
        // Loading a project replaces state wholesale: it is not a user edit,
        // and stale pre-load undo actions would restore a half-replaced model.
        undo.performWithoutRegistration { applySnapshotContents(s) }
        wireUndoHooks()
        undo.reset()
    }

    private func applySnapshotContents(_ s: ProjectDocument) {
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
}
