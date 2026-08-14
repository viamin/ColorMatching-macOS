import XCTest
@testable import ColorComposerCore

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
        fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> CachedProfileColors {
        CachedProfileColors(
            profileID: profileID,
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

        XCTAssertEqual(cache.entry(for: 2), entry)
    }

    func testEntryForUncachedProfileIsNil() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        XCTAssertNil(cache.entry(for: 99))
    }

    func testStoreOverwritesPreviousFetch() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3, colorIDs: [1], fetchedAt: Date(timeIntervalSince1970: 100)))
        let refreshed = try makeEntry(profileID: 3, colorIDs: [1, 2], fetchedAt: Date(timeIntervalSince1970: 200))

        try cache.store(refreshed)

        XCTAssertEqual(cache.entry(for: 3), refreshed)
    }

    func testCorruptCacheFileCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("profile-5.json"))

        XCTAssertNil(cache.entry(for: 5))
    }

    func testEntryWhoseStoredIDDisagreesWithFilenameCountsAsMiss() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("profile-3.json"),
            to: directory.appendingPathComponent("profile-5.json")
        )

        XCTAssertNil(cache.entry(for: 5))
    }

    func testAllEntriesSkipsCorruptFilesAndSortsByProfile() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try cache.store(try makeEntry(profileID: 1))
        try cache.store(try makeEntry(profileID: 2))
        try Data("not json".utf8)
            .write(to: directory.appendingPathComponent("profile-9.json"))

        XCTAssertEqual(cache.allEntries().map(\.profileID), [1, 2, 3])
    }

    func testAllEntriesSkipsEntriesWhoseStoredIDDisagreesWithFilename() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 3))
        try FileManager.default.moveItem(
            at: directory.appendingPathComponent("profile-3.json"),
            to: directory.appendingPathComponent("profile-5.json")
        )
        try cache.store(try makeEntry(profileID: 2))

        XCTAssertEqual(cache.allEntries().map(\.profileID), [2])
    }

    func testAllEntriesIgnoresFilesOutsideTheNamingContract() throws {
        let cache = ProfileColorCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cache.store(try makeEntry(profileID: 1))
        for foreign in ["notes.txt", "profile-abc.json", ".DS_Store"] {
            try Data("not json".utf8).write(to: directory.appendingPathComponent(foreign))
        }

        XCTAssertEqual(cache.allEntries().map(\.profileID), [1])
    }

    func testAllEntriesIncludesEntriesWithoutProfileMetadata() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 4))
        try cache.store(CachedProfileColors(
            profileID: 7,
            profile: nil,
            colors: [try makeColor(id: 1)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        XCTAssertEqual(cache.allEntries().map(\.profileID), [4, 7])
        XCTAssertNil(cache.entry(for: 7)?.profile)
    }

    func testAllEntriesIsEmptyWithoutDirectory() {
        let cache = ProfileColorCache(directory: directory)

        XCTAssertTrue(cache.allEntries().isEmpty)
    }

    func testRemoveAllClearsEveryProfile() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))
        try cache.store(try makeEntry(profileID: 2))

        try cache.removeAll()

        XCTAssertNil(cache.entry(for: 1))
        XCTAssertNil(cache.entry(for: 2))
        XCTAssertTrue(cache.allEntries().isEmpty)
    }

    func testRemoveAllSucceedsWhenNothingIsCached() throws {
        let cache = ProfileColorCache(directory: directory)

        XCTAssertNoThrow(try cache.removeAll())
    }

    func testStoredFileUsesSnakeCaseWireKeys() throws {
        let cache = ProfileColorCache(directory: directory)
        try cache.store(try makeEntry(profileID: 1))

        let data = try Data(contentsOf: directory.appendingPathComponent("profile-1.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["profile_id"])
        XCTAssertNotNil(object["fetched_at"])
    }
}
