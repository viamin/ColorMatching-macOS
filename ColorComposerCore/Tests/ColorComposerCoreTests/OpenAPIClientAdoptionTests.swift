import Foundation
import XCTest

/// Issue #39 deliverable guard: `ColorComposerCore` must adopt the generated
/// OpenAPI client stack — `swift-openapi-generator` (build plugin) and
/// `swift-openapi-runtime` (runtime library) declared in `Package.swift`.
///
/// These assertions fail until the migration lands, which is the point: they
/// turn "the package adopted the generated client" into an inspectable,
/// recurring check instead of prose in a pull request description.
final class OpenAPIClientAdoptionTests: XCTestCase {
    private func packageManifest() throws -> String {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        return try String(contentsOf: manifestURL, encoding: .utf8)
    }

    func testPackageDeclaresSwiftOpenAPIRuntimeDependency() throws {
        let manifest = try packageManifest()

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must depend on swift-openapi-runtime (issue #39)"
        )
    }

    func testPackageDeclaresSwiftOpenAPIGeneratorDependency() throws {
        let manifest = try packageManifest()

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-generator build plugin (issue #39)"
        )
    }
}
