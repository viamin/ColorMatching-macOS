import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Migration contract for adopting the generated OpenAPI client (issue #39).
///
/// Two layers:
///
/// 1. **Generated-client artifacts** — `swift-openapi-generator` +
///    `swift-openapi-runtime` declared in `ColorComposerCore/Package.swift`
///    and the OpenAPI document committed at
///    `Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}` describing
///    the consumed `/api/v1` operations. These tests are red until the
///    migration lands and define the canonical layout the implementation must
///    follow (documented in `docs/solver-parity-corpus.md`).
///
/// 2. **Behavior preservation** — the `/api/v1` wire shapes (from the
///    published `color_matching` OpenAPI 3 spec, viamin/color_matching#113)
///    and the exact requests `PaletteAPIClient` issues today. Whatever the
///    migration generates must keep these decoding and request shapes intact
///    so the disk cache and offline fallback keep working against both old
///    cache files and live servers.
final class OpenAPIClientMigrationTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ColorComposerCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // ColorComposerCore/

    private static var openAPIDocumentURL: URL? {
        let directory = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
        return ["openapi.yaml", "openapi.yml", "openapi.json"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    override func tearDown() {
        super.tearDown()
        MigrationMockURLProtocol.handler = nil
    }

    // MARK: - Generated-client artifacts (issue #39 deliverable 1)

    func testPackageDeclaresSwiftOpenAIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-generator plugin dependency (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-runtime dependency (issue #39)"
        )
    }

    func testOpenAPIDocumentIsCommittedForClientGeneration() throws {
        let documentURL = try XCTUnwrap(
            Self.openAPIDocumentURL,
            "commit the /api/v1 OpenAPI document at ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json} (issue #39)"
        )

        let data = try Data(contentsOf: documentURL)
        XCTAssertGreaterThan(data.count, 0, "the committed OpenAPI document must not be empty")

        if documentURL.pathExtension == "json" {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: data),
                "the committed OpenAPI document must be valid JSON"
            )
        }
    }

    func testOpenAPIDocumentDescribesTheConsumedAPIv1Operations() throws {
        let documentURL = try XCTUnwrap(
            Self.openAPIDocumentURL,
            "commit the /api/v1 OpenAPI document at ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json} (issue #39)"
        )
        let document = try String(contentsOf: documentURL, encoding: .utf8)

        XCTAssertTrue(
            document.contains("printer_profiles"),
            "the OpenAPI document must describe GET /api/v1/printer_profiles — PaletteAPIClient consumes it"
        )
        XCTAssertTrue(
            document.contains("colors"),
            "the OpenAPI document must describe GET /api/v1/colors — PaletteAPIClient consumes it"
        )
    }

    // MARK: - /api/v1 wire shapes from the published OpenAPI spec

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Per the spec (ApiSchemas.ColorsResponse), `rgb` is optional and the
    /// controller emits `"rgb": null` when a stored hex cannot parse, and
    /// `palette_name` is explicitly nullable. The client DTOs must keep
    /// decoding both spellings — including from cache files written by older
    /// builds.
    func testColorsEnvelopeDecodesNullableRGBAndPaletteName() throws {
        let json = """
        {
          "printer_profile": {
            "id": 4, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 9, "name": "Unparseable Swatch", "hex": "#zzzzzz",
              "rgb": null,
              "palette_id": 2, "palette_name": null, "sort_order": 0,
              "responses": {
                "lps": {
                  "brightness": 0.25, "source": "measurement",
                  "raw_value": 41.7, "raw_unit": "cd/m²",
                  "apparent_brightness": null,
                  "measured_at": "2026-01-02T03:04:05.123456Z",
                  "test_run_id": "run-42"
                }
              }
            }
          ]
        }
        """
        let envelope = try decode(json, as: ColorsResponse.self)

        XCTAssertEqual(envelope.printerProfile?.id, 4)
        let color = try XCTUnwrap(envelope.colors.first)
        XCTAssertNil(color.rgb)
        XCTAssertNil(color.paletteName)
        XCTAssertEqual(color.responses["lps"]?.rawValue, 41.7)
        XCTAssertEqual(color.responses["lps"]?.rawUnit, "cd/m²")
        XCTAssertEqual(color.responses["lps"]?.measuredAt, "2026-01-02T03:04:05.123456Z")
        XCTAssertEqual(color.responses["lps"]?.testRunId, "run-42")
    }

    /// Per the spec (ApiSchemas.PrinterProfile), a profile carries `id` plus
    /// the three required non-nullable strings; the envelope always wraps them
    /// in a `printer_profiles` array.
    func testPrinterProfilesEnvelopeDecodesSpecRequiredProfileFields() throws {
        let json = """
        {
          "printer_profiles": [
            {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Pigment"},
            {"id": 2, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Dye"}
          ]
        }
        """
        let envelope = try decode(json, as: PrinterProfilesResponse.self)

        XCTAssertEqual(envelope.printerProfiles.map(\.id), [1, 2])
        XCTAssertEqual(envelope.printerProfiles.last?.paperType, "Glossy")
    }

    // MARK: - Request shapes PaletteAPIClient issues today (must survive the migration)

    func testFetchColorsRequestsAPIv1ColorsWithProfileIDQueryAndHeaders() async throws {
        MigrationMockURLProtocol.handler = { _ in
            (.init(statusCode: 200), Data("{\"colors\":[],\"printer_profile\":null}".utf8))
        }
        let client = makeClient()

        _ = try await client.fetchColors(printerProfileID: 3)

        let request = try XCTUnwrap(MigrationMockURLProtocol.takeRecordedRequests().first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/colors")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "printer_profile_id" }?.value,
            "3"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer parity-token")
    }

    func testFetchPrinterProfilesRequestsTheAPIv1Path() async throws {
        MigrationMockURLProtocol.handler = { _ in
            (.init(statusCode: 200), Data("{\"printer_profiles\":[]}".utf8))
        }
        let client = makeClient()

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(MigrationMockURLProtocol.takeRecordedRequests().first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    private func makeClient() -> PaletteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://parity.example.com")!,
            token: "parity-token",
            session: URLSession(configuration: configuration)
        )
    }
}

/// Recording URL protocol — mirrors the mock in `PaletteAPIClientTests`, plus
/// a request log so migration tests can pin the exact requests issued.
private final class MigrationMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func takeRecordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        lock.lock()
        recordedRequests = []
        recordedRequests.append(request)
        let handler = Self.handler
        lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension HTTPURLResponse {
    convenience init(statusCode: Int) {
        self.init(
            url: URL(string: "http://parity.example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
