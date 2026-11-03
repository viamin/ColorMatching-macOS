import Foundation
import XCTest

/// Package-level contract for issue #39. The generated client's public
/// endpoint behavior is covered by `PaletteAPIClientTests`; this test prevents
/// silently retaining a hand-written-only transport stack.
final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    func testCorePackageDeclaresOpenAPIRuntimeAndGenerator() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
    }
}
