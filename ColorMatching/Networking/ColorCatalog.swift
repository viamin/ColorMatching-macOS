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

    var selectedPrinterProfileID: Int? {
        didSet {
            guard selectedPrinterProfileID != oldValue else { return }
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
        guard let baseURL else {
            client = nil
            return
        }
        client = PaletteAPIClient(baseURL: baseURL, token: token?.isEmpty == false ? token : nil)
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
            try await client.testConnection()
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
            let fetchedProfiles = try await client.fetchPrinterProfiles()
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
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID)
            guard selectedPrinterProfileID == profileID else { return }
            onPaletteChanged?()
            colors = dtos.compactMap { $0.toDomain() }
            colorsForProfile = profile
            lastRefresh = Date()
            connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        } catch let error as PaletteAPIError {
            guard selectedPrinterProfileID == profileID else { return }
            connectionMessage = error.errorDescription
        } catch {
            guard selectedPrinterProfileID == profileID else { return }
            connectionMessage = "Could not load colors."
        }
    }

    private func clearLoadedColors() {
        onPaletteChanged?()
        colors = []
        colorsForProfile = nil
        lastRefresh = nil
        connectionMessage = nil
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
