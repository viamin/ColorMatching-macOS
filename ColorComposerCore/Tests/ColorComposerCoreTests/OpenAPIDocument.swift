import Foundation
import XCTest

/// The OpenAPI document published by the `color_matching` server
/// (`GET /api/v1/openapi.json`), vendored into this repository so a typed
/// client can be generated from it and so the contract the app relies on
/// stays checkable.
///
/// The document is looked up by file name: any JSON file whose name contains
/// `openapi` inside the package or the repository checkout counts.
struct OpenAPIDocument {
    enum LoaderError: Error, CustomStringConvertible {
        case documentNotFound([String])
        case unreadable(URL, Error)
        case notJSON(URL)

        var description: String {
            switch self {
            case .documentNotFound(let roots):
                return """
                No vendored OpenAPI document was found. Commit the document the server publishes at \
                GET /api/v1/openapi.json as a JSON file whose name contains "openapi". Searched:
                \(roots.map { "  - \($0)" }.joined(separator: "\n"))
                """
            case .unreadable(let url, let error):
                return "Could not read the OpenAPI document at \(url.path): \(error)"
            case .notJSON(let url):
                return "The OpenAPI document at \(url.path) is not valid JSON."
            }
        }
    }

    /// Where the document was found.
    let url: URL
    /// The parsed document.
    let root: [String: Any]

    init(url: URL, root: [String: Any]) {
        self.url = url
        self.root = root
    }

    static func load() throws -> OpenAPIDocument {
        let url = try vendoredDocumentURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoaderError.unreadable(url, error)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoaderError.notJSON(url)
        }
        return OpenAPIDocument(url: url, root: root)
    }

    // MARK: - Document access

    /// The OpenAPI version the document declares.
    var version: String? {
        root["openapi"] as? String
    }

    /// Every documented path.
    var paths: [String: Any] {
        root["paths"] as? [String: Any] ?? [:]
    }

    /// The reusable component schemas.
    var schemas: [String: Any] {
        (root["components"] as? [String: Any])?["schemas"] as? [String: Any] ?? [:]
    }

    /// The declared security schemes.
    var securitySchemes: [String: Any] {
        (root["components"] as? [String: Any])?["securitySchemes"] as? [String: Any] ?? [:]
    }

    /// The operation object for a path and method, when documented.
    func operation(_ path: String, _ method: String) -> [String: Any]? {
        (paths[path] as? [String: Any])?[method] as? [String: Any]
    }

    /// The response schema of an operation, when documented.
    func responseSchema(path: String, method: String = "get", status: String = "200") -> [String: Any]? {
        guard let operation = operation(path, method),
              let responses = operation["responses"] as? [String: Any],
              let response = responses[status] as? [String: Any],
              let content = response["content"] as? [String: Any] else { return nil }
        let media = (content["application/json"] as? [String: Any])
            ?? content.values.compactMap { $0 as? [String: Any] }.first
        return (media?["schema"] as? [String: Any])
    }

    /// The parameters an operation declares.
    func parameters(path: String, method: String = "get") -> [[String: Any]] {
        (operation(path, method)?["parameters"] as? [[String: Any]]) ?? []
    }

    /// Resolves `$ref`s and `allOf` wrappers into a single schema object.
    func resolved(_ schema: [String: Any]) -> [String: Any] {
        if let ref = schema["$ref"] as? String, let target = component(named: ref) {
            return resolved(target)
        }
        if let members = schema["allOf"] as? [[String: Any]], !members.isEmpty {
            var merged: [String: Any] = [:]
            for member in members {
                merge(resolved(member), into: &merged)
            }
            return merged
        }
        return schema
    }

    /// The property names a schema declares.
    func propertyNames(_ schema: [String: Any]) -> Set<String> {
        Set((resolved(schema)["properties"] as? [String: Any] ?? [:]).keys)
    }

    /// The schema of an array property's items.
    func itemSchema(of schema: [String: Any], property: String) -> [String: Any]? {
        guard let properties = resolved(schema)["properties"] as? [String: Any],
              let declaration = properties[property] as? [String: Any],
              let items = declaration["items"] as? [String: Any] else { return nil }
        return resolved(items)
    }

    // MARK: - Internals

    private func component(named ref: String) -> [String: Any]? {
        guard let name = ref.split(separator: "/").last else { return nil }
        return schemas[String(name)] as? [String: Any]
    }

    private func merge(_ source: [String: Any], into target: inout [String: Any]) {
        for (key, value) in source {
            switch key {
            case "properties":
                var properties = target["properties"] as? [String: Any] ?? [:]
                properties.merge(value as? [String: Any] ?? [:]) { _, new in new }
                target["properties"] = properties
            case "required":
                var required = target["required"] as? [String] ?? []
                required.append(contentsOf: value as? [String] ?? [])
                target["required"] = required
            default:
                if target[key] == nil { target[key] = value }
            }
        }
    }

    private static func vendoredDocumentURL() throws -> URL {
        let roots = searchRoots()
        let matches = roots.flatMap(matchingDocuments(under:))
        // Prefer the canonical name when several documents are vendored.
        let ordered = matches.sorted { lhs, rhs in
            let lhsRank = lhs.lastPathComponent.lowercased() == "openapi.json" ? 0 : 1
            let rhsRank = rhs.lastPathComponent.lowercased() == "openapi.json" ? 0 : 1
            return lhsRank == rhsRank ? lhs.path < rhs.path : lhsRank < rhsRank
        }
        guard let url = ordered.first else {
            throw LoaderError.documentNotFound(roots.map(\.path))
        }
        return url
    }

    private static func matchingDocuments(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json" else { continue }
            let name = url.lastPathComponent.lowercased()
            guard name.contains("openapi") || name.contains("open-api") else { continue }
            matches.append(url)
        }
        return matches
    }

    /// The package directory, plus the repository checkout it lives in. The
    /// sources are also looked up with symlinks resolved, so the lint harness
    /// (which reaches them through a symlink) finds the same document.
    private static func searchRoots() -> [URL] {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var roots: [URL] = []

        for directory in [sourceDirectory, sourceDirectory.resolvingSymlinksInPath()] {
            let packageRoot = directory.deletingLastPathComponent().deletingLastPathComponent()
            if !roots.contains(packageRoot) { roots.append(packageRoot) }

            var ancestor = packageRoot
            for _ in 0..<3 {
                ancestor = ancestor.deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) else {
                    continue
                }
                if !roots.contains(ancestor) { roots.append(ancestor) }
                break
            }
        }
        return roots
    }
}
