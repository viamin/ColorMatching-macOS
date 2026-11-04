import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testCorePackageDeclaresGeneratedClientDependencies() throws {
        let manifest = try String(contentsOf: packageURL)

        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-runtime"),
            "ColorComposerCore must depend on swift-openapi-runtime for its generated API client."
        )
        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-generator"),
            "ColorComposerCore must depend on swift-openapi-generator to generate its API client."
        )
    }

    private var packageURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
