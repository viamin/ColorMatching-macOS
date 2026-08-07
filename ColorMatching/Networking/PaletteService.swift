import Foundation
import ColorComposerCore

/// Coordinates fetching palette data from the `color_matching` server and holds
/// the decoded results. UI observes this via `@Observable`.
@Observable
final class PaletteService {
    var printerProfiles: [PrinterProfileDTO] = []
    var palettes: [PaletteSummaryDTO] = []
    var colors: [PaletteColor] = []          // domain models
    var colorsForProfile: PrinterProfileDTO?

    var selectedPrinterProfileID: Int? {
        didSet { Task { await fetchColorsIfPossible() } }
    }
    var selectedPaletteID: Int?

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
            async let profiles = client.fetchPrinterProfiles()
            async let pals = client.fetchPalettes()
            let (fetchedProfiles, fetchedPalettes) = try await (profiles, pals)
            printerProfiles = fetchedProfiles
            palettes = fetchedPalettes
            if selectedPrinterProfileID == nil { selectedPrinterProfileID = fetchedProfiles.first?.id }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s) and \(fetchedPalettes.count) palette(s)."
            await fetchColorsIfPossible()
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
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID, paletteID: selectedPaletteID)
            colors = dtos.compactMap { $0.toDomain() }
            colorsForProfile = profile
            lastRefresh = Date()
            connectionMessage = "Loaded \(colors.count) color(s)."
        } catch let error as PaletteAPIError {
            connectionMessage = error.errorDescription
        } catch {
            connectionMessage = "Could not load colors."
        }
    }

    /// Palette colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
