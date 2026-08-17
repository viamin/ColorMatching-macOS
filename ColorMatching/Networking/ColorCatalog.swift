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
    var reauthenticate: (@MainActor @Sendable () async -> String?)?
    private var isRestoringSnapshot = false

    var selectedPrinterProfileID: Int? {
        didSet {
            guard selectedPrinterProfileID != oldValue else { return }
            guard !isRestoringSnapshot else { return }
            clearLoadedColors()
            guard selectedPrinterProfileID != nil else {
                return
            }
            Task { await fetchColorsIfPossible() }
        }
    }

    var lastRefresh: Date?
    var connectionMessage: String?
    var isWorking = false

    private var client: PaletteAPIClient?

    func configure(baseURL: URL?, token: String?) {
        let normalizedToken = token?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .flatMap { $0.isEmpty ? nil : $0 }
        let baseURLChanged = client?.baseURL != baseURL
        let tokenChanged = client?.token != normalizedToken

        guard baseURLChanged || tokenChanged else { return }

        client = baseURL.map { PaletteAPIClient(baseURL: $0, token: normalizedToken) }

        guard baseURLChanged else {
            connectionMessage = nil
            return
        }

        printerProfiles = []

        if selectedPrinterProfileID != nil {
            selectedPrinterProfileID = nil
        } else {
            clearLoadedColors()
        }
    }

    var isConfigured: Bool { client != nil }

    // MARK: - Actions

    func testConnection() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.testConnection(retryingWith: authRetryHandler())
            connectionMessage = "Connected."
        } catch let error as PaletteAPIError {
            connectionMessage = error.errorDescription
        } catch {
            connectionMessage = "Could not reach the server."
        }
    }

    func refreshAll() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let previousSelection = selectedPrinterProfileID
            let fetchedProfiles = try await client.fetchPrinterProfiles(retryingWith: authRetryHandler())
            printerProfiles = fetchedProfiles
            if let selectedProfileID = selectedPrinterProfileID,
               fetchedProfiles.contains(where: { $0.id == selectedProfileID }) == false {
                selectedPrinterProfileID = fetchedProfiles.first?.id
            } else if selectedPrinterProfileID == nil {
                selectedPrinterProfileID = fetchedProfiles.first?.id
            }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            if selectedPrinterProfileID == previousSelection {
                await fetchColorsIfPossible()
            }
        } catch let error as PaletteAPIError {
            connectionMessage = error.errorDescription
        } catch {
            connectionMessage = "Could not reach the server."
        }
    }

    private func fetchColorsIfPossible() async {
        guard let client, let profileID = selectedPrinterProfileID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (dtos, profile) = try await client.fetchColors(
                printerProfileID: profileID,
                retryingWith: authRetryHandler()
            )
            guard selectedPrinterProfileID == profileID else { return }
            let loadedColors = dtos.compactMap { $0.toDomain() }
            applyPalette(
                loadedColors,
                profile: profile,
                connectionMessage: "Loaded \(loadedColors.count) color(s) for this profile."
            )
        } catch let error as PaletteAPIError {
            guard selectedPrinterProfileID == profileID else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard selectedPrinterProfileID == profileID else { return }
            connectionMessage = "Could not load colors."
        }
    }

    func restoreSnapshot(
        printerProfileID: Int?,
        printerProfile: PrinterProfileDTO?,
        colors: [PaletteColor]
    ) {
        isRestoringSnapshot = true
        selectedPrinterProfileID = printerProfileID
        isRestoringSnapshot = false
        printerProfiles = printerProfile.map { [$0] } ?? []
        applyPalette(
            colors,
            profile: printerProfile,
            connectionMessage: "Loaded \(colors.count) color(s) from project."
        )
    }

    private func clearLoadedColors() {
        onPaletteChanged?()
        colors = []
        colorsForProfile = nil
        lastRefresh = nil
        connectionMessage = nil
    }

    private func applyPalette(
        _ colors: [PaletteColor],
        profile: PrinterProfileDTO?,
        connectionMessage: String
    ) {
        onPaletteChanged?()
        self.colors = colors
        colorsForProfile = profile
        lastRefresh = Date()
        self.connectionMessage = connectionMessage
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }

    private func authRetryHandler() -> PaletteAPIReauthentication? {
        guard let reauthenticate else { return nil }
        return { await reauthenticate() }
    }
}
