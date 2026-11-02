import Foundation
import XCTest

/// Structural adoption checks for the generated OpenAPI client (issue #39).
///
/// These deliberately fail until `ColorComposerCore` adopts
/// `swift-openapi-generator` + `swift-openapi-runtime` (viamin/color_matching#110)
/// and generates a typed client from the published OpenAPI document. They stay
/// green afterwards so the dependencies, the spec, and the generated client
/// cannot be silently dropped. The behavioral wire contract the migration must
/// preserve is pinned separately in `PaletteAPIClientWireContractTests`.
final class OpenAPIClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Issue #39: the package must declare the OpenAPI generator + runtime.
    func testPackageManifestDeclaresOpenAPIPackages() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must add swift-openapi-generator (issue #39, depends on viamin/color_matching#110)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must add swift-openapi-runtime (issue #39)"
        )
    }

    /// Issue #39: the OpenAPI document published by viamin/color_matching#110
    /// must be committed so the client can be regenerated offline.
    func testOpenAPIDocumentIsCommitted() throws {
        let documents = try candidateFiles(in: packageRoot).filter(isOpenAPIDocument)
        XCTAssertTrue(
            !documents.isEmpty,
            "No committed OpenAPI document (openapi*.yaml/.yml/.json) found under \(packageRoot.path)"
        )
    }

    /// Issue #39: `PaletteAPIClient` must be migrated onto the generated client,
    /// so the package sources must reference the OpenAPI runtime.
    func testClientSourcesImportOpenAPIRuntime() throws {
        let sources = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let referencing = try candidateFiles(in: sources)
            .filter { $0.pathExtension.lowercased() == "swift" }
            .filter { url in
                try String(contentsOf: url, encoding: .utf8).contains("OpenAPIRuntime")
            }
        XCTAssertFalse(
            referencing.isEmpty,
            "No source under \(sources.path) references OpenAPIRuntime; PaletteAPIClient must use the generated client"
        )
    }

    // MARK: - File discovery

    private let skippedDirectories: Set<String> = [".build", ".git", "checkouts", "Fixtures"]
    private let candidateExtensions: Set<String> = ["swift", "yaml", "yml", "json"]

    private func candidateFiles(in directory: URL) throws -> [URL] {
        var results: [URL] = []
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || skippedDirectories.contains(name) { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                results.append(contentsOf: try candidateFiles(in: entry))
            } else if candidateExtensions.contains(entry.pathExtension.lowercased()) {
                results.append(entry)
            }
        }
        return results
    }

    private func isOpenAPIDocument(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let hasDocumentExtension = ["yaml", "yml", "json"].contains(url.pathExtension.lowercased())
        let namedLikeSpec = name.range(
            of: #"^openapi[-.].*\.(yaml|yml|json)$"#,
            options: [.regularExpression]
        ) != nil
        let insideOpenAPIDirectory =
            hasDocumentExtension
            && url.deletingLastPathComponent().lastPathComponent.lowercased() == "openapi"
        return namedLikeSpec || insideOpenAPIDirectory
    }
}
