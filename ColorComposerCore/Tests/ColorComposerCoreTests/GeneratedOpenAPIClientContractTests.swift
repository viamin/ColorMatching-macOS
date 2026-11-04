import Foundation
import XCTest

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGenerator() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
    }
}
