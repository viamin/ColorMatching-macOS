import Foundation
import XCTest

final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    func testCorePackageDeclaresOpenAPIGeneratorAndRuntime() throws {
        let package = try String(contentsOf: packageURL())

        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
    }

    func testCoreContainsAGeneratedOpenAPIClientUsedByThePaletteClient() throws {
        let sourceDirectory = packageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ColorComposerCore")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)
        )
        let sourceFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let source = try sourceFiles.map { try String(contentsOf: $0) }.joined(separator: "\n")

        XCTAssertTrue(source.contains("import OpenAPIRuntime"))
        XCTAssertTrue(source.contains("Client("))
    }

    private func packageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
