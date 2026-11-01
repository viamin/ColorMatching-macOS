import Foundation
import XCTest

/// Guards the documentation deliverable of issue #39: README.md must document
/// solver-parity corpus consumption — where the committed corpus lives, where
/// it comes from, and how to refresh it.
///
/// Expected to fail until the README section lands; the implementation notes
/// to lift into the README live in `docs/solver-parity-corpus.md`.
final class CorpusDocumentationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testREADMEDocumentsWhereTheCorpusLivesAndHowToRefreshIt() throws {
        let readme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let lowered = readme.lowercased()

        XCTAssertTrue(lowered.contains("corpus"), "README must document the solver parity corpus")
        XCTAssertTrue(
            readme.contains("ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/corpus.v1.json"),
            "README must state where the committed corpus lives"
        )
        XCTAssertTrue(
            readme.contains("priv/parity/v1/corpus.json"),
            "README must point at the upstream corpus source in color_matching"
        )
        XCTAssertTrue(lowered.contains("refresh"), "README must explain how to refresh the corpus")
    }
}
