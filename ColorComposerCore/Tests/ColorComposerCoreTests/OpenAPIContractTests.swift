import Foundation
import XCTest

/// Guards the committed OpenAPI document that feeds the generated API client
/// (viamin/color_matching#110 → #39).
///
/// The Elixir service publishes its OpenAPI 3 contract at
/// `GET /api/v1/openapi.json` (OpenApiSpex). This repository commits an
/// exported copy under `ColorComposerCore/OpenAPI/` so `swift-openapi-generator`
/// can build the typed client that `PaletteAPIClient` migrates onto. This test
/// fails while no document is committed (current state) and then keeps
/// guarding that the document documents both `/api/v1` operations the app
/// consumes. Refresh procedure: `docs/generated-openapi-client.md`.
final class OpenAPIContractTests: XCTestCase {
    /// The operations `PaletteAPIClient` consumes today; the generated client
    /// must not regress or rename them.
    private static let consumedOperations = [
        "/api/v1/printer_profiles",
        "/api/v1/colors"
    ]

    func testOpenAPIDocumentIsCommittedAndDocumentsConsumedOperations() throws {
        let searched = candidateDocumentURLs()
        let existing = searched.filter { FileManager.default.fileExists(atPath: $0.path) }

        let document = try XCTUnwrap(
            existing.first,
            """
            No OpenAPI document found. Export the spec from a running color_matching \
            server (GET /api/v1/openapi.json — viamin/color_matching#110) and commit it \
            as ColorComposerCore/OpenAPI/openapi.json so swift-openapi-generator can \
            generate the typed PaletteAPIClient. Searched: \
            \(searched.map { $0.path }.joined(separator: ", "))
            """
        )

        let contents = try String(contentsOf: document, encoding: .utf8)
        for operation in Self.consumedOperations {
            XCTAssertTrue(
                contents.contains(operation),
                "\(document.lastPathComponent) does not mention \(operation)"
            )
        }

        // JSON documents are validated structurally; YAML gets the path
        // presence check above (no YAML parser is linked in this target).
        if document.pathExtension == "json" {
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any],
                "\(document.lastPathComponent) is not a JSON object"
            )
            let paths = try XCTUnwrap(
                root["paths"] as? [String: Any],
                "\(document.lastPathComponent) has no paths object"
            )
            for operation in Self.consumedOperations {
                let path = try XCTUnwrap(
                    paths[operation] as? [String: Any],
                    "\(document.lastPathComponent) is missing path \(operation)"
                )
                XCTAssertNotNil(path["get"], "\(document.lastPathComponent) is missing GET \(operation)")
            }
        }
    }

    /// Canonical locations searched for the committed spec, most conventional
    /// first: the swift-openapi-generator layout inside the package, then the
    /// repository root.
    private func candidateDocumentURLs() -> [URL] {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent() // Tests/ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore
        let repositoryRoot = packageRoot.deletingLastPathComponent()

        var urls: [URL] = []
        for directory in [packageRoot.appendingPathComponent("OpenAPI"), repositoryRoot] {
            for name in ["openapi", "color_matching", "api"] {
                for fileExtension in ["json", "yaml", "yml"] {
                    urls.append(directory.appendingPathComponent("\(name).\(fileExtension)"))
                }
            }
        }
        return urls
    }
}
