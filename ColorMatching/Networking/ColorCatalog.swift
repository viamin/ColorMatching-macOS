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

    @MainActor
    func configure(baseURL: URL?, token: String?) {
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

    private func beginRequest() {
        inFlightRequests += 1
        isWorking = true
    }

    private func endRequest() {
        inFlightRequests = max(0, inFlightRequests - 1)
        isWorking = inFlightRequests > 0
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
        printerProfiles.append(placeholderProfile(id: profileID))
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

    // MARK: - Actions

    @MainActor
    func testConnection() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        retireStaleCacheBackedState()
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        beginRequest()
        defer { endRequest() }
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

    @MainActor
    func refreshAll() async {
        guard let client else {
            connectionMessage = "Set a server URL first."
            return
        }
        retireStaleCacheBackedState()
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        beginRequest()
        defer { endRequest() }
        do {
            let fetchedProfiles = try await client.fetchPrinterProfiles()
            // The server may have changed while the request was in flight;
            // the previous server's late response must not populate state.
            guard cacheServer == requestedServer else { return }
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
            guard cacheServer == requestedServer else { return }
            // When the user has switched servers, an offline refresh must not
            // leave the previous server's live colors on screen under the new
            // server's profile list or "no profiles" state.
            clearLoadedColorsIfServerChanged()
            serveCachedProfilesIfUnavailable()
            handleFetchFailure(error, fallbackMessage: "Could not reach the server.")
        }
    }

    /// Drops every cached profile list and color fetch. Cache-backed state on
    /// screen — colors served from the cache, profiles offered from it — is
    /// cleared too; live-fetched and project-loaded colors are unaffected.
    @MainActor
    func clearCache() {
        do {
            try cache.removeAll()
            dropCacheBackedState()
            connectionMessage = "Cleared cached profiles and colors."
        } catch {
            connectionMessage = "Could not clear the color cache."
        }
    }

    /// Applies a project's embedded palette snapshot. If the currently shown
    /// profile list belongs to another server, drop it so the picker does not
    /// keep offering stale profiles that no longer match the configured server.
    @MainActor
    func loadProjectColors(_ projectColors: [PaletteColor], profileID: Int?) {
        if loadedPrinterProfilesServer != cacheServer {
            printerProfiles = []
            printerProfilesAreCached = false
            loadedPrinterProfilesServer = nil
        }
        ensureVisiblePrinterProfile(profileID)
        colors = projectColors
        // The snapshot carries no profile metadata, so the on-screen colors
        // describe no fetched profile; a later live fetch fills it back in.
        colorsForProfile = nil
        loadedColorsProfileID = profileID
        loadedColorsServer = nil
        colorsLoadedFromProject = true
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

    @MainActor
    private func fetchColorsIfPossible() async {
        // Retiring precedes the selection guard: clearing the selection —
        // picking "None", loading a project with no profile — is still an
        // action on the configured server, so another server's stale cached
        // profiles and colors must drop even though no fetch follows. (It
        // also precedes capturing `profileID` because retiring may clear the
        // selection; fetching afterwards would only be discarded.)
        guard let client else { return }
        retireStaleCacheBackedState()
        clearLoadedColorsIfServerChanged()
        guard let profileID = selectedPrinterProfileID else { return }
        let requestedServer = ProfileColorCache.normalizedServerBaseUrl(client.baseURL.absoluteString)
        beginRequest()
        defer { endRequest() }
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
        let sanitizedProfile = sanitizedProfile(profile, for: profileID)
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
        } else if let cached = servableCacheEntry(for: profileID) {
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
    /// with an older disk snapshot for the same profile and server.
    private func keepsLiveColors(_ profileID: Int) -> Bool {
        !colorsLoadedFromProject
            && !isServingFromCache
            && loadedColorsProfileID == profileID
            && loadedColorsServer == cacheServer
            && !colors.isEmpty
    }

    private func serve(_ cached: CachedProfileColors, profileID: Int, reason: String) {
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
    /// profile, come from the current server (or from a loaded project), and
    /// there are colors to keep; another profile's leftovers, another
    /// server's live fetch, or an empty palette are cleared. The cache badge
    /// is left untouched — kept colors keep their true provenance.
    private func keepOrClearLoadedColors(profileID: Int, reason: String) {
        guard loadedColorsProfileID == profileID, loadedColorsBelongToCurrentServer, !colors.isEmpty else {
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
        _ = reconcileSelectedProfile(with: cachedProfiles)
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

    private var keepsProfilesForCurrentServer: Bool {
        !printerProfiles.isEmpty && loadedPrinterProfilesServer == cacheServer
    }

    private var loadedColorsBelongToCurrentServer: Bool {
        colorsLoadedFromProject || loadedColorsServer == cacheServer
    }

    private var keepsActiveSelectionVisible: Bool {
        guard let selectedPrinterProfileID else { return false }
        return loadedColorsProfileID == selectedPrinterProfileID
            && loadedColorsBelongToCurrentServer
            && !colors.isEmpty
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
        guard let selectedPrinterProfileID, !colors.isEmpty else { return }
        guard loadedColorsProfileID != selectedPrinterProfileID else { return }
        clearLoadedColors()
    }

    /// A successful refresh can legitimately leave no selectable profile.
    /// When that happens, any live or cached colors from a previously selected
    /// profile are stale and must be cleared; a loaded project snapshot is the
    /// user's chosen document data and intentionally survives.
    private func clearLoadedColorsWithoutSelection() {
        guard selectedPrinterProfileID == nil, !colorsLoadedFromProject else { return }
        clearLoadedColors()
    }

    /// When the configured server changes, previously fetched live colors from
    /// another server become stale immediately, even if the selected numeric
    /// profile id happens to exist on both servers. A loaded project snapshot
    /// still survives because it is the user's chosen document state.
    private func clearLoadedColorsIfServerChanged() {
        guard !colorsLoadedFromProject, !colors.isEmpty else { return }
        guard let loadedColorsServer, loadedColorsServer != cacheServer else { return }
        clearLoadedColors()
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
