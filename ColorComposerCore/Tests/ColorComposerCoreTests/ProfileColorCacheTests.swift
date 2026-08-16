import XCTest
@testable import ColorComposerCore

private let defaultServer = "http://localhost:4000"

final class ProfileColorCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileColorCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeColor(id: Int) throws -> PaletteColorDTO {
        let json = "{\"id\":\(id),\"name\":\"Color \(id)\",\"hex\":\"#112233\","
            + "\"rgb\":{\"r\":17,\"g\":34,\"b\":51},"
            + "\"responses\":{\"red\":{\"brightness\":0.5}}}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }

    /// A color that decodes from the wire but cannot convert for the solver:
    /// no `rgb` and a hex no color parses from.
    private func makeUnconvertibleColor(id: Int) throws -> PaletteColorDTO {
        let json = "{\"id\":\(id),\"hex\":\"not-a-color\",\"responses\":{}}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }

    private func makeEntry(
        profileID: Int,
        colorIDs: [Int] = [1],
        serverBaseUrl: String = defaultServer,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> CachedProfileColors {
        CachedProfileColors(
            serverBaseUrl: serverBaseUrl,
            profileId: profileID,
            profile: PrinterProfileDTO(
                id: profileID, printerMakeModel: "Epson", paperType: "Matte", inkType: "Dye"
            ),
            colors: try colorIDs.map { try makeColor(id: $0) },
            fetchedAt: fetchedAt
        )
    }

    private func serverDirectory(for serverBaseUrl: String = defaultServer) -> URL {
        let safe = Data(serverBaseUrl.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("server-\(safe)", isDirectory: true)
    }

    func testStoreThenReadRoundTripsEntry() throws {
        let cache = ProfileColorCache(directory: directory)
        let entry = try makeEntry(profileID: 2, colorIDs: [10, 11])

        try cache.store(entry)

        XCTAssertEqual(cache.entry(for: 2, serverBaseUrl: defaultServer), entry)
    }

    /// An empty fetch is still cached and survives the disk round-trip: it
    /// reads back as an entry whose `domainColors` are empty — nothing to
    /// serve offline, so the failure path reports the miss plainly instead of
    /// badging an empty palette as cached colors.
    func testEmptyCachedFetchSurvivesDiskRoundTrip() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 8, colorIDs: []))

        let entry = try XCTUnwrap(cache.entry(for: 8, serverBaseUrl: defaultServer))

        XCTAssertTrue(entry.colors.isEmpty)
        XCTAssertTrue(entry.domainColors.isEmpty)
    }

    func testEntryForUncachedProfileIsNil() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        XCTAssertNil(cache.entry(for: 99, serverBaseUrl: defaultServer))
    }

    func testEntryForMissingDirectoryIsNil() {
        let cache = ProfileColorCache(directory: directory)

        XCTAssertNil(cache.entry(for: 1, serverBaseUrl: defaultServer))
    }

    func testStoreOverwritesPreviousFetch() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, colorIDs: [1], fetchedAt: Date(timeIntervalSince1970: 100)))
        let refreshed = try makeEntry(profileID: 3, colorIDs: [1, 2], fetchedAt: Date(timeIntervalSince1970: 200))

        try cache.store(refreshed)

        XCTAssertEqual(cache.entry(for: 3, serverBaseUrl: defaultServer), refreshed)
    }

    // MARK: Server scoping

    func testEntryFromAnotherServerCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://one.example:4000"))

        XCTAssertEqual(cache.entry(for: 3, serverBaseUrl: "http://one.example:4000")?.profileId, 3)
        XCTAssertNil(cache.entry(for: 3, serverBaseUrl: "http://two.example:4000"))
    }

    func testAllEntriesOnlyReturnsTheRequestingServersEntries() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1, serverBaseUrl: "http://one.example:4000"))
        try cache.store(try makeEntry(profileID: 2, serverBaseUrl: "http://two.example:4000"))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://one.example:4000").map(\.profileId), [1])
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://two.example:4000").map(\.profileId), [2])
    }

    func testTwoServersKeepSeparateEntriesForTheSameProfileID() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://one.example:4000"))
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://two.example:4000"))

        XCTAssertEqual(
            cache.entry(for: 3, serverBaseUrl: "http://one.example:4000")?.serverBaseUrl,
            "http://one.example:4000"
        )
        XCTAssertEqual(
            cache.entry(for: 3, serverBaseUrl: "http://two.example:4000")?.serverBaseUrl,
            "http://two.example:4000"
        )
    }

    func testTrailingSlashAndHostCaseUseTheSameCacheNamespace() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://LOCALHOST:4000/"))

        XCTAssertEqual(
            cache.entry(for: 3, serverBaseUrl: "http://localhost:4000")?.serverBaseUrl,
            "http://localhost:4000"
        )
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://localhost:4000/").map(\.profileId), [3])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testDefaultPortAndSchemeCaseUseTheSameCacheNamespace() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "HTTP://localhost:80/"))

        XCTAssertEqual(
            cache.entry(for: 3, serverBaseUrl: "http://localhost")?.serverBaseUrl,
            "http://localhost"
        )
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://localhost:80").map(\.profileId), [3])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testOnlyTrailingSlashesUseTheSameCacheNamespace() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 5, serverBaseUrl: "http://localhost:4000////"))

        XCTAssertEqual(
            cache.entry(for: 5, serverBaseUrl: "http://localhost:4000")?.serverBaseUrl,
            "http://localhost:4000"
        )
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://localhost:4000/").map(\.profileId), [5])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testLeadingAndInternalPathSlashesKeepDistinctCacheNamespaces() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 5, serverBaseUrl: "http://localhost:4000//colors"))

        XCTAssertEqual(
            cache.entry(for: 5, serverBaseUrl: "http://localhost:4000//colors")?.serverBaseUrl,
            "http://localhost:4000//colors"
        )
        XCTAssertNil(cache.entry(for: 5, serverBaseUrl: "http://localhost:4000/colors"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testQueryAndFragmentUseTheSameCacheNamespace() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 4, serverBaseUrl: "http://localhost:4000/colors?token=abc#frag"))

        XCTAssertEqual(
            cache.entry(for: 4, serverBaseUrl: "http://localhost:4000/colors")?.serverBaseUrl,
            "http://localhost:4000/colors"
        )
        XCTAssertEqual(
            cache.allEntries(serverBaseUrl: "http://localhost:4000/colors?other=def").map(\.profileId),
            [4]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testUserInfoUsesTheSameCacheNamespaceAndIsNotStored() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 4, serverBaseUrl: "http://user:secret@LOCALHOST:4000/colors/"))

        let entry = try XCTUnwrap(cache.entry(for: 4, serverBaseUrl: "http://localhost:4000/colors"))

        XCTAssertEqual(entry.serverBaseUrl, "http://localhost:4000/colors")
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://other:creds@localhost:4000/colors").map(\.profileId), [4])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 1)
    }

    func testStoreCreatesSeparateServerDirectories() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://one.example:4000"))
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://two.example:4000"))

        let directories = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(directories.count, 2)
        XCTAssertTrue(directories.allSatisfy(\.hasDirectoryPath))
    }

    // MARK: Corrupt and foreign files

    func testCorruptCacheFileCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        let serverDirectory = serverDirectory()
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: serverDirectory.appendingPathComponent("profile-5.json"))

        XCTAssertNil(cache.entry(for: 5, serverBaseUrl: defaultServer))
    }

    func testEntryWhoseStoredIDDisagreesWithFilenameCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        let serverDirectory = serverDirectory()
        try FileManager.default.moveItem(
            at: serverDirectory.appendingPathComponent("profile-3.json"),
            to: serverDirectory.appendingPathComponent("profile-5.json")
        )

        XCTAssertNil(cache.entry(for: 5, serverBaseUrl: defaultServer))
    }

    func testAllEntriesSkipsCorruptFilesAndSortsByProfile() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try cache.store(try makeEntry(profileID: 1))
        try cache.store(try makeEntry(profileID: 2))
        let serverDirectory = serverDirectory()
        try Data("not json".utf8)
            .write(to: serverDirectory.appendingPathComponent("profile-9.json"))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [1, 2, 3])
    }

    func testAllEntriesSkipsEntriesWhoseStoredIDDisagreesWithFilename() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        let serverDirectory = serverDirectory()
        try FileManager.default.moveItem(
            at: serverDirectory.appendingPathComponent("profile-3.json"),
            to: serverDirectory.appendingPathComponent("profile-5.json")
        )
        try cache.store(try makeEntry(profileID: 2))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [2])
    }

    func testAllEntriesIgnoresFilesOutsideTheNamingContract() throws {
        let cache = ProfileColorCache(directory: directory)
        let serverDirectory = serverDirectory()
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try cache.store(try makeEntry(profileID: 1))
        for foreign in ["notes.txt", "profile-abc.json", ".DS_Store"] {
            try Data("not json".utf8).write(to: serverDirectory.appendingPathComponent(foreign))
        }

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [1])
    }

    func testAllEntriesIncludesEntriesWithoutProfileMetadata() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 4))
        try cache.store(CachedProfileColors(
            serverBaseUrl: defaultServer,
            profileId: 7,
            profile: nil,
            colors: [try makeColor(id: 1)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [4, 7])
        XCTAssertNil(cache.entry(for: 7, serverBaseUrl: defaultServer)?.profile)
    }

    func testAllEntriesIsEmptyWithoutDirectory() {
        let cache = ProfileColorCache(directory: directory)

        XCTAssertTrue(cache.allEntries(serverBaseUrl: defaultServer).isEmpty)
    }

    // MARK: Clearing

    func testRemoveAllClearsEveryProfile() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))
        try cache.store(try makeEntry(profileID: 2))

        try cache.removeAll()

        XCTAssertNil(cache.entry(for: 1, serverBaseUrl: defaultServer))
        XCTAssertNil(cache.entry(for: 2, serverBaseUrl: defaultServer))
        XCTAssertTrue(cache.allEntries(serverBaseUrl: defaultServer).isEmpty)
    }

    func testRemoveAllSucceedsWhenNothingIsCached() throws {
        let cache = ProfileColorCache(directory: directory)

        XCTAssertNoThrow(try cache.removeAll())
    }

    /// Clear Cache followed by a later successful fetch must be able to
    /// repopulate the cache: `removeAll` deletes the directory, so `store`
    /// has to recreate it.
    func testStoreRecreatesDirectoryAfterRemoveAll() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        try cache.removeAll()
        try cache.store(try makeEntry(profileID: 1))

        XCTAssertEqual(cache.entry(for: 1, serverBaseUrl: defaultServer)?.profileId, 1)
    }

    // MARK: Domain colors

    func testDomainColorsConvertRoundTrippedDTOs() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1, colorIDs: [7, 8]))

        let entry = try XCTUnwrap(cache.entry(for: 1, serverBaseUrl: defaultServer))

        XCTAssertEqual(entry.domainColors.map(\.id), [7, 8])
        XCTAssertTrue(entry.hasServableColors)
    }

    func testHasServableColorsIsFalseWhenNoCachedColorConverts() throws {
        let entry = CachedProfileColors(
            serverBaseUrl: defaultServer,
            profileId: 6,
            profile: PrinterProfileDTO(
                id: 6, printerMakeModel: "Epson", paperType: "Matte", inkType: "Dye"
            ),
            colors: [try makeUnconvertibleColor(id: 99)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(entry.domainColors.isEmpty)
        XCTAssertFalse(entry.hasServableColors)
    }

    /// A fetch that returned no colors still gets cached; its entry has
    /// nothing to serve offline and must be distinguishable from a usable one.
    func testDomainColorsIsEmptyForAnEmptyCachedFetch() throws {
        let entry = try makeEntry(profileID: 1, colorIDs: [])

        XCTAssertTrue(entry.domainColors.isEmpty)
    }

    func testDomainColorsIsEmptyWhenEveryDTOFailsConversion() throws {
        let entry = CachedProfileColors(
            serverBaseUrl: defaultServer,
            profileId: 1,
            profile: nil,
            colors: [try makeUnconvertibleColor(id: 1), try makeUnconvertibleColor(id: 2)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(entry.domainColors.isEmpty)
    }

    // MARK: On-disk format

    func testStoredFileUsesSnakeCaseWireKeys() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        let serverDirectory = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first)
        let data = try Data(contentsOf: serverDirectory.appendingPathComponent("profile-1.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["profile_id"])
        XCTAssertNotNil(object["server_base_url"])
        XCTAssertNotNil(object["fetched_at"])
    }

    /// Pins the on-disk format: a hand-written snake_case cache file must
    /// decode. This is the guard against CodingKey/strategy drift (e.g. an
    /// auto-generated key like `profileID` that the snake-case round-trip
    /// never matches), where every stored entry would silently count as a miss.
    func testDecodesHandWrittenSnakeCaseCacheFile() throws {
        let cache = ProfileColorCache(directory: directory)
        let serverDirectory = serverDirectory()
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        let json = """
            {"server_base_url":"http://localhost:4000",
            "profile_id":6,
            "profile":{"id":6,"printer_make_model":"Canon","paper_type":"Glossy","ink_type":"Pigment"},
            "colors":[{"id":1,"name":"Color 1","hex":"#112233","rgb":{"r":17,"g":34,"b":51},
            "responses":{"red":{"brightness":0.5}}}],
            "fetched_at":"2023-11-14T22:13:20Z"}
            """
        try Data(json.utf8).write(to: serverDirectory.appendingPathComponent("profile-6.json"))

        let entry = try XCTUnwrap(cache.entry(for: 6, serverBaseUrl: "http://localhost:4000"))

        XCTAssertEqual(entry.serverBaseUrl, "http://localhost:4000")
        XCTAssertEqual(entry.profileId, 6)
        XCTAssertEqual(entry.profile?.printerMakeModel, "Canon")
        XCTAssertEqual(entry.colors.map(\.id), [1])
        XCTAssertEqual(entry.fetchedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
