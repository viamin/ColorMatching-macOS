import Foundation
import XCTest

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGeneratorDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL)

        XCTAssertTrue(package.contains("https://github.com/apple/swift-openapi-runtime"))
        XCTAssertTrue(package.contains("https://github.com/apple/swift-openapi-generator"))
    }
}
