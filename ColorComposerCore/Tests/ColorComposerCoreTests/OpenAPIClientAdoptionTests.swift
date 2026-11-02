import Foundation
import XCTest

/// Pins the first deliverable of #39: `ColorComposerCore` must depend on
/// `swift-openapi-generator` + `swift-openapi-runtime` and generate a typed
/// client from the `color_matching` OpenAPI document (viamin/color_matching#110),
/// with `PaletteAPIClient` migrated to it (or wrapping it).
///
/// This only inspects the package manifest as text — it deliberately avoids
/// `import OpenAPIRuntime` or referencing generated types, since neither
/// exists in the package graph yet; doing so would fail to *compile* the
/// whole test target instead of failing this one assertion.
final class OpenAPIClientAdoptionTests: XCTestCase {
    private var packageManifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore
            .appendingPathComponent("Package.swift")
    }

    func testPackageDeclaresOpenAPIGeneratorDependencies() throws {
        let manifest = try String(contentsOf: packageManifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            """
            ColorComposerCore/Package.swift must depend on apple/swift-openapi-generator \
            to generate a typed client from the color_matching OpenAPI document \
            (viamin/color_matching#110).
            """
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            """
            ColorComposerCore/Package.swift must depend on apple/swift-openapi-runtime, \
            the runtime support library the generated client needs at runtime.
            """
        )
    }
}
