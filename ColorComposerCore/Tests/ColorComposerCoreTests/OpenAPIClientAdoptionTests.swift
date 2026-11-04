import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresGeneratedClientDependencies() throws {
        let package = try packageManifest()
        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
    }

    private func packageManifest() throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let package = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        return try String(contentsOf: package)
    }
}
