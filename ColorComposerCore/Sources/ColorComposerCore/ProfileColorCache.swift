import Foundation

/// One cached fetch of a profile's colors: the wire DTOs exactly as the server
/// returned them, plus the moment they were fetched (the staleness marker).
public struct CachedProfileColors: Codable, Equatable, Sendable {
    public let profileID: Int
    public let profile: PrinterProfileDTO?
    public let colors: [PaletteColorDTO]
    public let fetchedAt: Date

    public init(profileID: Int, profile: PrinterProfileDTO?, colors: [PaletteColorDTO], fetchedAt: Date) {
        self.profileID = profileID
        self.profile = profile
        self.colors = colors
        self.fetchedAt = fetchedAt
    }
}

/// Disk cache of the last-fetched colors per printer profile, so the app can
/// keep composing when the `color_matching` server is unreachable.
///
/// Each profile's fetch is stored as one JSON file (`profile-<id>.json`) under
/// `directory`, encoded with the same snake-case wire format the API uses.
/// Reads treat a missing or corrupt file as a cache miss; writes are atomic,
/// so a crash mid-write can never leave a half-written entry.
public struct ProfileColorCache: Sendable {
    /// Directory holding one `profile-<id>.json` per cached profile.
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

    /// The cached fetch for a profile, or `nil` when nothing usable is cached
    /// (a missing, unreadable, or corrupt file — or one whose stored profile
    /// id disagrees with the requested one — all count as a miss).
    public func entry(for profileID: Int) -> CachedProfileColors? {
        guard let entry = entry(at: fileURL(for: profileID)),
              entry.profileID == profileID else { return nil }
        return entry
    }

    /// Every intact cached entry, ordered by profile id. Only files honoring
    /// the `profile-<id>.json` naming contract with a matching stored id are
    /// returned. Used to offer cached profiles in the picker when the server
    /// cannot be reached at all.
    public func allEntries() -> [CachedProfileColors] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .compactMap { url in
                guard let id = Self.profileID(fromFileURL: url),
                      let entry = entry(at: url), entry.profileID == id else { return nil }
                return entry
            }
            .sorted { $0.profileID < $1.profileID }
    }

    // MARK: - Writes

    /// Stores (or overwrites) the cached fetch for `entry.profileID`.
    public func store(_ entry: CachedProfileColors) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(entry).write(to: fileURL(for: entry.profileID), options: .atomic)
    }

    /// Removes every cached profile. A missing cache directory is a no-op.
    public func removeAll() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    private static let fileStemPrefix = "profile-"

    private func fileURL(for profileID: Int) -> URL {
        directory.appendingPathComponent("\(Self.fileStemPrefix)\(profileID).json")
    }

    /// The `<id>` in a cache file named `profile-<id>.json`, if it parses.
    private static func profileID(fromFileURL url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", stem.hasPrefix(fileStemPrefix) else { return nil }
        return Int(stem.dropFirst(fileStemPrefix.count))
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
