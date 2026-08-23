import Foundation
import CoreGraphics
import Observation
import ColorComposerCore

private struct SourceLayerSnapshot: Sendable {
    let assignedCondition: LightingCondition?
    let cgImage: SendableCGImage?
    let scalingMode: ImageScalingMode
    let inverted: Bool
    let colorSpace: BrightnessColorSpace
}

/// `CGImage` instances are immutable snapshots once created, so it is safe to
/// move the cached image through the off-main solve pipeline.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
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
    /// Keep the interactive preview bounded; 200×200 logical cells still fit in
    /// a 1600×1600 preview at this cap, while export/print retain the full raster.
    private static let maxPreviewPixelsPerCell = 8

    @ObservationIgnored
    private var previewRevision = 0

    @ObservationIgnored
    private var cachedCompositePreview: (key: CompositePreviewKey, image: RGBAImage)?

    @ObservationIgnored
    private var cachedSoftProofPreview: (key: SoftProofPreviewKey, preview: SoftProofPreview)?

    /// The token this catalog's last `configure(...)` call was made with. Every
    /// `AppModel` window shares the same `UserDefaults`-backed `serverToken`, so
    /// when another window's re-auth persists a fresher token here, this
    /// window's `onAuthenticationRequired` can hand it back without prompting
    /// (see below) rather than showing a redundant prompt for a token that is
    /// already stale in `UserDefaults`.
    @ObservationIgnored
    private var configuredToken = ""

    private struct LayerState {
        let imageData: Data?
        let filename: String?
        let assignedCondition: LightingCondition?
        let inverted: Bool
        let scalingMode: ImageScalingMode
        let colorSpace: BrightnessColorSpace
    }

    init() {
        // No deinit-time cleanup is needed: these catalog callbacks capture self
        // weakly and no-op after deallocation, and in-flight catalog requests are
        // generation-guarded inside ColorCatalog.
        catalog.onPaletteChanged = { [weak self] in
            self?.handleUpstreamChange()
        }
        catalog.onAuthenticationRequired = { [weak self] in
            await MainActor.run {
                guard let self else { return nil }
                // Another window's re-auth may have stored a fresher token
                // than this catalog was configured with.
                let stored = self.serverToken
                if !stored.isEmpty, stored != self.configuredToken {
                    return stored
                }
                return ReauthPrompt.promptForToken()
            }
        }
        catalog.onTokenUpdated = { [weak self] newToken in
            UserDefaults.standard.set(newToken, forKey: "serverToken")
            self?.configuredToken = newToken
        }
        catalog.configure(baseURL: URL(string: serverBaseURL), token: serverToken)
        configuredToken = serverToken
        wireUndoHooks()
    }

    // MARK: - Catalog / server

    let catalog = ColorCatalog()

    var serverBaseURL: String {
        get { UserDefaults.standard.string(forKey: "serverBaseURL") ?? "http://localhost:4000" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverBaseURL")
            catalog.configure(baseURL: URL(string: newValue), token: serverToken)
            configuredToken = serverToken
            scheduleCatalogConfigurationChange()
        }
    }

    var serverToken: String {
        get { UserDefaults.standard.string(forKey: "serverToken") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverToken")
            catalog.configure(baseURL: URL(string: serverBaseURL), token: newValue)
            configuredToken = newValue
            scheduleCatalogConfigurationChange()
        }
    }

    // MARK: - Source layers

    private(set) var layers: [SourceLayer] = [SourceLayer(), SourceLayer(), SourceLayer(), SourceLayer()]

    static let maxLayers = 4

    @discardableResult
    func loadLayer(_ index: Int, from url: URL) -> Bool {
        guard index >= 0 && index < layers.count else { return false }
        do {
            let previousState = layerState(at: index)
            let (data, filename, _) = try ImageUtilities.load(from: url)
            registerLayerRestoreUndo(actionName: "Load Layer", index: index, restore: previousState)
            undoController.performWithoutRegistration {
                layers[index].imageData = data
                layers[index].filename = filename
                if layers[index].assignedCondition == nil {
                    layers[index].assignedCondition = nextUnassignedCondition()
                }
            }
            lastError = nil
            handleUpstreamChange()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Loads the given images into the next available empty slots, preserving
    /// images already loaded. Excess images are dropped once all slots are full.
    func appendImages(from urls: [URL]) {
        var slot = 0
        for url in urls {
            while slot < layers.count && layers[slot].hasImage { slot += 1 }
            guard slot < layers.count else { return }
            if loadLayer(slot, from: url) {
                slot += 1
            }
        }
    }

    func removeLayer(_ index: Int) {
        guard index >= 0 && index < layers.count else { return }
        guard layers[index].hasImage else { return }
        registerLayerRestoreUndo(actionName: "Remove Layer", index: index, restore: layerState(at: index))
        undoController.performWithoutRegistration {
            layers[index].imageData = nil
            layers[index].filename = nil
        }
        handleUpstreamChange()
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
            noteEdit(kind: "weights", actionName: "Change Weight") { $0.weights = oldValue }
        }
    }
    var scorerKind: ScorerKind = .weightedSquaredError {
        didSet {
            guard oldValue != scorerKind else { return }
            noteEdit(kind: "scorer", actionName: "Change Scorer") { $0.scorerKind = oldValue }
        }
    }
    var logicalWidth = 200 {
        didSet {
            guard oldValue != logicalWidth else { return }
            noteEdit(kind: "resolution", actionName: "Change Resolution") { $0.logicalWidth = oldValue }
        }
    }
    var logicalHeight = 200 {
        didSet {
            guard oldValue != logicalHeight else { return }
            noteEdit(kind: "resolution", actionName: "Change Resolution") { $0.logicalHeight = oldValue }
        }
    }
    var pixelsPerCell = 4 {
        didSet {
            guard oldValue != pixelsPerCell else { return }
            noteEdit(kind: "exportScale", actionName: "Change Export Scale") { $0.pixelsPerCell = oldValue }
        }
    }
    var rasterMode: RasterMode = .flat {
        didSet {
            guard oldValue != rasterMode else { return }
            noteEdit(kind: "rasterMode", actionName: "Change Raster Mode") { $0.rasterMode = oldValue }
        }
    }
    var physicalWidthMM = 200.0 {
        didSet {
            guard oldValue != physicalWidthMM else { return }
            noteEdit(kind: "printSize", actionName: "Change Print Size") { $0.physicalWidthMM = oldValue }
        }
    }
    var physicalHeightMM = 200.0 {
        didSet {
            guard oldValue != physicalHeightMM else { return }
            noteEdit(kind: "printSize", actionName: "Change Print Size") { $0.physicalHeightMM = oldValue }
        }
    }
    var showsPrintMarks = false {
        didSet {
            guard oldValue != showsPrintMarks else { return }
            noteEdit(kind: "printMarks", actionName: "Toggle Print Marks") { $0.showsPrintMarks = oldValue }
        }
    }
    var printMarksInsetMM = 3.0 {
        didSet {
            guard oldValue != printMarksInsetMM else { return }
            noteEdit(kind: "printMarks", actionName: "Change Print Marks") { $0.printMarksInsetMM = oldValue }
        }
    }
    var printBleedMM = 0.0 {
        didSet {
            guard oldValue != printBleedMM else { return }
            noteEdit(kind: "printBleed", actionName: "Change Bleed") { $0.printBleedMM = oldValue }
        }
    }

    var presetSizes: [(label: String, size: Int)] {
        [("100 × 100", 100), ("200 × 200", 200), ("500 × 500", 500)]
    }

    // MARK: - Undo support (issue #14)

    /// Registers user composition edits with the window's undo manager so
    /// ⌘Z / ⇧⌘Z and the Edit menu's Undo/Redo drive them. Only edits noted
    /// here reach the undo stack — solves and results never do.
    let undoController = CompositionUndo()

    /// Connects window undo support; called when the window's undo manager
    /// becomes available and again when a fresh model takes over.
    func attachUndoManager(_ manager: UndoManager?) {
        undoController.attach(manager)
    }

    func setUndoManager(_ manager: UndoManager?) {
        attachUndoManager(manager)
    }

    var canUndo: Bool { undoController.undoManager?.canUndo ?? false }
    var canRedo: Bool { undoController.undoManager?.canRedo ?? false }

    var undoMenuTitle: String {
        menuTitle(prefix: "Undo", actionName: undoController.undoManager?.undoActionName)
    }

    var redoMenuTitle: String {
        menuTitle(prefix: "Redo", actionName: undoController.undoManager?.redoActionName)
    }

    func undo() {
        undoController.undoManager?.undo()
    }

    func redo() {
        undoController.undoManager?.redo()
    }

    func setWeight(_ keyPath: WritableKeyPath<ChannelWeights, Double>, to newValue: Double) {
        var updated = weights
        guard updated[keyPath: keyPath] != newValue else { return }
        updated[keyPath: keyPath] = newValue
        weights = updated
        handleUpstreamChange()
    }

    func setLogicalWidth(_ newValue: Int) {
        guard logicalWidth != newValue else { return }
        logicalWidth = newValue
        handleUpstreamChange()
    }

    func setLogicalHeight(_ newValue: Int) {
        guard logicalHeight != newValue else { return }
        logicalHeight = newValue
        handleUpstreamChange()
    }

    func setLogicalSize(width: Int, height: Int) {
        guard logicalWidth != width || logicalHeight != height else { return }
        var restore = compositionEdit()
        restore.logicalWidth = logicalWidth
        restore.logicalHeight = logicalHeight
        undoController.noteUserEdit(kind: "resolution", actionName: "Change Resolution", restore: restore, swap: editSwap)
        undoController.performWithoutRegistration {
            logicalWidth = width
            logicalHeight = height
        }
        handleUpstreamChange()
    }

    func setPixelsPerCell(_ newValue: Int) {
        guard pixelsPerCell != newValue else { return }
        pixelsPerCell = newValue
        handleUpstreamChange()
    }

    func setLayerAssignedCondition(_ index: Int, to newValue: LightingCondition?) {
        guard index >= 0 && index < layers.count else { return }
        guard layers[index].assignedCondition != newValue else { return }
        layers[index].assignedCondition = newValue
        handleUpstreamChange()
    }

    func setLayerScalingMode(_ index: Int, to newValue: ImageScalingMode) {
        guard index >= 0 && index < layers.count else { return }
        guard layers[index].scalingMode != newValue else { return }
        layers[index].scalingMode = newValue
        handleUpstreamChange()
    }

    func setLayerInverted(_ index: Int, to newValue: Bool) {
        guard index >= 0 && index < layers.count else { return }
        guard layers[index].inverted != newValue else { return }
        layers[index].inverted = newValue
        handleUpstreamChange()
    }

    /// Builds the pre-edit snapshot for a settings edit by reverting one
    /// field of the current snapshot.
    private func noteEdit(kind: String, actionName: String, revert: (inout CompositionEdit) -> Void) {
        var restore = compositionEdit()
        revert(&restore)
        undoController.noteUserEdit(kind: kind, actionName: actionName, restore: restore, swap: editSwap)
    }

    /// Builds the pre-edit snapshot for a layer-field edit.
    private func noteLayerEdit(_ layer: SourceLayer, edit: LayerEdit) {
        guard let index = layers.firstIndex(where: { $0 === layer }) else { return }
        var restore = compositionEdit()
        restore.layers[index] = edit.reverted(restore.layers[index])
        undoController.noteUserEdit(
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
            rasterMode: rasterMode,
            physicalWidthMM: physicalWidthMM,
            physicalHeightMM: physicalHeightMM,
            showsPrintMarks: showsPrintMarks,
            printMarksInsetMM: printMarksInsetMM,
            printBleedMM: printBleedMM,
            tilingEnabled: tilingEnabled,
            tileWidthMM: tileWidthMM,
            tileHeightMM: tileHeightMM,
            tileOverlapMM: tileOverlapMM,
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
        rasterMode = edit.rasterMode
        physicalWidthMM = edit.physicalWidthMM
        physicalHeightMM = edit.physicalHeightMM
        showsPrintMarks = edit.showsPrintMarks
        printMarksInsetMM = edit.printMarksInsetMM
        printBleedMM = edit.printBleedMM
        tilingEnabled = edit.tilingEnabled
        tileWidthMM = edit.tileWidthMM
        tileHeightMM = edit.tileHeightMM
        tileOverlapMM = edit.tileOverlapMM
        for layerEdit in edit.layers {
            guard let index = layers.firstIndex(where: { $0.id == layerEdit.id }) else { continue }
            layers[index].assignedCondition = layerEdit.assignedCondition
            layers[index].inverted = layerEdit.inverted
            layers[index].scalingMode = layerEdit.scalingMode
            layers[index].colorSpace = layerEdit.colorSpace
        }
        handleUpstreamChange()
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

    private func layerState(at index: Int) -> LayerState {
        let layer = layers[index]
        return LayerState(
            imageData: layer.imageData,
            filename: layer.filename,
            assignedCondition: layer.assignedCondition,
            inverted: layer.inverted,
            scalingMode: layer.scalingMode,
            colorSpace: layer.colorSpace
        )
    }

    private func registerLayerRestoreUndo(actionName: String, index: Int, restore: LayerState) {
        guard let undoManager = undoController.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreLayer(at: index, to: restore, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreLayer(at index: Int, to state: LayerState, actionName: String) {
        guard index >= 0 && index < layers.count else { return }
        let inverse = layerState(at: index)
        registerLayerRestoreUndo(actionName: actionName, index: index, restore: inverse)
        undoController.performWithoutRegistration {
            let layer = layers[index]
            layer.imageData = state.imageData
            layer.filename = state.filename
            layer.assignedCondition = state.assignedCondition
            layer.inverted = state.inverted
            layer.scalingMode = state.scalingMode
            layer.colorSpace = state.colorSpace
        }
        handleUpstreamChange()
    }

    private func menuTitle(prefix: String, actionName: String?) -> String {
        guard let actionName, !actionName.isEmpty else { return prefix }
        return "\(prefix) \(actionName)"
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
    private var catalogConfigDebounceTask: Task<Void, Never>?
    private var pendingAutoRegenerate = false
    private var solveQueued = false
    private var solveGeneration = 0
    private var isRestoringProject = false

    /// Cancels any in-flight solve and starts a new one. Both the manual
    /// Generate action and the debounced auto-regenerate pipeline go through
    /// here so the prior task is always canceled *before* the new task is
    /// launched — and so `solveTask` never points to the task currently
    /// executing `generate()` (which would cancel itself).
    func runSolve() {
        debounceTask?.cancel()
        debounceTask = nil
        solveTask?.cancel()
        pendingAutoRegenerate = false
        solveQueued = true
        solveGeneration += 1
        let generation = solveGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.generate()
            guard self.solveGeneration == generation else { return }
            self.solveTask = nil
        }
        solveTask = task
    }

    /// Stops any pending debounce or in-flight solve before the project's state
    /// is replaced, so stale work cannot write results into the next document.
    func cancelPendingWork() {
        catalog.cancelPendingWork()
        catalogConfigDebounceTask?.cancel()
        catalogConfigDebounceTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        solveTask?.cancel()
        solveTask = nil
        isSolving = false
        pendingAutoRegenerate = false
        solveQueued = false
        solveGeneration += 1
    }

    // MARK: - Result

    private(set) var result: CompositionResult?
    private(set) var errorStatistics: ErrorStatistics?
    private(set) var isSolving = false
    private(set) var lastError: String?
    private(set) var documentStateID = UUID()
    private var solvedGamut: ResponseGamut?

    var hasResult: Bool { result != nil }
    var canGenerate: Bool {
        let active = weights.activeConditions
        return catalog.hasLoadedColorsForSelection &&
            !catalog.colors.isEmpty &&
            !active.isEmpty &&
            active.allSatisfy(hasAssignedSource)
    }
    var canExportComposite: Bool { hasResult }
    var canExportTiles: Bool { tilingEnabled && hasResult }

    /// Discards the solved composition when upstream inputs such as the active
    /// palette change, so export/print cannot operate on stale output.
    func invalidateGeneratedOutput() {
        debounceTask?.cancel()
        debounceTask = nil
        solveTask?.cancel()
        solveTask = nil
        isSolving = false
        pendingAutoRegenerate = false
        clearGeneratedOutput()
        solveQueued = false
        solveGeneration += 1
    }

    /// Handles edits to any solver input. Existing output is invalidated
    /// immediately; when auto-regenerate is enabled, a fresh solve is queued.
    /// Keep the pipeline alive across repeated edits while a debounced or
    /// in-flight solve is already pending, or while an async palette refresh is
    /// still in flight, otherwise a later edit could cancel that work and leave
    /// the document with no replacement result.
    func handleUpstreamChange() {
        guard !isRestoringProject else { return }
        let shouldAutoRegenerate = autoRegenerate &&
            (hasResult || isSolving || debounceTask != nil || solveQueued || pendingAutoRegenerate)
        invalidateGeneratedOutput()
        guard shouldAutoRegenerate else { return }
        guard canGenerate else {
            pendingAutoRegenerate = true
            return
        }
        pendingAutoRegenerate = false
        scheduleDebouncedSolve()
    }

    /// `serverBaseURL`/`serverToken` are bound directly to a `TextField`/
    /// `SecureField`, which write back on every keystroke. Debounce the
    /// invalidation so a multi-character edit doesn't cancel an in-flight
    /// solve and blank the preview once per typed character; `catalog.configure`
    /// is still called synchronously on each edit and guards stale fetches
    /// itself via `configurationRevision`.
    private func scheduleCatalogConfigurationChange() {
        guard !isRestoringProject else { return }
        catalogConfigDebounceTask?.cancel()
        catalogConfigDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch { return }
            self?.handleCatalogConfigurationChange()
        }
    }

    /// Server settings changes invalidate the generated composition immediately
    /// (the loaded palette survives until the next fetch/refresh replaces it),
    /// but if a solve was previously visible we still want the next successful
    /// refresh to restore it automatically when auto-regenerate is enabled.
    private func handleCatalogConfigurationChange() {
        catalogConfigDebounceTask = nil
        let shouldAutoRegenerate = autoRegenerate &&
            (hasResult || isSolving || debounceTask != nil || solveQueued || pendingAutoRegenerate)
        invalidateGeneratedOutput()
        pendingAutoRegenerate = shouldAutoRegenerate
    }

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
        solveQueued = false

        let active = weights.activeConditions
        guard !active.isEmpty else {
            clearGeneratedOutput()
            lastError = "Set at least one channel weight above zero."
            return
        }
        guard catalog.hasLoadedColorsForSelection else {
            clearGeneratedOutput()
            lastError = "Load colors from the server, cache, or a project first."
            return
        }
        guard !catalog.colors.isEmpty else {
            clearGeneratedOutput()
            lastError = "The selected profile has no colors to generate with."
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
            invalidatePreviewCaches()
        case .failure(let error):
            clearGeneratedOutput()
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

    /// Captures the current layer settings and cached images on the main actor
    /// so resampling can run off-actor in `solveComposition` without re-decoding.
    private func sourceLayerSnapshots() -> [SourceLayerSnapshot] {
        layers.map {
            SourceLayerSnapshot(
                assignedCondition: $0.assignedCondition,
                cgImage: $0.cgImage.map(SendableCGImage.init),
                scalingMode: $0.scalingMode,
                inverted: $0.inverted,
                colorSpace: $0.colorSpace
            )
        }
    }

    /// One brightness grid per active condition, or throws when an active
    /// channel has no assigned source image or its cached image is unavailable.
    private nonisolated static func sourceGrids(
        for active: [LightingCondition],
        from layers: [SourceLayerSnapshot],
        logicalWidth: Int,
        logicalHeight: Int
    ) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in active {
            guard let layer = layers.first(where: { $0.cgImage != nil && $0.assignedCondition == condition }) else {
                throw SourceGridBuildError.missingSourceImage(condition)
            }
            guard let grid = brightnessGrid(for: layer, logicalWidth: logicalWidth, logicalHeight: logicalHeight) else {
                throw layer.cgImage == nil
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
        guard let cgImage = layer.cgImage?.image else { return nil }
        return BrightnessGridSampler.sample(
            cgImage: cgImage,
            targetWidth: logicalWidth,
            targetHeight: logicalHeight,
            scalingMode: layer.scalingMode,
            invert: layer.inverted,
            colorSpace: layer.colorSpace
        )
    }

    private func hasAssignedSource(for condition: LightingCondition) -> Bool {
        layers.contains { $0.hasImage && $0.assignedCondition == condition }
    }

    private func scheduleDebouncedSolve() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch { return }
            runSolve()
        }
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
        pendingAutoRegenerate = false
        solveQueued = false
        solveGeneration += 1
        invalidatePreviewCaches()
    }

    // MARK: - Derived images

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
    /// export-sized rasters on the main actor. Export/print (`exportRaster`)
    /// render the same raster mode without the magenta marker: unmatched
    /// cells come out opaque paper-white in halftone mode, or as a
    /// transparent hole in flat and two-color modes.
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
    /// can hit. Unlike `compositePreviewRGBA`, this has no magenta
    /// unmatched-cell marker: halftone renders unmatched cells as opaque
    /// paper-white, while flat and two-color leave them fully transparent.
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
    var tilingEnabled = false {
        didSet {
            guard oldValue != tilingEnabled else { return }
            noteEdit(kind: "tilingEnabled", actionName: "Tiling") { $0.tilingEnabled = oldValue }
        }
    }
    var tileWidthMM = 200.0 {
        didSet {
            guard oldValue != tileWidthMM else { return }
            noteEdit(kind: "tileSize", actionName: "Tile Size") { $0.tileWidthMM = oldValue }
        }
    }
    var tileHeightMM = 200.0 {
        didSet {
            guard oldValue != tileHeightMM else { return }
            noteEdit(kind: "tileSize", actionName: "Tile Size") { $0.tileHeightMM = oldValue }
        }
    }
    var tileOverlapMM = 10.0 {
        didSet {
            guard oldValue != tileOverlapMM else { return }
            noteEdit(kind: "tileOverlap", actionName: "Tile Overlap") { $0.tileOverlapMM = oldValue }
        }
    }

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
        // Keep the current document running unless the replacement snapshot is
        // structurally valid; a failed open should not cancel its pending work.
        cancelPendingWork()
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
        // Loading a project replaces state wholesale: it is not a user edit,
        // and stale pre-load undo actions would restore a half-replaced model.
        isRestoringProject = true
        defer { isRestoringProject = false }
        undoController.performWithoutRegistration { applySnapshotContents(s) }
        wireUndoHooks()
        undoController.reset()
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
        documentStateID = UUID()
    }

    private func clearGeneratedOutput() {
        result = nil
        errorStatistics = nil
        lastError = nil
        solvedGamut = nil
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
