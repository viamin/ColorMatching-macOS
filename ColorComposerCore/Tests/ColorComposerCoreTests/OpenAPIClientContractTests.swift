import Foundation
import XCTest
@testable import ColorComposerCore

/// Structural contract for the generated OpenAPI client.
///
/// The client is generated from the `color_matching` OpenAPI document, so the
/// document and the generator wiring have to live in the repository — a
/// client generated from a document nobody can rebuild is not reviewable.
///
/// These checks are deliberately structural (ZFC): they read the committed
/// files and compare them against the contract, they do not guess intent.
final class OpenAPIClientContractTests: XCTestCase {
    /// The package must depend on the generator (to produce the client) and on
    /// the runtime (to send the requests).
    func testPackageDeclaresTheOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try String(contentsOf: try OpenAPIDocumentDiscovery.packageManifestURL(), encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore must depend on swift-openapi-generator"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore must depend on swift-openapi-runtime"
        )
    }

    /// The OpenAPI document the client is generated from is committed and
    /// declares the endpoints this app uses.
    func testCommittedOpenAPIDocumentDeclaresTheEndpointsTheClientUses() throws {
        let documents = try OpenAPIDocumentDiscovery.openAPIDocuments()

        XCTAssertFalse(
            documents.isEmpty,
            "the repository must commit the OpenAPI document the client is generated from"
        )

        let matching = documents.filter { document in
            let remainders = Set(document.declaredPaths.map(OpenAPIDocumentDiscovery.normalizedRemainder))
            return remainders.contains("printer_profiles") && remainders.contains("colors")
        }

        XCTAssertFalse(
            matching.isEmpty,
            "the committed OpenAPI document must declare /api/v1/printer_profiles and /api/v1/colors"
        )
    }

    /// `/api/v1/colors` is fetched with a required `printer_profile_id`
    /// query parameter — the client sends it, so the document must pin it.
    func testCommittedOpenAPIDocumentPinsThePrinterProfileQueryParameter() throws {
        let documents = try OpenAPIDocumentDiscovery.openAPIDocuments()
        let matching = documents.filter { document in
            let remainders = Set(document.declaredPaths.map(OpenAPIDocumentDiscovery.normalizedRemainder))
            return remainders.contains("printer_profiles") && remainders.contains("colors")
        }

        for document in matching {
            if let json = document.json {
                let parameter = OpenAPIDocumentDiscovery.printerProfileQueryParameter(in: json)
                XCTAssertNotNil(
                    parameter,
                    "\(document.url.lastPathComponent) must declare a printer_profile_id query parameter for /api/v1/colors"
                )
                XCTAssertEqual(
                    parameter?.required,
                    true,
                    "\(document.url.lastPathComponent): printer_profile_id is required"
                )
            } else {
                let text = document.text
                let range = text.range(of: "printer_profile_id")
                XCTAssertNotNil(range, "\(document.url.lastPathComponent) must mention printer_profile_id")
                if let range {
                    let window = text[range.lowerBound..<text.index(range.lowerBound, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex]
                    XCTAssertTrue(
                        window.contains("required"),
                        "\(document.url.lastPathComponent): printer_profile_id must be required"
                    )
                }
            }
        }
    }
}

// MARK: - Repository discovery

/// A committed OpenAPI document.
private struct OpenAPIDocument {
    let url: URL
    /// The path keys the document declares, e.g. `/api/v1/printer_profiles`.
    let declaredPaths: [String]
    /// The parsed document, when it is JSON.
    let json: [String: Any]?
    /// The raw document text, used for YAML documents.
    let text: String
}

private enum OpenAPIDocumentDiscovery {
    /// Directory names that never hold a committed OpenAPI document.
    static let skippedDirectories: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData",
        "build",
        "node_modules"
    ]

    /// The `Package.swift` of the `ColorComposerCore` package.
    static func packageManifestURL() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw DocumentError.packageManifestNotFound
    }

    /// The repository root: the directory that holds the package.
    static func repositoryRoot() throws -> URL {
        try packageManifestURL().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every committed OpenAPI document in the repository.
    static func openAPIDocuments() throws -> [OpenAPIDocument] {
        let root = try repositoryRoot()
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var documents: [OpenAPIDocument] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let name = url.lastPathComponent.lowercased()
            let isJSON = name.hasSuffix(".json")
            let isYAML = name.hasSuffix(".yaml") || name.hasSuffix(".yml")
            guard isJSON || isYAML else { continue }
            guard name.contains("openapi") else { continue }

            if isJSON, let document = jsonDocument(at: url) {
                documents.append(document)
            } else if isYAML, let document = yamlDocument(at: url) {
                documents.append(document)
            }
        }
        return documents
    }

    static func jsonDocument(at url: URL) -> OpenAPIDocument? {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["openapi"] is String else { return nil }
        let paths = (object["paths"] as? [String: Any]) ?? [:]
        return OpenAPIDocument(
            url: url,
            declaredPaths: Array(paths.keys),
            json: object,
            text: String(data: data, encoding: .utf8) ?? ""
        )
    }

    static func yamlDocument(at url: URL) -> OpenAPIDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard text.contains("openapi:") else { return nil }
        return OpenAPIDocument(url: url, declaredPaths: yamlPaths(in: text), json: nil, text: text)
    }

    /// The path keys of a YAML document, read from the `paths:` block.
    static func yamlPaths(in text: String) -> [String] {
        var paths: [String] = []
        var pathsIndent: Int?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if let pathsIndent {
                if indent <= pathsIndent { break }
                guard trimmed.hasPrefix("/") else { continue }
                paths.append(String(trimmed.prefix(while: { $0 != ":" })))
            } else if trimmed == "paths:" {
                pathsIndent = indent
            }
        }
        return paths
    }

    /// The path of an endpoint relative to `/api/v1`, so a document that
    /// declares `/printer_profiles` under an `/api/v1` server matches the same
    /// endpoint as one that declares `/api/v1/printer_profiles`.
    static func normalizedRemainder(_ path: String) -> String {
        var remainder = path
        if remainder.hasPrefix("/api/v1") {
            remainder = String(remainder.dropFirst("/api/v1".count))
        }
        if remainder.hasPrefix("/") {
            remainder = String(remainder.dropFirst())
        }
        return remainder
    }

    /// Whether the document declares `printer_profile_id` as a required query
    /// parameter of `/api/v1/colors`.
    static func printerProfileQueryParameter(in json: [String: Any]) -> (required: Bool)? {
        guard let paths = json["paths"] as? [String: Any] else { return nil }

        for (path, item) in paths {
            guard normalizedRemainder(path) == "colors", let item = item as? [String: Any] else { continue }

            var parameters: [[String: Any]] = []
            if let pathParameters = item["parameters"] as? [[String: Any]] {
                parameters.append(contentsOf: pathParameters)
            }
            if let get = item["get"] as? [String: Any],
               let operationParameters = get["parameters"] as? [[String: Any]] {
                parameters.append(contentsOf: operationParameters)
            }

            for parameter in parameters {
                var resolved = parameter
                if let reference = parameter["$ref"] as? String,
                   let referenced = resolveReference(reference, in: json) {
                    resolved = referenced
                }
                if (resolved["name"] as? String) == "printer_profile_id" {
                    return (resolved["required"] as? Bool) ?? false
                }
            }
        }
        return nil
    }

    static func resolveReference(_ reference: String, in json: [String: Any]) -> [String: Any]? {
        guard reference.hasPrefix("#/") else { return nil }
        var current: Any = json
        for component in reference.dropFirst(2).components(separatedBy: "/") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    enum DocumentError: Error {
        case packageManifestNotFound
    }
}
