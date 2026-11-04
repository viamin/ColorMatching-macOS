import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresOpenAPIClientRuntimeAndGenerator() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package, encoding: .utf8)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
    }
}
