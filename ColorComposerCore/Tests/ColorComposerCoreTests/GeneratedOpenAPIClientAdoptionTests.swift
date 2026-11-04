import Foundation
import XCTest

final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    func testPackageUsesOpenAPIGeneratorAndRuntimeForPaletteClient() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"))
        let sourceDirectory = packageRoot.appendingPathComponent("Sources/ColorComposerCore")
        let generatedClientUsesRuntime = FileManager.default
            .enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .contains { url in
                guard let source = try? String(contentsOf: url) else { return false }
                return source.contains("import OpenAPIRuntime")
            }

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
        XCTAssertTrue(generatedClientUsesRuntime)
    }
}
