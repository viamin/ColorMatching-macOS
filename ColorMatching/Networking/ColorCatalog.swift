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
    var onPaletteChanged: (() -> Void)?
    private(set) var loadedPrinterProfileID: Int?
    private var loadedProjectPaletteWithoutProfile = false
    private var colorFetchTask: Task<Void, Never>?
    private var operationVersion = 0
    private var isRestoringSnapshot = false

    var selectedPrinterProfileID: Int? {
        didSet {
            guard selectedPrinterProfileID != oldValue else { return }
            guard fetchesColorsOnProfileSelection, !isRestoringSnapshot else { return }
            cancelPendingWork()
            clearLoadedColors()
            connectionMessage = selectedPrinterProfileID == nil ? nil : "Loading colors..."
            let version = operationVersion
            colorFetchTask = Task { [weak self] in
                await self?.fetchColorsIfPossible(version: version)
            }
        }
    }

    var lastRefresh: Date?
    var connectionMessage: String?
    var isWorking = false

    /// Invoked when the server rejects the current token with 401. Should
    /// securely prompt for a replacement token and return it, or `nil` if the
    /// user cancels (issue #16).
    var onAuthenticationRequired: (() async -> String?)?

    /// Invoked with the token that succeeded a re-authenticated retry, so the
    /// owner can persist it (e.g. to `AppModel.serverToken`).
    var onTokenUpdated: ((String) -> Void)?

    private var client: PaletteAPIClient?
    private var fetchesColorsOnProfileSelection = true

    deinit {
        cancelPendingWork()
    }

    func configure(baseURL: URL?, token: String?) {
        let normalizedToken = token?.isEmpty == false ? token : nil
        let configurationChanged = client?.baseURL != baseURL || client?.token != normalizedToken

        guard configurationChanged else { return }

        cancelPendingWork()
        client = baseURL.map { PaletteAPIClient(baseURL: $0, token: normalizedToken) }
        printerProfiles = []
        clearLoadedColors()
    }

    var isConfigured: Bool { client != nil }

    /// A selection counts as loaded once the fetch (or project restore) for the
    /// currently selected profile has completed, even if that profile contains
    /// zero measured colors. A restored project palette with no current profile
    /// selection also counts as loaded, so Generate stays available for legacy
    /// or offline project snapshots that still embed color data.
    var hasLoadedColorsForSelection: Bool {
        guard let selectedPrinterProfileID else { return loadedProjectPaletteWithoutProfile }
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
        guard client != nil else {
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
            try await withReauth { try await $0.testConnection() }
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
        guard client != nil else {
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
            let fetchedProfiles = try await withReauth { try await $0.fetchPrinterProfiles() }
            guard isCurrent(version) else { return }
            printerProfiles = fetchedProfiles
            if needsProfileSelection(from: fetchedProfiles) {
                setSelectedPrinterProfileID(fetchedProfiles.first?.id, fetchColors: false)
            }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            if selectedPrinterProfileID == nil {
                clearLoadedColors()
            }
            await fetchColorsIfPossible(version: version)
        } catch let error as PaletteAPIError {
            guard isCurrent(version) else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard isCurrent(version) else { return }
            connectionMessage = "Could not reach the server."
        }
    }

    func restoreSnapshot(
        printerProfileID: Int?,
        printerProfile: PrinterProfileDTO?,
        colors: [PaletteColor]
    ) {
        cancelPendingWork()
        isRestoringSnapshot = true
        setSelectedPrinterProfileID(printerProfileID, fetchColors: false)
        isRestoringSnapshot = false
        printerProfiles = printerProfile.map { [$0] } ?? []
        applyPalette(
            colors,
            profile: printerProfile,
            connectionMessage: "Loaded \(colors.count) color(s) from project.",
            lastRefresh: nil,
            loadedPrinterProfileID: printerProfileID,
            loadedProjectPaletteWithoutProfile: printerProfileID == nil
        )
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
        let previousColorsForProfile = colorsForProfile
        let previousLoadedPrinterProfileID = loadedPrinterProfileID
        let previousLastRefresh = lastRefresh
        loadedPrinterProfileID = nil
        loadedProjectPaletteWithoutProfile = false
        colorsForProfile = nil
        if shouldClearStaleColors {
            colors = []
            lastRefresh = nil
        }
        defer {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            isWorking = false
        }
        do {
            let (dtos, profile) = try await withReauth { try await $0.fetchColors(printerProfileID: profileID) }
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            let loadedColors = dtos.compactMap { $0.toDomain() }
            applyPalette(
                loadedColors,
                profile: profile,
                connectionMessage: "Loaded \(loadedColors.count) color(s) for this profile.",
                lastRefresh: Date(),
                loadedPrinterProfileID: profileID,
                loadedProjectPaletteWithoutProfile: false
            )
        } catch let error as PaletteAPIError {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            restoreLoadedProfileIfNeeded(
                shouldClearStaleColors: shouldClearStaleColors,
                profileID: profileID,
                previousLoadedPrinterProfileID: previousLoadedPrinterProfileID,
                previousColorsForProfile: previousColorsForProfile,
                previousLastRefresh: previousLastRefresh
            )
            connectionMessage = error.errorDescription
        } catch {
            guard isCurrent(version), selectedPrinterProfileID == profileID else { return }
            restoreLoadedProfileIfNeeded(
                shouldClearStaleColors: shouldClearStaleColors,
                profileID: profileID,
                previousLoadedPrinterProfileID: previousLoadedPrinterProfileID,
                previousColorsForProfile: previousColorsForProfile,
                previousLastRefresh: previousLastRefresh
            )
            connectionMessage = "Could not load colors."
        }
    }

    /// Runs `operation` against the current client, retrying exactly once
    /// with a freshly prompted token if the server responds 401 (issue #16).
    /// Non-auth errors, and a second 401 after re-auth, propagate untouched.
    private func withReauth<T>(_ operation: (PaletteAPIClient) async throws -> T) async throws -> T {
        guard let client else { throw PaletteAPIError.invalidURL }
        do {
            return try await operation(client)
        } catch PaletteAPIError.unauthorized {
            guard let newToken = await onAuthenticationRequired?(), !newToken.isEmpty else {
                throw PaletteAPIError.unauthorized
            }
            let reauthedClient = PaletteAPIClient(baseURL: client.baseURL, token: newToken)
            let result = try await operation(reauthedClient)
            self.client = reauthedClient
            onTokenUpdated?(newToken)
            return result
        }
    }

    private func clearLoadedColors() {
        colors = []
        colorsForProfile = nil
        loadedPrinterProfileID = nil
        loadedProjectPaletteWithoutProfile = false
        lastRefresh = nil
        connectionMessage = nil
    }

    private func applyPalette(
        _ colors: [PaletteColor],
        profile: PrinterProfileDTO?,
        connectionMessage: String,
        lastRefresh: Date?,
        loadedPrinterProfileID: Int?,
        loadedProjectPaletteWithoutProfile: Bool
    ) {
        self.colors = colors
        colorsForProfile = profile
        self.lastRefresh = lastRefresh
        self.loadedPrinterProfileID = loadedPrinterProfileID
        self.loadedProjectPaletteWithoutProfile = loadedProjectPaletteWithoutProfile
        self.connectionMessage = connectionMessage
        onPaletteChanged?()
    }

    private func restoreLoadedProfileIfNeeded(
        shouldClearStaleColors: Bool,
        profileID: Int,
        previousLoadedPrinterProfileID: Int?,
        previousColorsForProfile: PrinterProfileDTO?,
        previousLastRefresh: Date?
    ) {
        guard !shouldClearStaleColors, previousLoadedPrinterProfileID == profileID else { return }
        loadedPrinterProfileID = profileID
        colorsForProfile = previousColorsForProfile
        lastRefresh = previousLastRefresh
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
