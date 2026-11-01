import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Characterization tests pinning the observable HTTP/JSON contract between
/// `PaletteAPIClient` and the `color_matching` `/api/v1` API, as published in
/// the server's OpenAPI 3 spec (viamin/color_matching#113).
///
/// These fixtures and assertions are the acceptance gate for migrating the
/// client onto the generated `swift-openapi-runtime` client (issue #39): the
/// migration may change transport plumbing but must keep every behavior
/// verified here — endpoint URLs, headers, bearer-token handling, typed
/// status errors, and decoding of the published wire shapes — plus the
/// disk-cache/offline behavior covered by `ProfileColorCacheTests`.
final class PaletteAPIClientContractTests: XCTestCase {
    private let baseURL = URL(string: "http://api.example:4000")!

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - Request wire contract

    func testFetchPrinterProfilesHitsVersionedEndpointWithJSONAccept() async throws {
        let request = try await captureRequest {
            _ = try await makeClient().fetchPrinterProfiles()
        }

        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchColorsHitsVersionedEndpointWithProfileQuery() async throws {
        let request = try await captureRequest(body: Data("""
        {"printer_profile": null, "colors": []}
        """.utf8)) {
            _ = try await makeClient().fetchColors(printerProfileID: 42)
        }

        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let query = request.url?.query?.split(separator: "&").map(String.init).sorted()
        XCTAssertEqual(query, ["printer_profile_id=42"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testTestConnectionProbesPrinterProfilesEndpoint() async throws {
        let request = try await captureRequest {
            try await makeClient().testConnection()
        }

        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
    }

    // MARK: - Bearer token contract (spec securityScheme: bearerAuth)

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let request = try await captureRequest {
            _ = try await makeClient(token: nil).fetchPrinterProfiles()
        }

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testBlankTokenSendsNoAuthorizationHeader() async throws {
        let request = try await captureRequest {
            _ = try await makeClient(token: "   ").fetchPrinterProfiles()
        }

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Typed status errors

    func testNon2xxStatusMapsToBadStatus() async throws {
        MockURLProtocol.handler = { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(
            try await makeClient(token: nil).fetchColors(printerProfileID: 1)
        ) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testMalformedBodyMapsToMalformedResponse() async throws {
        MockURLProtocol.handler = { request in
            (.init(statusCode: 200, url: request.url!), Data("{\"unexpected\": true}".utf8))
        }
        await XCTAssertThrowsErrorAsync(
            try await makeClient(token: nil).fetchPrinterProfiles()
        ) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionAcceptsAny2xx() async throws {
        MockURLProtocol.handler = { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }
        try await makeClient(token: nil).testConnection()
    }

    func testTestConnectionRejectsNon2xxWithBadStatus() async throws {
        MockURLProtocol.handler = { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(
            try await makeClient(token: nil).testConnection()
        ) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    // MARK: - Published OpenAPI response shapes

    /// The committed fixtures must keep satisfying the required-field lists of
    /// the published schemas (`PrinterProfilesResponse`, `ColorsResponse`),
    /// so a hand-edit cannot silently weaken what the client is pinned to
    /// decode.
    func testFixturesSatisfyPublishedRequiredFields() throws {
        try assertRequiredFields(
            fixture: "printer_profiles.response.json",
            envelopeKey: "printer_profiles",
            requiredItemFields: ["id", "printer_make_model", "paper_type", "ink_type"]
        )
        try assertRequiredFields(
            fixture: "colors.response.json",
            envelopeKey: "colors",
            requiredItemFields: ["id", "name", "hex", "palette_id", "sort_order", "responses"]
        )
    }

    func testFetchPrinterProfilesDecodesPublishedEnvelope() async throws {
        MockURLProtocol.handler = responseStub(try fixtureData("printer_profiles.response.json"))

        let profiles = try await makeClient(token: nil).fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [3, 7])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson SureColor P700")
        XCTAssertEqual(profiles.first?.paperType, "Premium Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
        XCTAssertEqual(profiles.last?.printerMakeModel, "Canon PRO-300")
    }

    func testFetchColorsDecodesPublishedEnvelopeAndDomainModel() async throws {
        MockURLProtocol.handler = responseStub(try fixtureData("colors.response.json"))

        let (colors, profile) = try await makeClient(token: nil).fetchColors(printerProfileID: 3)

        // ColorsResponse.printer_profile is required by the published spec.
        XCTAssertEqual(profile?.id, 3)
        XCTAssertEqual(profile?.paperType, "Premium Matte")

        XCTAssertEqual(colors.map(\.id), [101, 102, 103])

        let measured = try XCTUnwrap(colors.first).toDomain()
        XCTAssertEqual(measured?.brightness(for: .white), 0.375)
        XCTAssertEqual(measured?.brightness(for: .red), 0.5)
        XCTAssertEqual(measured?.rgb, RGBColor(red: 160, green: 82, blue: 45))
        XCTAssertEqual(measured?.paletteName, "Earth Tones")

        // The spec leaves `responses` untyped (additionalProperties), so the
        // client keeps dropping light sources outside its canonical set.
        let withUnknownSource = colors[1].toDomain()
        XCTAssertEqual(withUnknownSource?.brightness(for: .lps), 0.5)
        XCTAssertEqual(withUnknownSource?.brightness(for: .white), 0.5)
        XCTAssertEqual(withUnknownSource?.responses.count, 5, "ultraviolet must be dropped at conversion")
        XCTAssertNil(colors[1].paletteName)

        // rgb is optional per the spec; hex remains the fallback.
        let hexFallback = colors[2].toDomain()
        XCTAssertEqual(hexFallback?.rgb, RGBColor(hex: "#112233"))
        XCTAssertEqual(hexFallback?.brightness(for: .red), 0.0625)
        XCTAssertNil(hexFallback?.brightness(for: .white))
    }

    // MARK: - Helpers

    private func makeClient(token: String? = nil) -> PaletteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(baseURL: baseURL, token: token, session: URLSession(configuration: configuration))
    }

    private func responseStub(_ data: Data) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in (.init(statusCode: 200, url: request.url!), data) }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI/\(name)")
        return try Data(contentsOf: url)
    }

    /// Runs `operation` against a client whose transport records the single
    /// outgoing request and returns a minimal 200 response.
    private func captureRequest(
        body: Data = Data("{\"printer_profiles\": []}".utf8),
        _ operation: () async throws -> Void
    ) async throws -> URLRequest {
        let lock = NSLock()
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            lock.lock()
            captured = request
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), body)
        }
        try await operation()

        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(captured, "No request was captured")
    }

    private func assertRequiredFields(
        fixture: String,
        envelopeKey: String,
        requiredItemFields: [String]
    ) throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: fixtureData(fixture)) as? [String: Any],
            "\(fixture): root must be a JSON object"
        )
        let items = try XCTUnwrap(object[envelopeKey] as? [[String: Any]], "\(fixture): missing \(envelopeKey) array")
        XCTAssertFalse(items.isEmpty, "\(fixture): fixture must contain at least one item")

        for (index, item) in items.enumerated() {
            for field in requiredItemFields {
                XCTAssertTrue(
                    item[field] != nil,
                    "\(fixture): item \(index) is missing required field \(field)"
                )
            }
        }
    }
}
