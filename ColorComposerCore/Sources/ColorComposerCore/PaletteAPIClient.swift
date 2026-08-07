import Foundation

/// Errors produced by `PaletteAPIClient`.
public enum PaletteAPIError: Error, LocalizedError, Equatable {
    case invalidURL
    case badStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server URL is not valid."
        case .badStatus(let code): return "The server returned HTTP \(code)."
        case .malformedResponse: return "The server response could not be read."
        }
    }
}

/// Async client for the `color_matching` palette API (`/api/v1/*`).
///
/// All endpoints accept an optional bearer token; when the server has
/// `LPSM_API_TOKEN` configured, the same token must be supplied here.
public struct PaletteAPIClient: Sendable {
    public let baseURL: URL
    public let token: String?
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: - Endpoints

    /// `GET /api/v1/printer_profiles`
    public func fetchPrinterProfiles() async throws -> [PrinterProfileDTO] {
        let url = endpoint(path: "printer_profiles")
        let envelope: PrinterProfilesResponse = try await get(url)
        return envelope.printerProfiles
    }

    /// `GET /api/v1/palettes`
    public func fetchPalettes() async throws -> [PaletteSummaryDTO] {
        let url = endpoint(path: "palettes")
        let envelope: PalettesResponse = try await get(url)
        return envelope.palettes
    }

    /// `GET /api/v1/colors?printer_profile_id=N&palette_id=M`
    ///
    /// `paletteID` is optional: when `nil`, every color across all palettes is
    /// returned.
    public func fetchColors(
        printerProfileID: Int,
        paletteID: Int? = nil
    ) async throws -> (colors: [PaletteColorDTO], profile: PrinterProfileDTO?) {
        var components = URLComponents(url: endpoint(path: "colors"), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = [URLQueryItem(name: "printer_profile_id", value: String(printerProfileID))]
        if let paletteID {
            query.append(URLQueryItem(name: "palette_id", value: String(paletteID)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw PaletteAPIError.invalidURL }

        let envelope: ColorsResponse = try await get(url)
        return (envelope.colors, envelope.printerProfile)
    }

    /// Lightweight reachability check used by the "Test connection" UI action.
    /// Succeeds on any 2xx from `/api/v1/printer_profiles`.
    public func testConnection() async throws {
        let url = endpoint(path: "printer_profiles")
        var request = URLRequest(url: url)
        authorize(&request)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PaletteAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PaletteAPIError.badStatus(http.statusCode)
        }
    }

    // MARK: - Internals

    private func endpoint(path: String) -> URL {
        baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
    }

    private func authorize(_ request: inout URLRequest) {
        if let token, !token.isEmpty {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw PaletteAPIError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PaletteAPIError.badStatus(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PaletteAPIError.malformedResponse
        }
    }
}
