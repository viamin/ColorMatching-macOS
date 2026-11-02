import Foundation
import XCTest

final class GeneratedClientAdoptionTests: XCTestCase {
    func testPackageUsesOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(contentsOf: packageDirectory.appendingPathComponent("Package.swift"))

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }

    private var packageDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
