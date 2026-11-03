import Foundation
import XCTest

final class OpenAPIClientDependencyTests: XCTestCase {
    func testPackageManifestDeclaresGeneratedClientDependencies() throws {
        let manifest = try String(contentsOf: packageManifestURL())

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
