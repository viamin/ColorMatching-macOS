import Foundation
import XCTest

final class GeneratedOpenAPIClientConfigurationTests: XCTestCase {
    func testCorePackageDeclaresGeneratedOpenAPIClientDependencies() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package)

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
    }
}
