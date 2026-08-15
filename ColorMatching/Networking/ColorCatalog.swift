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
/// Every successful fetch is written to a disk cache keyed by server and
/// profile. When the server is unreachable the cached fetch is served instead
/// and `isServingFromCache` is set, so the UI can badge the colors as stale.
///
/// Deliberately over the ~100-line class guideline: the fetch, cache, and
/// failure-policy paths all mutate this one set of observable state, so
/// splitting them would pass that state between collaborators without
/// reducing any complexity.
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
    /// True when `colors` are the loaded project's embedded palette snapshot
    /// (set by the app model when a `.cmpj` is opened). A failed fetch keeps
    /// them even when a cache entry exists: a saved document's palette is the
    /// data the user chose, not a stale fetch to fall back from.
    var colorsLoadedFromProject = false

    private var client: PaletteAPIClient?
    private let cache: ProfileColorCache
    /// True when `printerProfiles` were offered from the offline cache because
    /// the server could not be reached at all.
    private var printerProfilesAreCached = false

    init(cache: ProfileColorCache = ProfileColorCache()) {
        self.cache = cache
    }

    func configure(baseURL: URL?, token: String?) {
        let serverChanged = baseURL?.absoluteString != client?.baseURL.absoluteString
        client = baseURL.map { PaletteAPIClient(baseURL: $0, token: token?.isEmpty == false ? token : nil) }
        if serverChanged { dropCacheBackedState() }
    }

    var isConfigured: Bool { client != nil }

    /// Retires cache-backed state: colors served from the cache and profiles
    /// offered from it. Such state belongs to the server it was cached from,
    /// so a server change (or Clear Cache) drops it rather than letting one
    /// server's offline palette linger on screen under the next server's URL.
    /// Live-fetched and project-loaded colors are untouched; only the next
    /// fetch decides their fate. A message describing the dropped state is
    /// retracted — it would otherwise keep describing a screen that is gone.
    private func dropCacheBackedState() {
        guard printerProfilesAreCached || isServingFromCache else { return }
        if printerProfilesAreCached {
            printerProfiles = []
            printerProfilesAreCached = false
            selectedPrinterProfileID = nil
        }
        if isServingFromCache {
            clearLoadedColors()
        }
        connectionMessage = nil
    }

    /// Cache namespace: the client's base URL string. Profile ids are unique
    /// only per server, so cached fetches are stored and read per server —
    /// one server's palette is never served for another's same-id profile.
    private var cacheServer: String? { client?.baseURL.absoluteString }

    // MARK: - Actions

    func testConnection() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        let requestedServer = client.baseURL.absoluteString
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.testConnection()
            // A late result describes the server it was sent to, which may no
            // longer be configured; only a fresh request may report.
            guard cacheServer == requestedServer else { return }
            connectionMessage = "Connected."
        } catch {
            guard cacheServer == requestedServer else { return }
            connectionMessage = (error as? PaletteAPIError)?.errorDescription
                ?? "Could not reach the server."
        }
    }

    func refreshAll() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        let requestedServer = client.baseURL.absoluteString
        isWorking = true
        defer { isWorking = false }
        do {
            let fetchedProfiles = try await client.fetchPrinterProfiles()
            // The server may have changed while the request was in flight;
            // the previous server's late response must not populate state.
            guard cacheServer == requestedServer else { return }
            printerProfiles = fetchedProfiles
            printerProfilesAreCached = false
            if selectedPrinterProfileID == nil { selectedPrinterProfileID = fetchedProfiles.first?.id }
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            await fetchColorsIfPossible()
        } catch {
            // A failure of an abandoned request says nothing about the
            // newly configured server — only a fresh request may report.
            guard cacheServer == requestedServer else { return }
            serveCachedProfilesIfUnavailable()
            handleFetchFailure(error, fallbackMessage: "Could not reach the server.")
        }
    }

    /// Drops every cached color fetch. Cache-backed state on screen — colors
    /// served from the cache, profiles offered from it — is cleared too;
    /// live-fetched and project-loaded colors are unaffected.
    func clearCache() {
        do {
            try cache.removeAll()
            dropCacheBackedState()
            connectionMessage = "Cleared cached colors."
        } catch {
            connectionMessage = "Could not clear the color cache."
        }
    }

    // MARK: - Color loading

    private func fetchColorsIfPossible() async {
        guard let client, let profileID = selectedPrinterProfileID else { return }
        let requestedServer = client.baseURL.absoluteString
        isWorking = true
        defer { isWorking = false }
        do {
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID)
            // The selection or server may have changed while the request was
            // in flight; a late response for another profile must not
            // overwrite it, and another server's response must be neither
            // shown nor cached under the current server.
            guard selectedPrinterProfileID == profileID, cacheServer == requestedServer else { return }
            applyFetched(dtos: dtos, profile: profile, profileID: profileID, server: requestedServer)
        } catch {
            guard selectedPrinterProfileID == profileID, cacheServer == requestedServer else { return }
            handleFetchFailure(error, fallbackMessage: "Could not load colors.")
        }
    }

    private func applyFetched(
        dtos: [PaletteColorDTO],
        profile: PrinterProfileDTO?,
        profileID: Int,
        server: String
    ) {
        let fetchedAt = Date()
        colors = dtos.compactMap { $0.toDomain() }
        colorsForProfile = profile
        lastRefresh = fetchedAt
        loadedColorsProfileID = profileID
        colorsLoadedFromProject = false
        isServingFromCache = false
        connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        // Best effort: a failed write only costs the *next* offline fallback,
        // never the live session, so the error is deliberately not surfaced.
        try? cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: profileID,
            profile: profile,
            colors: dtos,
            fetchedAt: fetchedAt
        ))
    }

    /// Serves the cached fetch for the selected profile when a usable one
    /// exists — unless the loaded project's own palette is on screen, which
    /// outranks the cache. Otherwise keeps colors already loaded for that
    /// profile and clears any other profile's leftovers, reporting `error`
    /// either way.
    private func handleFetchFailure(_ error: Error, fallbackMessage: String) {
        let reason = (error as? PaletteAPIError)?.errorDescription ?? fallbackMessage
        guard let profileID = selectedPrinterProfileID else {
            connectionMessage = reason
            return
        }
        // The clause is continued with an em-dash in the composed messages
        // below; the branches that show it standing alone restore the period.
        let clause = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        if let cached = servableCacheEntry(for: profileID) {
            serve(cached, profileID: profileID, reason: clause)
        } else {
            keepOrClearLoadedColors(profileID: profileID, reason: clause)
        }
    }

    /// The cached fetch the failure fallback may serve for `profileID`: an
    /// entry for the configured server carrying at least one usable color,
    /// when the loaded project's own palette isn't on screen (a saved
    /// document's palette is the data the user chose, not a stale fetch to
    /// fall back from). An empty cached fetch is nothing to serve, so it
    /// counts as a miss and the failure is reported plainly instead.
    private func servableCacheEntry(for profileID: Int) -> CachedProfileColors? {
        guard let server = cacheServer, !keepsProjectColors(profileID) else { return nil }
        guard let cached = cache.entry(for: profileID, serverBaseUrl: server),
              !cached.domainColors.isEmpty else { return nil }
        return cached
    }

    /// Whether the on-screen colors are the loaded project's own palette
    /// snapshot for the selected profile, and so win over the cache.
    private func keepsProjectColors(_ profileID: Int) -> Bool {
        colorsLoadedFromProject && loadedColorsProfileID == profileID
    }

    private func serve(_ cached: CachedProfileColors, profileID: Int, reason: String) {
        colors = cached.domainColors
        colorsForProfile = cached.profile
        lastRefresh = cached.fetchedAt
        loadedColorsProfileID = profileID
        colorsLoadedFromProject = false
        isServingFromCache = true
        connectionMessage = "\(reason) — showing cached colors from \(Self.cacheTimestamp(cached.fetchedAt))."
    }

    /// Keeps colors already on screen only when they belong to the selected
    /// profile and there are colors to keep; another profile's leftovers —
    /// or an empty palette — are cleared. The cache badge is left untouched —
    /// kept colors keep their true provenance.
    private func keepOrClearLoadedColors(profileID: Int, reason: String) {
        guard loadedColorsProfileID == profileID, !colors.isEmpty else {
            clearLoadedColors()
            connectionMessage = "\(reason)."
            return
        }
        let kept = colorsLoadedFromProject ? "colors loaded from the project" : "loaded colors"
        connectionMessage = "\(reason) — keeping \(kept)."
    }

    /// Offline cold start: offer cached profiles in the picker so a profile
    /// can be selected (and its colors then served from the cache) with no
    /// server round-trip at all.
    private func serveCachedProfilesIfUnavailable() {
        guard printerProfiles.isEmpty, let server = cacheServer else { return }
        let cachedProfiles = cache.allEntries(serverBaseUrl: server).compactMap(\.profile)
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
        colorsLoadedFromProject = false
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
