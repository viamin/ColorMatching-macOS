import Foundation
import AppKit
import ColorComposerCore

/// The root application state: server/profile & color sync, source layers, composition
/// settings, and the solved result with derived preview images.
@Observable
final class AppModel {

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
    var logicalWidth = 200
    var logicalHeight = 200
    var pixelsPerCell = 4
    var physicalWidthMM = 200.0
    var physicalHeightMM = 200.0

    var presetSizes: [(label: String, size: Int)] {
        [("100 × 100", 100), ("200 × 200", 200), ("500 × 500", 500)]
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
        let active = weights.activeConditions
        guard !active.isEmpty else {
            lastError = "Set at least one channel weight above zero."
            return
        }
        guard !catalog.colors.isEmpty else {
            lastError = "Load colors from the server first."
            return
        }
        guard let grids = sourceGrids(for: active) else { return }

        let candidateColors = catalog.colors
        let weights = self.weights
        let solver = CompositionSolver()
        isSolving = true
        lastError = nil

        let solved: Result<CompositionResult, Error>
        do {
            let r = try solver.solve(palette: candidateColors, sourceGrids: grids, weights: weights)
            solved = .success(r)
        } catch {
            solved = .failure(error)
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

    // MARK: - Derived images

    var compositeRGBA: RGBAImage? {
        guard let result else { return nil }
        return CompositionRenderer.composite(result)
    }

    /// On-screen composite that visibly marks unmatched cells (magenta) so a
    /// no-data or partial-match result is never invisible. Export/print keep
    /// using `compositeRGBA` (transparent for unmatched).
    var compositePreviewRGBA: RGBAImage? {
        guard let result else { return nil }
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            let base = cell * 4
            if let index = result.colorIndices[cell] {
                let color = result.palette[index].rgb
                rgba[base] = color.red; rgba[base + 1] = color.green
                rgba[base + 2] = color.blue; rgba[base + 3] = 255
            } else {
                // Visible "no eligible color" marker.
                rgba[base] = 255; rgba[base + 1] = 0; rgba[base + 2] = 255; rgba[base + 3] = 255
            }
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
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

    // MARK: - Export / print

    func exportComposite(to url: URL) throws {
        guard let raster = exportRaster,
              let cgImage = ImageUtilities.makeCGImage(from: raster) else {
            throw ImageWriteError.writeFailed
        }
        try ImageUtilities.write(cgImage, to: url)
    }

    func printComposite() {
        guard let raster = exportRaster,
              let image = ImageUtilities.nsImage(from: raster) else { return }
        PrintSupport.print(image, physicalSizeMM: CGSize(width: physicalWidthMM, height: physicalHeightMM))
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
                scalingMode: layer.scalingMode
            )
        }
        return ProjectDocument(
            serverBaseURL: serverBaseURL,
            apiToken: serverToken,
            printerProfileID: catalog.selectedPrinterProfileID,
            colorSnapshot: catalog.colors.map { ColorSnapshot($0) },
            weights: weights,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelsPerCell: pixelsPerCell,
            physicalWidthMM: physicalWidthMM,
            physicalHeightMM: physicalHeightMM,
            layers: layerSnaps
        )
    }

    private func applySnapshot(_ s: ProjectDocument) {
        serverBaseURL = s.serverBaseURL
        serverToken = s.apiToken
        catalog.selectedPrinterProfileID = s.printerProfileID
        catalog.colors = s.colorSnapshot.map { $0.toColor() }
        catalog.lastRefresh = Date()
        catalog.connectionMessage = "Loaded \(s.colorSnapshot.count) color(s) from project."

        weights = s.weights
        logicalWidth = s.logicalWidth
        logicalHeight = s.logicalHeight
        pixelsPerCell = s.pixelsPerCell
        physicalWidthMM = s.physicalWidthMM
        physicalHeightMM = s.physicalHeightMM

        let restored = s.layers.enumerated().map { (index, snap) -> SourceLayer in
            let layer = index < layers.count ? layers[index] : SourceLayer()
            layer.imageData = snap.imageData
            layer.filename = snap.filename
            layer.assignedCondition = snap.assignedCondition
            layer.inverted = snap.inverted
            layer.scalingMode = snap.scalingMode
            return layer
        }
        while layers.count < Self.maxLayers { layers.append(SourceLayer()) }
        for i in 0..<Self.maxLayers {
            layers[i] = i < restored.count ? restored[i] : SourceLayer()
        }
    }
}
