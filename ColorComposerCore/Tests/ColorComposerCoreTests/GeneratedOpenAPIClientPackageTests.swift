import Foundation
import XCTest

final class GeneratedOpenAPIClientPackageTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGenerator() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let package = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(package.contains("swift-openapi-runtime"))
        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("OpenAPIRuntime"))
        XCTAssertTrue(package.contains("OpenAPIGenerator"))
    }
}
