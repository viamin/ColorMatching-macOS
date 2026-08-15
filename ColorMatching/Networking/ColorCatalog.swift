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
    /// Profile id the on-screen `colors` belong to (`nil` when none). A failed
    /// fetch keeps them only when they match the selected profile — colors
    /// loaded from a project or an earlier fetch survive, another profile's
    /// leftovers are cleared as stale.
    var loadedColorsProfileID: Int?

    private var client: PaletteAPIClient?
    private let cache: ProfileColorCache
    /// True when `printerProfiles` were offered from the offline cache because
    /// the server could not be reached at all.
    private var printerProfilesAreCached = false

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
            printerProfilesAreCached = false
            if selectedPrinterProfileID == nil { selectedPrinterProfileID = fetchedProfiles.first?.id }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            await fetchColorsIfPossible()
        } catch {
            serveCachedProfilesIfUnavailable()
            handleFetchFailure(error, missMessage: "Could not reach the server.")
        }
    }

    /// Drops every cached color fetch. Cache-backed state on screen — colors
    /// served from the cache, profiles offered from it — is cleared too;
    /// live-fetched and project-loaded colors are unaffected.
    func clearCache() {
        do {
            try cache.removeAll()
            if printerProfilesAreCached {
                printerProfiles = []
                printerProfilesAreCached = false
                selectedPrinterProfileID = nil
            }
            if isServingFromCache {
                clearLoadedColors()
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
            // The selection may have changed while the request was in flight;
            // a late response for another profile must not overwrite it.
            guard selectedPrinterProfileID == profileID else { return }
            applyFetched(dtos: dtos, profile: profile, profileID: profileID)
        } catch {
            guard selectedPrinterProfileID == profileID else { return }
            handleFetchFailure(error, missMessage: "Could not load colors.")
        }
    }

    private func applyFetched(dtos: [PaletteColorDTO], profile: PrinterProfileDTO?, profileID: Int) {
        let fetchedAt = Date()
        colors = dtos.compactMap { $0.toDomain() }
        colorsForProfile = profile
        lastRefresh = fetchedAt
        loadedColorsProfileID = profileID
        isServingFromCache = false
        connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        // Best effort: a failed write only costs the *next* offline fallback,
        // never the live session, so the error is deliberately not surfaced.
        try? cache.store(CachedProfileColors(
            profileId: profileID,
            profile: profile,
            colors: dtos,
            fetchedAt: fetchedAt
        ))
    }

    /// Serves the cached fetch for the selected profile when one exists; on a
    /// cache miss, keeps colors already loaded for that profile and clears
    /// any other profile's leftovers, reporting `error` either way.
    private func handleFetchFailure(_ error: Error, missMessage: String) {
        let reason = (error as? PaletteAPIError)?.errorDescription ?? missMessage
        guard let profileID = selectedPrinterProfileID else {
            connectionMessage = reason
            return
        }
        if let cached = cache.entry(for: profileID) {
            serve(cached, profileID: profileID, reason: reason)
        } else {
            keepOrClearLoadedColors(profileID: profileID, reason: reason)
        }
    }

    private func serve(_ cached: CachedProfileColors, profileID: Int, reason: String) {
        colors = cached.colors.compactMap { $0.toDomain() }
        colorsForProfile = cached.profile
        lastRefresh = cached.fetchedAt
        loadedColorsProfileID = profileID
        isServingFromCache = true
        connectionMessage = "\(reason) — showing cached colors from \(Self.cacheTimestamp(cached.fetchedAt))."
    }

    /// Keeps colors already on screen only when they belong to the selected
    /// profile; another profile's leftovers are cleared as stale. The cache
    /// badge is left untouched — kept colors keep their true provenance.
    private func keepOrClearLoadedColors(profileID: Int, reason: String) {
        if loadedColorsProfileID == profileID {
            connectionMessage = "\(reason) — keeping loaded colors."
        } else {
            clearLoadedColors()
            connectionMessage = reason
        }
    }

    /// Offline cold start: offer cached profiles in the picker so a profile
    /// can be selected (and its colors then served from the cache) with no
    /// server round-trip at all.
    private func serveCachedProfilesIfUnavailable() {
        guard printerProfiles.isEmpty else { return }
        let cachedProfiles = cache.allEntries().compactMap(\.profile)
        guard !cachedProfiles.isEmpty else { return }
        printerProfiles = cachedProfiles
        printerProfilesAreCached = true
        if selectedPrinterProfileID == nil {
            selectedPrinterProfileID = cachedProfiles.first?.id
        }
    }

    private static func cacheTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    private func clearLoadedColors() {
        colors = []
        colorsForProfile = nil
        lastRefresh = nil
        loadedColorsProfileID = nil
        isServingFromCache = false
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
