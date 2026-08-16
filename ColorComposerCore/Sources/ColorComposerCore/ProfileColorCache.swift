import Foundation

/// One cached fetch of a profile's colors: the wire DTOs exactly as the server
/// returned them, the server they came from, plus the moment they were fetched
/// (the staleness marker).
public struct CachedProfileColors: Codable, Equatable, Sendable {
    /// Base URL string of the server the fetch came from. Profile ids are
    /// unique only per server, so this field keeps one server's cached palette
    /// from ever being served for another's same-id profile: reads treat a
    /// mismatch as a miss. Spelled `serverBaseUrl` (not `serverBaseURL`) for
    /// the CodingKey reason given at `profileId` below.
    public let serverBaseUrl: String
    /// Deliberately `profileId` (not `profileID`): the auto-generated CodingKey
    /// must round-trip through Foundation's snake-case key conversion. The
    /// encoded `profile_id` decodes back as `profileId`; `profileID` would
    /// never match and every cache read would silently count as a miss.
    public let profileId: Int
    public let profile: PrinterProfileDTO?
    public let colors: [PaletteColorDTO]
    public let fetchedAt: Date

    public init(
        serverBaseUrl: String,
        profileId: Int,
        profile: PrinterProfileDTO?,
        colors: [PaletteColorDTO],
        fetchedAt: Date
    ) {
        self.serverBaseUrl = serverBaseUrl
        self.profileId = profileId
        self.profile = profile
        self.colors = colors
        self.fetchedAt = fetchedAt
    }
}

public extension CachedProfileColors {
    /// The cached colors converted to solver-ready domain colors. An entry
    /// that cached an empty fetch — or whose DTOs all fail conversion (no
    /// rgb, unparseable hex) — yields none, and so is nothing to serve
    /// offline: callers report the failure plainly instead of claiming to
    /// show cached colors over an empty palette.
    var domainColors: [PaletteColor] {
        colors.compactMap { $0.toDomain() }
    }

    /// `true` when the cached fetch still contains at least one usable color
    /// to serve offline. Cached profiles without any convertible colors are
    /// not useful fallbacks and should stay out of the offline picker too.
    var hasServableColors: Bool {
        !domainColors.isEmpty
    }
}

/// Disk cache of the last-fetched colors per printer profile, so the app can
/// keep composing when the `color_matching` server is unreachable.
///
/// Each profile's fetch is stored as one JSON file (`profile-<id>.json`) under
/// a server-specific subdirectory of `directory`, encoded with the same
/// snake-case wire format the API uses. Entries record the server they were
/// fetched from and are never served across servers — profile ids are unique
/// only per server, so (server, profile) is the real cache key. Reads treat a
/// missing or corrupt file as a cache miss; writes are atomic, so a crash
/// mid-write can never leave a half-written entry.
///
/// Deliberately over the ~100-line type guideline: the read, write, and
/// integrity-check paths all share one file-naming contract, and splitting
/// them would spread that contract across collaborators without reducing
/// any complexity.
public struct ProfileColorCache: Sendable {
    /// Root directory holding one subdirectory per server, each with one
    /// `profile-<id>.json` per cached profile.
    public let directory: URL

    /// Cache at an explicit directory (tests and custom locations).
    public init(directory: URL) {
        self.directory = directory
    }

    /// Default cache under the user's Caches directory:
    /// `<Caches>/ColorMatching/ProfileColorCache`.
    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: base
            .appendingPathComponent("ColorMatching", isDirectory: true)
            .appendingPathComponent("ProfileColorCache", isDirectory: true))
    }

    // MARK: - Reads

    /// The cached fetch for a profile on `serverBaseUrl`, or `nil` when nothing
    /// usable is cached (a missing, unreadable, or corrupt file — or one whose
    /// stored profile id or server disagrees with the request — all count as
    /// a miss).
    public func entry(for profileID: Int, serverBaseUrl: String) -> CachedProfileColors? {
        let normalizedServerBaseUrl = Self.normalizedServerBaseUrl(serverBaseUrl)
        guard let entry = entry(at: fileURL(for: profileID, serverBaseUrl: normalizedServerBaseUrl)),
              entry.profileId == profileID,
              Self.normalizedServerBaseUrl(entry.serverBaseUrl) == normalizedServerBaseUrl else { return nil }
        return entry
    }

    /// Every intact cached entry for `serverBaseUrl`, ordered by profile id.
    /// Only files honoring the `profile-<id>.json` naming contract with a
    /// matching stored id and server are returned. Used to offer cached
    /// profiles in the picker when the server cannot be reached at all.
    public func allEntries(serverBaseUrl: String) -> [CachedProfileColors] {
        let normalizedServerBaseUrl = Self.normalizedServerBaseUrl(serverBaseUrl)
        let serverDirectory = directory(for: normalizedServerBaseUrl)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: serverDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .compactMap { url in
                guard let id = Self.profileID(fromFileURL: url),
                      let entry = entry(at: url),
                      entry.profileId == id,
                      Self.normalizedServerBaseUrl(entry.serverBaseUrl) == normalizedServerBaseUrl else { return nil }
                return entry
            }
            .sorted { $0.profileId < $1.profileId }
    }

    // MARK: - Writes

    /// Stores (or overwrites) the cached fetch for `entry.profileId`. Two
    /// servers' entries for the same profile id live in different
    /// subdirectories and do not overwrite one another.
    public func store(_ entry: CachedProfileColors) throws {
        let normalizedEntry = normalized(entry)
        let serverDirectory = directory(for: normalizedEntry.serverBaseUrl)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try encode(normalizedEntry).write(
            to: fileURL(for: normalizedEntry.profileId, serverBaseUrl: normalizedEntry.serverBaseUrl),
            options: .atomic
        )
    }

    /// Removes every cached profile. A missing cache directory is a no-op.
    public func removeAll() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    private static let fileStemPrefix = "profile-"

    private func directory(for serverBaseUrl: String) -> URL {
        directory.appendingPathComponent(Self.directoryName(for: serverBaseUrl), isDirectory: true)
    }

    private func fileURL(for profileID: Int, serverBaseUrl: String) -> URL {
        directory(for: serverBaseUrl).appendingPathComponent("\(Self.fileStemPrefix)\(profileID).json")
    }

    /// The `<id>` in a cache file named `profile-<id>.json`, if it parses.
    private static func profileID(fromFileURL url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", stem.hasPrefix(fileStemPrefix) else { return nil }
        return Int(stem.dropFirst(fileStemPrefix.count))
    }

    private static func directoryName(for serverBaseUrl: String) -> String {
        let base64 = Data(serverBaseUrl.utf8).base64EncodedString()
        let safe = base64
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "server-\(safe)"
    }

    /// Cache keys should ignore harmless URL spelling differences like a
    /// trailing slash or host capitalization, so one logical server maps to
    /// one cache namespace.
    public static func normalizedServerBaseUrl(_ serverBaseUrl: String) -> String {
        let trimmed = serverBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        if let port = components.port, isDefaultPort(port, for: components.scheme) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil

        let path = components.percentEncodedPath
        if path == "/" {
            components.percentEncodedPath = ""
        } else if !path.isEmpty {
            let trimmedPath = String(path.dropLast(while: { $0 == "/" }))
            components.percentEncodedPath = trimmedPath.allSatisfy({ $0 == "/" }) ? "" : trimmedPath
        }

        return components.string ?? trimmed
    }

    private static func isDefaultPort(_ port: Int, for scheme: String?) -> Bool {
        switch scheme {
        case "http": return port == 80
        case "https": return port == 443
        default: return false
        }
    }

    private func normalized(_ entry: CachedProfileColors) -> CachedProfileColors {
        CachedProfileColors(
            serverBaseUrl: Self.normalizedServerBaseUrl(entry.serverBaseUrl),
            profileId: entry.profileId,
            profile: entry.profile,
            colors: entry.colors,
            fetchedAt: entry.fetchedAt
        )
    }

    private func entry(at url: URL) -> CachedProfileColors? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private func encode(_ entry: CachedProfileColors) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entry)
    }

    private func decode(_ data: Data) -> CachedProfileColors? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedProfileColors.self, from: data)
    }
}
