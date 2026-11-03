import Foundation
@testable import ColorComposerCore

/// Locator and decoder for the committed `color_matching` solver parity
/// corpus.
///
/// The fixture is a byte-identical copy of `priv/parity/v1/corpus.json` from
/// viamin/color_matching (PR #112, issue #111). `docs/solver-parity-corpus.md`
/// records where it lives and how to refresh it.
enum ParityCorpusFixture {
    /// Path of the fixture relative to the test target directory.
    static let relativePath = "Fixtures/parity/v1/corpus.json"

    /// FNV-1a (64-bit) checksum of the upstream corpus bytes as committed in
    /// viamin/color_matching PR #112.
    ///
    /// Pins the fixture against accidental edits: a hand-modified corpus would
    /// turn the parity test into an assertion about the edit rather than about
    /// the server's behavior.
    static let upstreamChecksum: UInt64 = 0xd29f_7eeb_b0aa_8010

    /// Absolute URL of the committed fixture.
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    /// Decodes the committed corpus.
    static func load() throws -> ParityCorpus {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    /// FNV-1a (64-bit) checksum of `data` — a dependency-free integrity pin.
    static func checksum(of data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
