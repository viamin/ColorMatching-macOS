import Foundation
import XCTest

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresTheGeneratedOpenAPIClientDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL)

        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
    }
}
