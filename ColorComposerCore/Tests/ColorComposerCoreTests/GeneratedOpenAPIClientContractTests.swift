import Foundation
import XCTest

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGenerator() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"), "Add swift-openapi-runtime to ColorComposerCore.")
        XCTAssertTrue(manifest.contains("swift-openapi-generator"), "Add swift-openapi-generator to ColorComposerCore.")
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"), "Generate the typed API client through the OpenAPI build plugin.")
    }
}
