import Foundation
import XCTest

final class OpenAPIClientMigrationContractTests: XCTestCase {
    func testPackageDeclaresGeneratedOpenAPIClientDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
        XCTAssertTrue(package.contains("OpenAPIGenerator"))
        XCTAssertTrue(package.contains("OpenAPIRuntime"))
    }
}
