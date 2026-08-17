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
@MainActor
@Observable
final class ColorCatalog {
    var printerProfiles: [PrinterProfileDTO] = []
    var colors: [PaletteColor] = []
    var colorsForProfile: PrinterProfileDTO?

    var selectedPrinterProfileID: Int? {
        didSet {
            guard !suppressesSelectionFetch else { return }
            clearStaleColorsForSelectionChange()
            Task { @MainActor in await fetchColorsIfPossible() }
        }
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
    /// Server whose fetch produced the on-screen `colors`, or `nil` when they
    /// came from a loaded project snapshot. A failed fetch keeps live/server
    /// colors only when they belong to the currently configured server.
    var loadedColorsServer: String?
    /// True when `colors` are the loaded project's embedded palette snapshot
    /// (set by the app model when a `.cmpj` is opened). A failed fetch keeps
    /// them even when a cache entry exists: a saved document's palette is the
    /// data the user chose, not a stale fetch to fall back from.
    var colorsLoadedFromProject = false

    private var client: PaletteAPIClient?
    private let cache: ProfileColorCache
    /// Multiple request paths can overlap (for example a refresh updating the
    /// selection, whose `didSet` launches a color fetch). Track the count so a
    /// finishing request does not re-enable the UI while another is still live.
    private var inFlightRequests = 0
    /// Request-activity generation for `isWorking`: invalidating requests for a
    /// local state restore (like opening a project) must retire their busy
    /// count immediately, and their eventual completions must not decrement the
    /// next generation's count.
    private var requestActivityGeneration = 0
    private var connectionRequestID = 0
    private var profileRefreshRequestID = 0
    private var colorFetchRequestID = 0
    /// `configure` runs on every edit of the server settings. Bump this so a
    /// late response from superseded credentials/configuration cannot report.
    private var configurationRevision = 0
    /// Internal state changes sometimes need to update the selection without
    /// triggering an immediate fetch. Opening a saved project is the key case:
    /// the document should restore its embedded palette snapshot exactly as
    /// saved, not opportunistically replace it with whatever the server now
    /// returns for the same profile.
    private var suppressesSelectionFetch = false
    /// True when `printerProfiles` were offered from the offline cache because
    /// the server could not be reached at all.
    private var printerProfilesAreCached = false
    /// Server whose profile list is currently on screen, whether it came from
    /// a live refresh or the offline cache. Used so a failed refresh for one
    /// server can replace another server's stale list with the current
    /// server's cached profiles — or clear the stale list when none exist.
    private var loadedPrinterProfilesServer: String?
    /// The server whose cache-backed state (cached profiles, cached colors) is
    /// currently on screen, or `nil` when none is. Only consulted while some
    /// cache-backed state is actually on screen — `retireStaleCacheBackedState`
    /// checks the flags first — so a value left over from state a later live
    /// fetch replaced is never read; the next drop clears it.
    private var cacheBackedServer: String?

    init(cache: ProfileColorCache = ProfileColorCache()) {
        self.cache = cache
    }

    func configure(baseURL: URL?, token: String?) {
        configurationRevision += 1
        client = baseURL.map { PaletteAPIClient(baseURL: $0, token: token?.isEmpty == false ? token : nil) }
    }

    var isConfigured: Bool { client != nil }

    /// Retires cache-backed state left over from a different server, before
    /// this server is used for a real request. `configure` cannot call this
    /// directly: it runs on every keystroke while the server URL field is
    /// edited, and eagerly dropping cache-backed state there would blank the
    /// screen mid-edit, before the user has typed a real URL. Instead every
    /// entry point that actually acts on the configured server — testing it,
    /// refreshing from it, fetching colors from it — calls this first, so a
    /// genuinely different server's stale offline data is retired before it
    /// can be shown as (or mistaken for) the new server's own.
    private func retireStaleCacheBackedState() {
        guard printerProfilesAreCached || isServingFromCache,
              cacheBackedServer != cacheServer else { return }
        dropCacheBackedState()
    }

    /// Retires cache-backed state: colors served from the cache and profiles
    /// offered from it. Live-fetched and project-loaded colors are untouched;
    /// only the next fetch decides their fate. Only the cached-colors message
    /// is retracted, with the colors it described — no path composes one
    /// about cached profiles, so a profiles-only drop keeps messages that
    /// still describe the colors on screen (a plain failure reason, a loaded
    /// project's palette). The loaded project's profile selection survives
    /// too: it was chosen by the document, not picked from the cached list.
    private func dropCacheBackedState() {
        guard printerProfilesAreCached || isServingFromCache else { return }
        if printerProfilesAreCached {
            printerProfiles = []
            printerProfilesAreCached = false
            loadedPrinterProfilesServer = nil
        }
        if isServingFromCache {
            clearLoadedColors()
            connectionMessage = nil
        }
        // Decide after cached colors are gone: otherwise a cached palette
        // being cleared could incorrectly keep its now-invisible profile
        // selected even though no live or project colors remain.
        if keepsActiveSelectionVisible {
            ensureVisiblePrinterProfile(selectedPrinterProfileID)
        } else {
            clearSelectedProfileIfUnavailable()
        }
        clearCacheBackedServerIfUnused()
    }

    /// `cacheBackedServer` only matters while some cache-backed profiles or
    /// colors are on screen. Once both have gone, clear the marker so later
    /// server changes and retries reason from current state only.
    private func clearCacheBackedServerIfUnused() {
        guard !printerProfilesAreCached, !isServingFromCache else { return }
        cacheBackedServer = nil
    }

    /// Cache namespace and server identity: a normalized base URL string.
    /// Harmless spelling differences (host case, trailing slash, default port)
    /// still name the same logical server everywhere the catalog reasons about
    /// live, cached, and project-loaded state.
    private var cacheServer: String? {
        client.map { ProfileColorCache.normalizedServerBaseUrl($0.baseURL.absoluteString) }
    }

    /// A live or cached profile list from another server must not remain
    /// selectable once the user acts on the newly configured server. Keep only
    /// a still-visible active selection (for current colors or a loaded
    /// project) as a placeholder; otherwise clear the stale list entirely so a
    /// later fetch never sends another server's profile id to this one.
    private func retireStaleProfileListForServerAction() {
        guard loadedPrinterProfilesServer != cacheServer else { return }
        printerProfiles = []
        printerProfilesAreCached = false
        loadedPrinterProfilesServer = nil
        if keepsActiveSelectionVisible {
            ensureVisiblePrinterProfile(selectedPrinterProfileID)
        } else {
            clearSelectedProfileIfUnavailable()
        }
        clearCacheBackedServerIfUnused()
    }

    private func beginRequest() -> Int {
        inFlightRequests += 1
        isWorking = true
        return requestActivityGeneration
    }

    private func endRequest(_ generation: Int) {
        guard generation == requestActivityGeneration else { return }
        inFlightRequests = max(0, inFlightRequests - 1)
        isWorking = inFlightRequests > 0
    }

    private func nextConnectionRequestID() -> Int {
        connectionRequestID += 1
        return connectionRequestID
    }

    private func nextProfileRefreshRequestID() -> Int {
        profileRefreshRequestID += 1
        return profileRefreshRequestID
    }

    private func nextColorFetchRequestID() -> Int {
        colorFetchRequestID += 1
        return colorFetchRequestID
    }

    /// Loading a saved project snapshot is a local state restore, not a
    /// network refresh. Any in-flight request that started before that restore
    /// must be ignored when it finishes, even if the caller did not happen to
    /// reconfigure the catalog first.
    private func invalidateOutstandingRequests() {
        connectionRequestID += 1
        profileRefreshRequestID += 1
        colorFetchRequestID += 1
        requestActivityGeneration += 1
        inFlightRequests = 0
        isWorking = false
    }

    private func restoreSelectedPrinterProfileID(_ profileID: Int?) {
        suppressesSelectionFetch = true
        defer { suppressesSelectionFetch = false }
        selectedPrinterProfileID = profileID
    }

    private func includesProfile(_ profileID: Int) -> Bool {
        printerProfiles.contains { $0.id == profileID }
    }

    private func placeholderProfile(id: Int) -> PrinterProfileDTO {
        PrinterProfileDTO(
            id: id,
            printerMakeModel: nil,
            paperType: nil,
            inkType: nil
        )
    }

    private func visiblePrinterProfile(for profileID: Int) -> PrinterProfileDTO {
        guard let colorsForProfile, colorsForProfile.id == profileID else {
            return placeholderProfile(id: profileID)
        }
        return colorsForProfile
    }

    /// The API response is an external boundary: if it carries profile
    /// metadata for another id, treat that metadata as absent rather than
    /// showing one profile's details for another profile's colors.
    private func sanitizedProfile(_ profile: PrinterProfileDTO?, for profileID: Int) -> PrinterProfileDTO? {
        guard let profile, profile.id == profileID else { return nil }
        return profile
    }

    /// A saved project can refer to a profile id that the current on-screen
    /// list does not include yet (or no longer includes). Keep that selection
    /// representable in the picker until a later refresh replaces it with the
    /// server's current list.
    private func ensureVisiblePrinterProfile(_ profileID: Int?) {
        guard let profileID else { return }
        guard !includesProfile(profileID) else { return }
        printerProfiles.append(visiblePrinterProfile(for: profileID))
        printerProfiles.sort { $0.id < $1.id }
    }

    /// A live color fetch can return fresher metadata for the selected
    /// profile than the on-screen list currently has (for example replacing a
    /// placeholder or stale cached entry). Refresh just that visible row
    /// without claiming to have reloaded the full profile list.
    private func refreshVisiblePrinterProfile(_ profile: PrinterProfileDTO?) {
        guard let profile else { return }
        if let index = printerProfiles.firstIndex(where: { $0.id == profile.id }) {
            printerProfiles[index] = profile
            return
        }
        guard selectedPrinterProfileID == profile.id else { return }
        printerProfiles.append(profile)
        printerProfiles.sort { $0.id < $1.id }
    }

    /// The picker changes selection synchronously, before any replacement fetch
    /// completes. Clear live/cached colors that no longer match immediately so
    /// the UI does not show profile A's palette while profile B (or None) is
    /// selected. A loaded project snapshot intentionally survives deselection.
    private func clearStaleColorsForSelectionChange() {
        clearLoadedColorsIfSelectionChanged()
        clearLoadedColorsWithoutSelection()
    }

    /// Once color state has been cleared because the selection or server no
    /// longer matches it, any status message describing those colors is stale
    /// too. The next request or explicit load path can report fresh state.
    private func clearColorMessageIfNoColorsRemain() {
        guard !hasLoadedColorState else { return }
        connectionMessage = nil
    }

    // MARK: - Actions

    func testConnection() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        retireStaleCacheBackedState()
        retireStaleProfileListForServerAction()
        clearLoadedColorsIfServerChanged()
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        let requestedConfigurationRevision = configurationRevision
        let requestID = nextConnectionRequestID()
        let activityGeneration = beginRequest()
        defer { endRequest(activityGeneration) }
        do {
            try await client.testConnection()
            // A late result describes the server it was sent to, which may no
            // longer be configured; only a fresh request may report.
            guard cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  connectionRequestID == requestID else { return }
            connectionMessage = "Connected."
        } catch {
            guard cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  connectionRequestID == requestID else { return }
            connectionMessage = (error as? PaletteAPIError)?.errorDescription
                ?? "Could not reach the server."
        }
    }

    func refreshAll() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        retireStaleCacheBackedState()
        retireStaleProfileListForServerAction()
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        let requestedConfigurationRevision = configurationRevision
        let requestID = nextProfileRefreshRequestID()
        let activityGeneration = beginRequest()
        defer { endRequest(activityGeneration) }
        do {
            let fetchedProfiles = try await client.fetchPrinterProfiles()
            // The server may have changed while the request was in flight;
            // the previous server's late response must not populate state.
            guard cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  profileRefreshRequestID == requestID else { return }
            printerProfiles = fetchedProfiles
            printerProfilesAreCached = false
            loadedPrinterProfilesServer = requestedServer
            clearLoadedColorsIfServerChanged()
            _ = reconcileSelectedProfile(with: fetchedProfiles)
            clearLoadedColorsIfSelectionChanged()
            clearLoadedColorsWithoutSelection()
            clearCacheBackedServerIfUnused()
            connectionMessage = "Loaded \(fetchedProfiles.count) profile(s)."
            await fetchColorsIfPossible()
        } catch {
            // A failure of an abandoned request says nothing about the
            // newly configured server — only a fresh request may report.
            guard cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  profileRefreshRequestID == requestID else { return }
            // When the user has switched servers, an offline refresh must not
            // leave the previous server's live colors on screen under the new
            // server's profile list or "no profiles" state.
            clearLoadedColorsIfServerChanged()
            if allowsOfflineFallback(for: error) {
                serveCachedProfilesIfUnavailable()
            }
            handleFetchFailure(error, fallbackMessage: "Could not reach the server.")
        }
    }

    /// Drops every cached profile list and color fetch. Cache-backed state on
    /// screen — colors served from the cache, profiles offered from it — is
    /// cleared too; live-fetched and project-loaded colors are unaffected.
    func clearCache() {
        guard !isWorking else {
            connectionMessage = "Wait for the current request to finish before clearing the cache."
            return
        }
        do {
            try cache.removeAll()
            dropCacheBackedState()
            connectionMessage = "Cleared the offline color cache."
        } catch {
            connectionMessage = "Could not clear the color cache."
        }
    }

    /// Applies a project's embedded palette snapshot. If the currently shown
    /// profile list belongs to another server, drop it so the picker does not
    /// keep offering stale profiles that no longer match the configured server.
    func loadProjectColors(_ projectColors: [PaletteColor], profileID: Int?) {
        invalidateOutstandingRequests()
        if loadedPrinterProfilesServer != cacheServer {
            printerProfiles = []
            printerProfilesAreCached = false
            loadedPrinterProfilesServer = nil
        }
        colors = projectColors
        // The snapshot carries no profile metadata, so the on-screen colors
        // describe no fetched profile; a later live fetch fills it back in.
        colorsForProfile = nil
        loadedColorsProfileID = profileID
        loadedColorsServer = nil
        colorsLoadedFromProject = true
        // If the project switches servers, `colorsForProfile` may still hold
        // metadata from an earlier live fetch for the same numeric id. Clear
        // that first so the picker keeps only a placeholder until a live
        // refresh repopulates profile details for this server.
        ensureVisiblePrinterProfile(profileID)
        // A document snapshot is neither a live refresh nor a cached fetch, so
        // leave the timestamp empty rather than mislabeling "right now" as the
        // age of server-derived data.
        lastRefresh = nil
        isServingFromCache = false
        clearCacheBackedServerIfUnused()
        connectionMessage = "Loaded \(projectColors.count) color(s) from project."
        // Opening a project restores its embedded snapshot exactly; a manual
        // refresh can replace it with live server data later.
        restoreSelectedPrinterProfileID(profileID)
    }

    // MARK: - Color loading

    private func fetchColorsIfPossible() async {
        // Retiring precedes the selection guard: clearing the selection —
        // picking "None", loading a project with no profile — is still an
        // action on the configured server, so another server's stale cached
        // profiles and colors must drop even though no fetch follows. (It
        // also precedes capturing `profileID` because retiring may clear the
        // selection; fetching afterwards would only be discarded.)
        guard let client else { return }
        retireStaleCacheBackedState()
        retireStaleProfileListForServerAction()
        clearLoadedColorsIfServerChanged()
        guard let profileID = selectedPrinterProfileID else { return }
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        let requestedConfigurationRevision = configurationRevision
        let requestID = nextColorFetchRequestID()
        let activityGeneration = beginRequest()
        defer { endRequest(activityGeneration) }
        do {
            let (dtos, profile) = try await client.fetchColors(printerProfileID: profileID)
            // The selection or server may have changed while the request was
            // in flight; a late response for another profile must not
            // overwrite it, and another server's response must be neither
            // shown nor cached under the current server.
            guard selectedPrinterProfileID == profileID,
                  cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  colorFetchRequestID == requestID else { return }
            applyFetched(dtos: dtos, profile: profile, profileID: profileID, server: requestedServer)
        } catch {
            guard selectedPrinterProfileID == profileID,
                  cacheServer == requestedServer,
                  configurationRevision == requestedConfigurationRevision,
                  colorFetchRequestID == requestID else { return }
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
        let sanitizedProfile = sanitizedProfile(profile, for: profileID)
        refreshVisiblePrinterProfile(sanitizedProfile)
        colors = dtos.compactMap { $0.toDomain() }
        colorsForProfile = sanitizedProfile
        lastRefresh = fetchedAt
        loadedColorsProfileID = profileID
        loadedColorsServer = server
        colorsLoadedFromProject = false
        isServingFromCache = false
        clearCacheBackedServerIfUnused()
        connectionMessage = "Loaded \(colors.count) color(s) for this profile."
        // Best effort: a failed write only costs the *next* offline fallback,
        // never the live session, so the error is deliberately not surfaced.
        try? cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: profileID,
            profile: sanitizedProfile,
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
        if keepsLiveColors(profileID) {
            keepOrClearLoadedColors(profileID: profileID, reason: clause)
        } else if allowsOfflineFallback(for: error),
                  let cached = servableCacheEntry(for: profileID) {
            serve(cached, profileID: profileID, reason: clause)
        } else {
            keepOrClearLoadedColors(profileID: profileID, reason: clause)
        }
    }

    /// Offline cache is only for transport failures: using stale local data to
    /// hide a 401, 500, or malformed payload would misreport a live server
    /// problem as "offline".
    private func allowsOfflineFallback(for error: Error) -> Bool {
        if error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
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
              cached.hasServableColors else { return nil }
        return cached
    }

    /// Whether the on-screen colors are the loaded project's own palette
    /// snapshot for the selected profile, and so win over the cache. An
    /// empty snapshot is no palette to protect — nothing chosen is on
    /// screen, so the cache may still serve offline.
    private func keepsProjectColors(_ profileID: Int) -> Bool {
        colorsLoadedFromProject && loadedColorsProfileID == profileID && !colors.isEmpty
    }

    /// A failed refresh must not replace fresher live colors already on screen
    /// with an older disk snapshot for the same profile and server. That
    /// includes a successful live fetch that returned zero colors: the empty
    /// result is still the freshest known server state for that profile.
    private func keepsLiveColors(_ profileID: Int) -> Bool {
        !colorsLoadedFromProject
            && !isServingFromCache
            && loadedColorsProfileID == profileID
            && loadedColorsServer == cacheServer
            && hasLoadedColorState
    }

    private func serve(_ cached: CachedProfileColors, profileID: Int, reason: String) {
        refreshVisiblePrinterProfile(cached.profile)
        colors = cached.domainColors
        colorsForProfile = cached.profile
        lastRefresh = cached.fetchedAt
        loadedColorsProfileID = profileID
        loadedColorsServer = cached.serverBaseUrl
        colorsLoadedFromProject = false
        isServingFromCache = true
        cacheBackedServer = cacheServer
        connectionMessage = "\(reason) — showing cached colors from \(Self.cacheTimestamp(cached.fetchedAt))."
    }

    /// Keeps colors already on screen only when they belong to the selected
    /// profile and still describe current state. A live fetch from the current
    /// server stays authoritative even when it returned zero colors; project
    /// snapshots and cached colors only stay when they still contain colors to
    /// show. Another profile's leftovers or another server's live fetch are
    /// cleared. The cache badge is left untouched — kept colors keep their
    /// true provenance.
    private func keepOrClearLoadedColors(profileID: Int, reason: String) {
        guard shouldKeepLoadedColors(profileID: profileID) else {
            clearLoadedColors()
            clearSelectedProfileIfUnavailable()
            connectionMessage = "\(reason)."
            return
        }
        let kept: String
        if colorsLoadedFromProject {
            kept = "colors loaded from the project"
        } else if isServingFromCache {
            kept = "cached colors"
        } else {
            kept = "loaded colors"
        }
        connectionMessage = "\(reason) — keeping \(kept)."
    }

    private func shouldKeepLoadedColors(profileID: Int) -> Bool {
        guard loadedColorsProfileID == profileID, loadedColorsBelongToCurrentServer else { return false }
        if colorsLoadedFromProject || isServingFromCache {
            return !colors.isEmpty
        }
        return hasLoadedColorState
    }

    /// Offline cold start: offer cached profiles in the picker so a profile
    /// can be selected (and its colors then served from the cache) with no
    /// server round-trip at all. If another server's profiles are on screen
    /// and there is no cache for the current one, clear that stale list so the
    /// picker does not mislabel it as belonging to the current server.
    private func serveCachedProfilesIfUnavailable() {
        guard let server = cacheServer, !keepsProfilesForCurrentServer else { return }
        var cachedProfiles = cache.allEntries(serverBaseUrl: server)
            .filter(\.hasServableColors)
            .map { entry in
                entry.profile ?? placeholderProfile(id: entry.profileId)
            }
        guard !cachedProfiles.isEmpty else {
            printerProfiles = []
            printerProfilesAreCached = false
            loadedPrinterProfilesServer = nil
            if keepsActiveSelectionWithoutCachedProfiles {
                ensureVisiblePrinterProfile(selectedPrinterProfileID)
            } else {
                restoreSelectedPrinterProfileID(nil)
            }
            clearCacheBackedServerIfUnused()
            return
        }
        if keepsActiveSelectionVisible, let selectedPrinterProfileID, !cachedProfiles.contains(where: { $0.id == selectedPrinterProfileID }) {
            cachedProfiles.append(placeholderProfile(id: selectedPrinterProfileID))
            cachedProfiles.sort { $0.id < $1.id }
        }
        printerProfiles = cachedProfiles
        printerProfilesAreCached = true
        loadedPrinterProfilesServer = server
        cacheBackedServer = server
        let selectionChanged = reconcileSelectedProfile(with: cachedProfiles)
        // Refreshing from the cache can silently move the picker to another
        // profile; clear any now-mismatched colors here so this fallback path
        // stays correct even if a caller later changes the surrounding order.
        if selectionChanged {
            clearLoadedColorsIfSelectionChanged()
            clearLoadedColorsWithoutSelection()
        }
    }

    private static func cacheTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }

    /// Keeps the current selection only while the profile list still contains
    /// it; otherwise picks the first available profile so the picker and the
    /// next color fetch stay in sync with the list on screen.
    private func reconcileSelectedProfile(with profiles: [PrinterProfileDTO]) -> Bool {
        guard let selectedPrinterProfileID else {
            let replacement = profiles.first?.id
            restoreSelectedPrinterProfileID(replacement)
            return replacement != nil
        }
        guard !profiles.contains(where: { $0.id == selectedPrinterProfileID }) else { return false }
        let replacement = profiles.first?.id
        let changed = replacement != selectedPrinterProfileID
        restoreSelectedPrinterProfileID(replacement)
        return changed
    }

    /// A successful live refresh for the current server remains authoritative
    /// even when it returned zero profiles. Otherwise an offline retry after a
    /// live-empty response would incorrectly resurrect older cached profiles.
    private var keepsProfilesForCurrentServer: Bool {
        loadedPrinterProfilesServer == cacheServer && !printerProfilesAreCached
    }

    /// Loaded color state includes metadata too, not just non-empty palettes:
    /// a zero-color fetch still stamps `lastRefresh`, server/profile ownership,
    /// and possibly cache provenance, all of which become stale when the
    /// selection or configured server changes.
    private var hasLoadedColorState: Bool {
        !colors.isEmpty
            || colorsForProfile != nil
            || loadedColorsProfileID != nil
            || loadedColorsServer != nil
            || lastRefresh != nil
            || colorsLoadedFromProject
            || isServingFromCache
    }

    private var loadedColorsBelongToCurrentServer: Bool {
        colorsLoadedFromProject || loadedColorsServer == cacheServer
    }

    /// Keep the active selection representable whenever the on-screen state
    /// still belongs to that profile, even if its palette is empty. A
    /// zero-color live fetch or loaded project snapshot still carries real
    /// profile ownership that later retries and refreshes should preserve.
    private var keepsActiveSelectionVisible: Bool {
        guard let selectedPrinterProfileID else { return false }
        return loadedColorsProfileID == selectedPrinterProfileID
            && loadedColorsBelongToCurrentServer
            && hasLoadedColorState
    }

    /// When no cached profile list exists for the current server, still keep
    /// the active selection representable if the on-screen colors already
    /// belong to it (from a live fetch, cache fallback, or loaded project).
    private var keepsActiveSelectionWithoutCachedProfiles: Bool {
        keepsActiveSelectionVisible
    }

    /// When the active selection changes to another concrete profile, any
    /// colors left from the previous profile become stale immediately and
    /// should drop before the replacement fetch completes. That includes a
    /// loaded project snapshot with no associated profile id: once the user
    /// picks a concrete profile, those colors no longer describe the
    /// selection shown in the picker.
    private func clearLoadedColorsIfSelectionChanged() {
        guard let selectedPrinterProfileID, hasLoadedColorState else { return }
        guard loadedColorsProfileID != selectedPrinterProfileID else { return }
        clearLoadedColors()
        clearColorMessageIfNoColorsRemain()
    }

    /// A successful refresh can legitimately leave no selectable profile.
    /// When that happens, any live or cached colors from a previously selected
    /// profile are stale and must be cleared; a loaded project snapshot is the
    /// user's chosen document data and intentionally survives.
    private func clearLoadedColorsWithoutSelection() {
        guard selectedPrinterProfileID == nil, !colorsLoadedFromProject else { return }
        clearLoadedColors()
        clearColorMessageIfNoColorsRemain()
    }

    /// When the configured server changes, previously fetched live colors from
    /// another server become stale immediately, even if the selected numeric
    /// profile id happens to exist on both servers. A loaded project snapshot
    /// still survives because it is the user's chosen document state.
    private func clearLoadedColorsIfServerChanged() {
        guard !colorsLoadedFromProject, hasLoadedColorState else { return }
        guard let loadedColorsServer, loadedColorsServer != cacheServer else { return }
        clearLoadedColors()
        clearColorMessageIfNoColorsRemain()
    }

    /// Once stale colors are cleared, keep the selection only if the current
    /// on-screen profile list still contains it. Otherwise the picker holds an
    /// invisible id from another server, which no longer describes any state
    /// the user can see or save.
    private func clearSelectedProfileIfUnavailable() {
        guard let selectedPrinterProfileID else { return }
        guard !includesProfile(selectedPrinterProfileID) else { return }
        restoreSelectedPrinterProfileID(nil)
    }

    private func clearLoadedColors() {
        colors = []
        colorsForProfile = nil
        lastRefresh = nil
        loadedColorsProfileID = nil
        loadedColorsServer = nil
        colorsLoadedFromProject = false
        isServingFromCache = false
        clearCacheBackedServerIfUnused()
    }

    /// Colors eligible for the solver given the currently active channels.
    /// Colors missing measurements for any active channel are excluded, matching
    /// the solver's policy; the UI surfaces the excluded count.
    func eligibleColors(activeConditions: [LightingCondition]) -> [PaletteColor] {
        let required = Set(activeConditions)
        return colors.filter { $0.hasMeasurements(for: required) }
    }
}
