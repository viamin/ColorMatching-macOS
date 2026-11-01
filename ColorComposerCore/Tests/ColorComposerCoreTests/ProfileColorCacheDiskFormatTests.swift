import Foundation
import XCTest
@testable import ColorComposerCore

/// Pins the on-disk format of `ProfileColorCache` entries.
///
/// The cache stores the *wire* DTOs exactly as `/api/v1` returned them, so a
/// previous app version's cache files must keep decoding after the generated
/// OpenAPI client replaces the hand-written DTOs (issue #39). These tests
/// write literal bytes — in the exact JSON shape and directory layout earlier
/// versions wrote — and read them back through the public cache API. If a
/// migration changes key spelling, date encoding, or the directory naming
/// contract, offline fallback for every existing user breaks, and these tests
/// say so before that ships.
final class ProfileColorCacheDiskFormatTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileColorCacheDiskFormatTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Literal bytes as written by earlier app versions: snake_case keys,
    /// ISO-8601 `fetched_at`, full response provenance, profile-<id>.json
    /// inside the server-<base64url> directory guarded by the ownership marker.
    private static let legacyEntryJSON = """
    {
      "server_base_url": "http://example.com",
      "profile_id": 7,
      "profile": {
        "id": 7,
        "printer_make_model": "Legacy Printer",
        "paper_type": "Matte",
        "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 71,
          "name": "Legacy Teal",
          "hex": "#00AAFF",
          "rgb": { "r": 0, "g": 170, "b": 255 },
          "palette_id": 4,
          "palette_name": "Legacy Set",
          "sort_order": 1,
          "responses": {
            "white": { "brightness": 0.8, "source": "response", "apparent_brightness": 8 },
            "lps": {
              "brightness": 0.3,
              "source": "measurement",
              "raw_value": 12.5,
              "raw_unit": "cd/m2",
              "measured_at": "2026-01-02T03:04:05Z",
              "test_run_id": "run-1"
            }
          }
        }
      ],
      "fetched_at": "2026-01-15T10:30:00Z"
    }
    """.data(using: .utf8)!

    func testLegacyOnDiskBytesStillDecodeAndConvert() throws {
        try writeLegacyEntry()

        let entry = try XCTUnwrap(ProfileColorCache(directory: root).entry(for: 7, serverBaseUrl: "http://example.com"))

        XCTAssertEqual(entry.profileId, 7)
        XCTAssertEqual(entry.profile?.printerMakeModel, "Legacy Printer")
        XCTAssertEqual(entry.colors.count, 1)
        XCTAssertEqual(
            entry.fetchedAt.timeIntervalSince1970,
            try iso8601("2026-01-15T10:30:00Z").timeIntervalSince1970,
            accuracy: 0.001
        )

        let color = try XCTUnwrap(entry.domainColors.first)
        XCTAssertEqual(color.id, 71)
        XCTAssertEqual(color.brightness(for: .white), 0.8)
        XCTAssertEqual(color.brightness(for: .lps), 0.3)
        XCTAssertTrue(entry.hasServableColors)
    }

    /// An entry a previous version considered empty-of-usable-colors (hex that
    /// parses on no version) must still decode — it is a miss only in the
    /// servability sense, not a corrupt file.
    func testLegacyBytesWithoutConvertibleColorsDecodeButAreNotServable() throws {
        let unservable = """
        {
          "server_base_url": "http://example.com",
          "profile_id": 9,
          "colors": [{ "id": 90, "hex": "not-a-color", "responses": {} }],
          "fetched_at": "2026-01-15T10:30:00Z"
        }
        """.data(using: .utf8)!
        try write(unservable, profileID: 9)

        let entry = try XCTUnwrap(ProfileColorCache(directory: root).entry(for: 9, serverBaseUrl: "http://example.com"))

        XCTAssertTrue(entry.domainColors.isEmpty)
        XCTAssertFalse(entry.hasServableColors)
    }

    /// The same literal bytes under another server's namespace are a miss:
    /// the (server, profile) cache key predates and must survive the migration.
    func testLegacyBytesAreNotServedAcrossServers() throws {
        try writeLegacyEntry()

        XCTAssertNil(ProfileColorCache(directory: root).entry(for: 7, serverBaseUrl: "http://elsewhere.example"))
    }

    // MARK: - Internals

    private func writeLegacyEntry() throws {
        try write(Self.legacyEntryJSON, profileID: 7)
    }

    private func write(_ data: Data, profileID: Int) throws {
        let serverDirectory = try createOwnedServerDirectory()
        try data.write(
            to: serverDirectory.appendingPathComponent("profile-\(profileID).json"),
            options: .atomic
        )
    }

    /// The documented directory layout: `server-<base64url-of-normalized-url>`
    /// carrying the `.profile-color-cache` ownership marker.
    private func createOwnedServerDirectory() throws -> URL {
        let normalized = ProfileColorCache.normalizedServerBaseUrl("http://example.com")
        let safe = Data(normalized.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let serverDirectory = root.appendingPathComponent("server-\(safe)", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try Data().write(to: serverDirectory.appendingPathComponent(".profile-color-cache"))
        return serverDirectory
    }

    private func iso8601(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: string))
    }
}
