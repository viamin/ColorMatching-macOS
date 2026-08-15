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

    func testStoreThenReadRoundTripsEntry() throws {
        let cache = ProfileColorCache(directory: directory)
        let entry = try makeEntry(profileID: 2, colorIDs: [10, 11])

        try cache.store(entry)

        XCTAssertEqual(cache.entry(for: 2, serverBaseUrl: defaultServer), entry)
    }

    func testEntryForUncachedProfileIsNil() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        XCTAssertNil(cache.entry(for: 99, serverBaseUrl: defaultServer))
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

    func testTwoServersShareAProfileFileSoLastStoreWins() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://one.example:4000"))
        try cache.store(try makeEntry(profileID: 3, serverBaseUrl: "http://two.example:4000"))

        XCTAssertEqual(
            cache.entry(for: 3, serverBaseUrl: "http://two.example:4000")?.serverBaseUrl,
            "http://two.example:4000"
        )
        XCTAssertNil(cache.entry(for: 3, serverBaseUrl: "http://one.example:4000"))
    }

    // MARK: Corrupt and foreign files

    func testCorruptCacheFileCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("profile-5.json"))

        XCTAssertNil(cache.entry(for: 5, serverBaseUrl: defaultServer))
    }

    func testEntryWhoseStoredIDDisagreesWithFilenameCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("profile-3.json"),
            to: directory.appendingPathComponent("profile-5.json")
        )

        XCTAssertNil(cache.entry(for: 5, serverBaseUrl: defaultServer))
    }

    func testAllEntriesSkipsCorruptFilesAndSortsByProfile() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try cache.store(try makeEntry(profileID: 1))
        try cache.store(try makeEntry(profileID: 2))
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("profile-9.json"))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [1, 2, 3])
    }

    func testAllEntriesSkipsEntriesWhoseStoredIDDisagreesWithFilename() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("profile-3.json"),
            to: directory.appendingPathComponent("profile-5.json")
        )
        try cache.store(try makeEntry(profileID: 2))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: defaultServer).map(\.profileId), [2])
    }

    func testAllEntriesIgnoresFilesOutsideTheNamingContract() throws {
        let cache = ProfileColorCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cache.store(try makeEntry(profileID: 1))
        for foreign in ["notes.txt", "profile-abc.json", ".DS_Store"] {
            try Data("not json".utf8).write(to: directory.appendingPathComponent(foreign))
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

    // MARK: On-disk format

    func testStoredFileUsesSnakeCaseWireKeys() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        let data = try Data(contentsOf: directory.appendingPathComponent("profile-1.json"))
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
            {"server_base_url":"http://localhost:4000",
            "profile_id":6,
            "profile":{"id":6,"printer_make_model":"Canon","paper_type":"Glossy","ink_type":"Pigment"},
            "colors":[{"id":1,"name":"Color 1","hex":"#112233","rgb":{"r":17,"g":34,"b":51},
            "responses":{"red":{"brightness":0.5}}}],
            "fetched_at":"2023-11-14T22:13:20Z"}
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent("profile-6.json"))

        let entry = try XCTUnwrap(cache.entry(for: 6, serverBaseUrl: "http://localhost:4000"))

        XCTAssertEqual(entry.serverBaseUrl, "http://localhost:4000")
        XCTAssertEqual(entry.profileId, 6)
        XCTAssertEqual(entry.profile?.printerMakeModel, "Canon")
        XCTAssertEqual(entry.colors.map(\.id), [1])
        XCTAssertEqual(entry.fetchedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
