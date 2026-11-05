import Foundation
import XCTest

final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresSwiftOpenAPIRuntimeAndGenerator() throws {
        let manifest = try packageManifest()

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }

    func testPaletteAPIClientUsesGeneratedOpenAPIClient() throws {
        let client = try sourceFile(named: "PaletteAPIClient.swift")

        XCTAssertTrue(client.contains("OpenAPIRuntime"))
        XCTAssertTrue(client.contains("Client"))
    }

    private func packageManifest() throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Package.swift"))
    }

    private func sourceFile(named name: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/ColorComposerCore/\(name)"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
