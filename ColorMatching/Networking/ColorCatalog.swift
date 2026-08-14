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
///
/// Every successful fetch is written to a profile-keyed disk cache. When the
/// server is unreachable the cached fetch is served instead and
/// `isServingFromCache` is set, so the UI can badge the colors as stale.
@Observable
final class ColorCatalog {
    var printerProfiles: [PrinterProfileDTO] = []
    var colors: [PaletteColor] = []
    var colorsForProfile: PrinterProfileDTO?

    var selectedPrinterProfileID: Int? {
        didSet { Task { await fetchColorsIfPossible() } }
    }

    var lastRefresh: Date?
    var connectionMessage: String?
    var isWorking = false
    /// True when `colors` were served from the offline cache rather than a
    /// live fetch — the UI shows a staleness badge while this is set.
    var isServingFromCache = false

    private var client: PaletteAPIClient?
    private let cache: ProfileColorCache

    init(cache: ProfileColorCache = ProfileColorCache()) {
        self.cache = cache
    }

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
            let fetchedProfiles = try await client.fetchPrinterProfiles()
            printerProfiles = fetchedProfiles
            if selectedPrinterProfileID == nil { selectedPrinterProfileID = fetchedProfiles.first?.id }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            await fetchColorsIfPossible()
        } catch {
            serveCachedProfilesIfUnavailable()
            handleFetchFailure(error, missMessage: "Could not reach the server.")
        }
    }

    /// Drops every cached color fetch. Colors currently on screen from the
    /// cache are cleared too; a live session is unaffected.
    func clearCache() {
        do {
            try cache.removeAll()
            if isServingFromCache {
                colors = []
                colorsForProfile = nil
                lastRefresh = nil
                isServingFromCache = false
            }
            connectionMessage = "Cleared cached colors."
        } catch {
            connectionMessage = "Could not clear the color cache."
        }
    }

    // MARK: - Color loading

    private func fetchColorsIfPossible() async {
        guard let client, let profileID = selectedPrinterProfileID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID)
            applyFetched(dtos: dtos, profile: profile, profileID: profileID)
        } catch {
            handleFetchFailure(error, missMessage: "Could not load colors.")
        }
    }

    private func applyFetched(dtos: [PaletteColorDTO], profile: PrinterProfileDTO?, profileID: Int) {
        let fetchedAt = Date()
        colors = dtos.compactMap { $0.toDomain() }
        colorsForProfile = profile
        lastRefresh = fetchedAt
        isServingFromCache = false
        connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        // Best effort: a failed write only costs the *next* offline fallback,
        // never the live session, so the error is deliberately not surfaced.
        try? cache.store(CachedProfileColors(
            profileID: profileID,
            profile: profile,
            colors: dtos,
            fetchedAt: fetchedAt
        ))
    }

    /// Serves the cached fetch for the selected profile, or reports `error`
    /// when no usable cache entry exists.
    private func handleFetchFailure(_ error: Error, missMessage: String) {
        let reason = (error as? PaletteAPIError)?.errorDescription ?? missMessage
        guard let profileID = selectedPrinterProfileID,
              let cached = cache.entry(for: profileID) else {
            isServingFromCache = false
            connectionMessage = reason
            return
        }
        colors = cached.colors.compactMap { $0.toDomain() }
        colorsForProfile = cached.profile
        lastRefresh = cached.fetchedAt
        isServingFromCache = true
        connectionMessage = "\(reason) — showing cached colors from \(Self.cacheTimestamp(cached.fetchedAt))."
    }

    /// Offline cold start: offer cached profiles in the picker so a profile
    /// can be selected (and its colors then served from the cache) with no
    /// server round-trip at all.
    private func serveCachedProfilesIfUnavailable() {
        guard printerProfiles.isEmpty else { return }
        let cachedProfiles = cache.allEntries().compactMap(\.profile)
        guard !cachedProfiles.isEmpty else { return }
        printerProfiles = cachedProfiles
        if selectedPrinterProfileID == nil {
            selectedPrinterProfileID = cachedProfiles.first?.id
        }
    }

    private static func cacheTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
