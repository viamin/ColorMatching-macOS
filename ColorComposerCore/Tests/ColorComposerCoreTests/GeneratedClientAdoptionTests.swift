import XCTest
@testable import ColorComposerCore

/// Structural gate for the generated OpenAPI client adoption (issue #39).
///
/// The package must generate its typed `/api/v1` client from a committed
/// OpenAPI document with apple/swift-openapi-generator, and link
/// swift-openapi-runtime. These checks are deliberately mechanical — they
/// turn "the typed client replaced the hand-rolled request building" into an
/// enforceable contract at test time, while the behavioral contract the
/// migration must preserve lives in `PaletteAPIClientTests`.
///
/// Until the migration lands, these tests fail — that is the red phase this
/// suite was written in.
final class GeneratedClientAdoptionTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()     // ColorComposerCoreTests
        .deletingLastPathComponent()     // Tests
        .deletingLastPathComponent()     // ColorComposerCore

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator (build plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime"
        )
    }

    func testOpenAPIDocumentIsCommittedForTheGeneratedClient() throws {
        let document = try XCTUnwrap(
            Self.findOpenAPIDocument(),
            "no OpenAPI document named openapi.{json,yaml,yml} is committed under " +
            "Sources/ColorComposerCore; the generated client has nothing to generate from"
        )
        let text = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(
            text.contains("/api/v1/printer_profiles"),
            "\(document.lastPathComponent) must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            text.contains("/api/v1/colors"),
            "\(document.lastPathComponent) must describe GET /api/v1/colors"
        )

        if document.pathExtension.lowercased() == "json" {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                "\(document.lastPathComponent) is not a JSON object"
            )
            XCTAssertNotNil(
                object["openapi"],
                "\(document.lastPathComponent) must carry an `openapi` version"
            )
        }
    }

    /// First `openapi.{json,yaml,yml}` under the target's sources, however
    /// the implementation lays the document out (root or subdirectory).
    private static func findOpenAPIDocument() -> URL? {
        let sources = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ColorComposerCore", isDirectory: true)
        var pending = [sources]
        while let directory = pending.popLast() {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in contents {
                if item.hasDirectoryPath {
                    pending.append(item)
                    continue
                }
                let name = item.lastPathComponent.lowercased()
                if name.hasPrefix("openapi."), ["json", "yaml", "yml"].contains(item.pathExtension.lowercased()) {
                    return item
                }
            }
        }
        return nil
    }
}
