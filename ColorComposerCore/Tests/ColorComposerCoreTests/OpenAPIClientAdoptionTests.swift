import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresOfficialOpenAPIClientDependenciesAndGenerationPlugin() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(manifest.contains("https://github.com/apple/swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("https://github.com/apple/swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }
}
