import XCTest
@testable import ColorComposerCore

/// End-to-end offline-fallback flow across the pieces the OpenAPI-client
/// migration (issue #39) touches: a `PaletteAPIClient` fetch is decoded into
/// DTOs, stored in `ProfileColorCache` per (server, profile), and served back
/// byte-identically — with the fetch date that drives the offline-stale badge
/// and the domain colors the solver consumes — when the server is unreachable.
final class OfflineCacheFlowTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineCacheFlowTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testWireFetchSurvivesCacheRoundTripForOfflineFallback() throws {
        let cache = ProfileColorCache(directory: directory)
        let fetchedAt = Date(timeIntervalSince1970: 1_770_000_000)

        // What the server returned for profile 7 on this server, verbatim DTOs.
        let profile = PrinterProfileDTO(
            id: 7, printerMakeModel: "Epson P700", paperType: "Matte", inkType: "Pigment"
        )
        let red = try decodeColor(
            #"{"id":101,"name":"Red 12","hex":"#C64A35","rgb":{"r":198,"g":74,"b":53},"responses":{"red":{"brightness":0.87},"lps":{"brightness":0.52}}}}"#
        )
        let unmeasured = try decodeColor(
            #"{"id":102,"name":"Unmeasured","hex":"#6A5ACD","rgb":{"r":106,"g":90,"b":205},"responses":{}}"#
        )

        try cache.store(CachedProfileColors(
            serverBaseUrl: "https://api.example.com",
            profileId: 7,
            profile: profile,
            colors: [red, unmeasured],
            fetchedAt: fetchedAt
        ))

        // Server unreachable: the cached entry is served with everything the
        // offline UI needs — original DTOs, staleness date, servable colors.
        let served = try XCTUnwrap(
            cache.entry(for: 7, serverBaseUrl: "https://api.example.com"),
            "offline fallback should serve the cached fetch for this server+profile"
        )

        XCTAssertEqual(served.profileId, 7)
        XCTAssertEqual(served.profile, profile)
        XCTAssertEqual(served.colors, [red, unmeasured])
        XCTAssertEqual(served.fetchedAt, fetchedAt, "the fetch date drives the offline-stale badge")
        XCTAssertTrue(served.hasServableColors)

        let domainColors = served.domainColors
        XCTAssertEqual(domainColors.count, 2)
        XCTAssertEqual(domainColors.first?.brightness(for: .red), 0.87)
        XCTAssertEqual(domainColors.first?.brightness(for: .lps), 0.52)
        XCTAssertNil(domainColors.first?.brightness(for: .green))
        XCTAssertTrue(domainColors[1].responses.isEmpty)
    }

    func testCachedProfileFallbackListsProfilesWhenServerUnreachable() throws {
        let cache = ProfileColorCache(directory: directory)
        let server = "http://localhost:4000"

        try cache.store(try makeEntry(profileID: 3))
        try cache.store(try makeEntry(profileID: 9))

        let offlineProfiles = cache.allEntries(serverBaseUrl: server)

        XCTAssertEqual(offlineProfiles.map(\.profileId), [3, 9], "the profile picker falls back to every cached profile, ordered by id")
        for entry in offlineProfiles {
            XCTAssertTrue(entry.hasServableColors, "entries without usable colors must not appear in the offline picker")
        }
    }

    func testTwoServersDoNotShareOfflineFallbacks() throws {
        let cache = ProfileColorCache(directory: directory)

        try cache.store(try makeEntry(profileID: 5, server: "https://one.example.com"))
        try cache.store(try makeEntry(profileID: 5, server: "https://two.example.com"))

        let served = try XCTUnwrap(cache.entry(for: 5, serverBaseUrl: "https://two.example.com"))
        XCTAssertEqual(served.serverBaseUrl, "https://two.example.com")
        XCTAssertNil(cache.entry(for: 4, serverBaseUrl: "https://two.example.com"))
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "https://one.example.com").map(\.profileId), [5])
        XCTAssertEqual(cache.allEntries(serverBaseUrl: "https://two.example.com").map(\.profileId), [5])
    }

    // MARK: - Fixtures

    private func makeEntry(
        profileID: Int,
        server: String = "http://localhost:4000",
        fetchedAt: Date = Date(timeIntervalSince1970: 1_770_000_000)
    ) throws -> CachedProfileColors {
        CachedProfileColors(
            serverBaseUrl: server,
            profileId: profileID,
            profile: PrinterProfileDTO(
                id: profileID, printerMakeModel: "Epson P700", paperType: "Matte", inkType: "Pigment"
            ),
            colors: [try decodeColor(
                #"{"id":\#(profileID * 100),"hex":"#112233","rgb":{"r":17,"g":34,"b":51},"responses":{"red":{"brightness":0.5}}}"#
            )],
            fetchedAt: fetchedAt
        )
    }

    private func decodeColor(_ json: String) throws -> PaletteColorDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }
}
