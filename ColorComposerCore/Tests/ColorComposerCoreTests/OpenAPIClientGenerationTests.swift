import Foundation
import XCTest

final class OpenAPIClientGenerationTests: XCTestCase {
    func testPackageDeclaresGeneratorRuntimeAndGeneratedClientPlugin() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }

    func testCommittedOpenAPIDocumentIsAvailableToTheGenerator() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: packageRoot.appendingPathComponent("Sources/ColorComposerCore/openapi.yaml").path
            )
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
