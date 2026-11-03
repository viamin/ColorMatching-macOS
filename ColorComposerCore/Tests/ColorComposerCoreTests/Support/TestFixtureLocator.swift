import Foundation

/// Locates files committed next to the test target (fixtures, vendored
/// documents) without relying on bundle resources.
///
/// The test target declares no SwiftPM resources, so fixtures are addressed
/// relative to this source file and resolved by walking up to the nearest
/// ancestor that contains them. That keeps the lookup working for `swift
/// test` from a source checkout, which is where the parity corpus and the
/// vendored OpenAPI document live.
enum TestFixtureLocator {
    /// Directory holding this source file (the test target's `Support` folder).
    static let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// The nearest ancestor directory of `sourceDirectory` that contains
    /// `relativePath`, or `nil` when no ancestor has it.
    static func locate(_ relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        var directory = sourceDirectory
        while true {
            var candidate = directory
            for component in components {
                candidate = candidate.appendingPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// The package root (the directory holding `Package.swift`), if reachable.
    static var packageRoot: URL? {
        var directory = sourceDirectory
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// Appends a slash-separated relative path to a directory.
    static func appending(_ relativePath: String, to directory: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(directory) { $0.appendingPathComponent(String($1)) }
    }
}
