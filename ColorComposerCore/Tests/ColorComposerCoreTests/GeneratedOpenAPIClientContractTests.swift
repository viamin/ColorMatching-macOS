import Foundation
import XCTest

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresTheOpenAPIGeneratorAndRuntime() throws {
        let package = try String(contentsOf: packageURL)

        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
    }

    private var packageURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
