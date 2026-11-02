import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Issue #39 — adoption of the generated OpenAPI client
/// (viamin/color_matching#110, merged as #113).
///
/// Two layers of enforcement:
///
/// 1. **Structural adoption (red until implemented).** The package must
///    declare `swift-openapi-generator` + `swift-openapi-runtime`, commit an
///    OpenAPI document covering the two `/api/v1` paths this app consumes,
///    and expose the generated `PaletteOpenAPI` module — the layout prescribed
///    in `docs/openapi-client-migration.md`. These tests fail until the
///    migration lands (expected in the tests-only red phase).
///
/// 2. **Wire-contract preservation (green before AND after migration).**
///    `PaletteAPIClient` — whether reimplemented on the generated client or
///    wrapping it — must keep issuing the same requests (paths, query,
///    bearer auth, `Accept: application/json`) and decoding the same
///    snake_case envelopes into the same DTOs. The migration must not change
///    observable behavior: per-server/profile color caching, offline-stale
///    badges, and cached profile fallback all sit on top of this contract
///    (see `ProfileColorCacheTests`).
final class OpenAPIClientMigrationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - Package layout (red until swift-openapi-generator is adopted)

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ColorComposerCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // ColorComposerCore/

    private static let openAPIDocumentCandidates: [String] = [
        "Sources/PaletteOpenAPI/openapi.yaml",
        "Sources/PaletteOpenAPI/openapi.yml",
        "Sources/PaletteOpenAPI/openapi.json",
        "openapi.yaml",
        "openapi.yml",
        "openapi.json",
    ]

    /// The package manifest must declare the generator plugin and the runtime
    /// library (issue #39 deliverable 1).
    func testPackageDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must add swift-openapi-generator (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must add swift-openapi-runtime (issue #39)"
        )
    }

    /// A committed OpenAPI document must exist and must describe both `/api/v1`
    /// endpoints `PaletteAPIClient` consumes — the document is the input to
    /// `swift-openapi-generator`, not decoration.
    func testOpenAPIDocumentCoversConsumedAPIv1Endpoints() throws {
        let documentURL = Self.openAPIDocumentCandidates.first { candidate in
            FileManager.default.fileExists(atPath: Self.packageRoot.appendingPathComponent(candidate).path)
        }.map { Self.packageRoot.appendingPathComponent($0) }

        let path = try XCTUnwrap(
            documentURL,
            "No OpenAPI document found under ColorComposerCore/ (looked in: "
                + Self.openAPIDocumentCandidates.joined(separator: ", ")
                + "). See docs/openapi-client-migration.md"
        )
        let document = try String(contentsOf: path, encoding: .utf8)

        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "The OpenAPI document must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "The OpenAPI document must describe GET /api/v1/colors"
        )
    }

    /// The generated client module must exist and be importable from the test
    /// target. The prescribed layout (docs/openapi-client-migration.md) is a
    /// `PaletteOpenAPI` target whose sources directory carries the OpenAPI
    /// document and the `openapi-generator-config.yaml` that drives the
    /// plugin.
    func testGeneratedClientTargetCarriesOpenAPIGeneratorConfig() throws {
        let configURL = Self.packageRoot
            .appendingPathComponent("Sources/PaletteOpenAPI/openapi-generator-config.yaml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: configURL.path),
            "Missing Sources/PaletteOpenAPI/openapi-generator-config.yaml — the generated-client target is not wired up (issue #39)"
        )
    }

    #if canImport(PaletteOpenAPI)
    /// Once adopted, the generated module must expose the typed `Client`
    /// entry point from swift-openapi-runtime. Behavioral coverage of the
    /// endpoints runs through `PaletteAPIClient` below, which must sit on top
    /// of (or wrap) this client after migration.
    func testGeneratedModuleExposesTypedClient() {
        _ = PaletteOpenAPI.Client.self
    }
    #else
    /// Red-phase marker: fails exactly until the generated client exists.
    func testGeneratedClientModuleIsAdopted() {
        XCTFail(
            "PaletteOpenAPI module not found — swift-openapi-generator has not been adopted yet "
                + "(issue #39; layout prescribed in docs/openapi-client-migration.md)"
        )
    }
    #endif

    // MARK: - Wire contract (must not change across the migration)

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: " t0ken ",
            session: session
        )
    }

    func testFetchColorsRequestShapeAndEnvelopeDecoding() async throws {
        let lock = NSLock()
        var capturedRequest: URLRequest?
        let client = makeClient { request in
            lock.lock()
            capturedRequest = request
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(capturedRequest)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/colors")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        XCTAssertEqual(query?["printer_profile_id"], "7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].id, 123)
        XCTAssertEqual(colors[0].hex, "#C64A35")
        XCTAssertEqual(colors[0].responses["red"]?.brightness ?? -1, 0.87, accuracy: 1e-12)
        XCTAssertEqual(profile?.id, 1)
        XCTAssertEqual(profile?.printerMakeModel, "Epson")
    }

    func testFetchPrinterProfilesRequestShapeAndEnvelopeDecoding() async throws {
        let lock = NSLock()
        var capturedRequest: URLRequest?
        let client = makeClient { request in
            lock.lock()
            capturedRequest = request
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        let url = try XCTUnwrap(try XCTUnwrap(capturedRequest).url)
        XCTAssertEqual(url.path, "/api/v1/printer_profiles")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Dye")
    }

    func testNon2xxMapsToBadStatusAndGarbageBodyToMalformedResponse() async {
        let badStatusClient = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await badStatusClient.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }

        let malformedClient = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }
        await XCTAssertThrowsErrorAsync(try await malformedClient.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Fixtures (mirror the /api/v1 wire shapes the server's OpenAPI
    // spec declares — see docs/openapi-client-migration.md for the diff notes)

    private static func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 1,
              "printer_make_model": "Example Printer",
              "paper_type": "Matte",
              "ink_type": "Dye"
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
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
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ assertions: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        assertions(error)
    }
}
