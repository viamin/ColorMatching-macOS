import XCTest
@testable import ColorComposerCore

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    /// The generated API client is expected to use Apple's runtime instead of
    /// maintaining a second hand-written wire model.
    func testOpenAPIRuntimeIsLinkedToTheCorePackage() {
        #if canImport(OpenAPIRuntime)
        XCTAssertTrue(true)
        #else
        XCTFail("ColorComposerCore must link swift-openapi-runtime for the generated API client")
        #endif
    }
}
