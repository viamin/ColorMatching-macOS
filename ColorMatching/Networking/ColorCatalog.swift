import Foundation
import ColorComposerCore

/// Fetches printer profiles and their measured printable colors from the
/// `color_matching` server.
///
/// Colors are **profile-scoped**. The palette grouping that `color_matching`
/// uses to discover LPS metamer pairs is a search construct, not a composition
/// input — so this catalog exposes colors per profile only. Once a profile is
/// selected it fetches every measured color for that profile; colors with no
/// measurement for the profile come back response-less and are excluded by the
/// solver.
@Observable
final class ColorCatalog {
    var printerProfiles: [PrinterProfileDTO] = []
    var colors: [PaletteColor] = []
    var colorsForProfile: PrinterProfileDTO?
    private(set) var loadedPrinterProfileID: Int?
    private var colorFetchTask: Task<Void, Never>?
    private var operationVersion = 0

    var selectedPrinterProfileID: Int? {
        didSet {
            guard fetchesColorsOnProfileSelection else { return }
            cancelPendingWork()
            loadedPrinterProfileID = nil
            colors = []
            colorsForProfile = nil
            let version = operationVersion
            colorFetchTask = Task { [weak self] in
                await self?.fetchColorsIfPossible(version: version)
            }
        }
    }

    var lastRefresh: Date?
    var connectionMessage: String?
    var isWorking = false

    private var client: PaletteAPIClient?
    private var fetchesColorsOnProfileSelection = true

    deinit {
        cancelPendingWork()
    }

    func configure(baseURL: URL?, token: String?) {
        invalidateLoadedData()
        guard let baseURL else {
            client = nil
            return
        }
        client = PaletteAPIClient(baseURL: baseURL, token: token?.isEmpty == false ? token : nil)
    }

    var isConfigured: Bool { client != nil }
    /// A selection counts as loaded once the fetch (or project restore) for the
    /// currently selected profile has completed, even if that profile contains
    /// zero measured colors. An empty palette is still a real loaded result.
    var hasLoadedColorsForSelection: Bool {
        guard let selectedPrinterProfileID else { return false }
        return loadedPrinterProfileID == selectedPrinterProfileID
    }

    // MARK: - Actions

    /// Prevents stale palette loads from mutating the current selection or a
    /// just-opened project after the user has moved on.
    func cancelPendingWork() {
        operationVersion += 1
        colorFetchTask?.cancel()
        colorFetchTask = nil
        isWorking = false
    }

    func testConnection() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        cancelPendingWork()
        let version = operationVersion
        isWorking = true
        defer {
            guard isCurrent(version) else { return }
            isWorking = false
        }
        do {
            try await client.testConnection()
            guard isCurrent(version) else { return }
            connectionMessage = "Connected."
        } catch let error as PaletteAPIError {
            guard isCurrent(version) else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard isCurrent(version) else { return }
            connectionMessage = "Could not reach the server."
        }
    }

    func refreshAll() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        // Treat an explicit refresh as the new source of truth. Without this,
        // an older profile-triggered color fetch can finish during the refresh
        // and still look "current", racing the refreshed palette into the UI.
        cancelPendingWork()
        let version = operationVersion
        isWorking = true
        defer {
            guard isCurrent(version) else { return }
            isWorking = false
        }
        do {
            let fetchedProfiles = try await client.fetchPrinterProfiles()
            guard isCurrent(version) else { return }
            printerProfiles = fetchedProfiles
            if needsProfileSelection(from: fetchedProfiles) {
                setSelectedPrinterProfileID(fetchedProfiles.first?.id, fetchColors: false)
            }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            await fetchColorsIfPossible(version: version)
        } catch let error as PaletteAPIError {
            guard isCurrent(version) else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard isCurrent(version) else { return }
            connectionMessage = "Could not reach the server."
        }
    }

    /// Restores the saved palette and selected profile from a project document
    /// without immediately replacing the embedded colors from the server.
    func restoreProjectPalette(printerProfileID: Int?, colors: [PaletteColor]) {
        cancelPendingWork()
        setSelectedPrinterProfileID(printerProfileID, fetchColors: false)
        self.colors = colors
        loadedPrinterProfileID = printerProfileID
        colorsForProfile = printerProfiles.first { $0.id == printerProfileID }
        lastRefresh = Date()
        connectionMessage = "Loaded \(colors.count) color(s) from project."
    }

    private func setSelectedPrinterProfileID(_ id: Int?, fetchColors: Bool) {
        let previousBehavior = fetchesColorsOnProfileSelection
        fetchesColorsOnProfileSelection = fetchColors
        selectedPrinterProfileID = id
        fetchesColorsOnProfileSelection = previousBehavior
    }

    private func needsProfileSelection(from profiles: [PrinterProfileDTO]) -> Bool {
        guard let selectedPrinterProfileID else { return true }
        return !profiles.contains { $0.id == selectedPrinterProfileID }
    }

    private func isCurrent(_ version: Int) -> Bool {
        !Task.isCancelled && operationVersion == version
    }

    private func fetchColorsIfPossible(version: Int) async {
        guard let client, let profileID = selectedPrinterProfileID else { return }
        isWorking = true
        let shouldClearStaleColors = loadedPrinterProfileID != profileID
        loadedPrinterProfileID = nil
        colorsForProfile = nil
        if shouldClearStaleColors {
            colors = []
        }
        defer {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            isWorking = false
        }
        do {
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID)
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            colors = dtos.compactMap { $0.toDomain() }
            loadedPrinterProfileID = profileID
            colorsForProfile = profile
            lastRefresh = Date()
            connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        } catch let error as PaletteAPIError {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            connectionMessage = "Could not load colors."
        }
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }

    private func invalidateLoadedData() {
        cancelPendingWork()
        printerProfiles = []
        setSelectedPrinterProfileID(nil, fetchColors: false)
        colors = []
        colorsForProfile = nil
        loadedPrinterProfileID = nil
        lastRefresh = nil
        connectionMessage = nil
    }
}
