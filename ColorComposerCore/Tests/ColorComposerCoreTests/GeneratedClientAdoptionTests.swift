import Foundation
import XCTest

final class GeneratedClientAdoptionTests: XCTestCase {
    func testPackageDeclaresOpenAPIClientDependenciesAndGeneratedSource() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageManifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(packageManifest.contains("swift-openapi-generator"))
        XCTAssertTrue(packageManifest.contains("swift-openapi-runtime"))

        let sourceRoot = packageRoot.appendingPathComponent("Sources/ColorComposerCore")
        let generatedSources = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.lowercased().contains("generated") }
        XCTAssertFalse(generatedSources.isEmpty, "Keep the OpenAPI-generated client in a clearly named source location.")
    }
}
