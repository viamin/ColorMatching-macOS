import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias PaletteAPIReauthentication = @Sendable () async throws -> String?

/// Errors produced by `PaletteAPIClient`.
public enum PaletteAPIError: Error, LocalizedError, Equatable {
    case invalidURL
    /// The server rejected the bearer token (HTTP 401), distinct from other
    /// non-2xx statuses so callers can trigger a re-authentication flow
    /// (issue #16) instead of surfacing a generic error.
    case unauthorized
    case badStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server URL is not valid."
        case .unauthorized: return "The API token was rejected. Enter a new token and try again."
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
    public func fetchPrinterProfiles(
        retryingWith reauthenticate: PaletteAPIReauthentication? = nil
    ) async throws -> [PrinterProfileDTO] {
        let url = endpoint(path: "printer_profiles")
        let envelope: PrinterProfilesResponse = try await get(url, retryingWith: reauthenticate)
        return envelope.printerProfiles
    }

    /// `GET /api/v1/colors?printer_profile_id=N`
    ///
    /// Returns every measured color for the profile (the palette grouping is
    /// irrelevant to composition); colors with no measurement for the profile
    /// come back response-less and are excluded by the solver.
    public func fetchColors(
        printerProfileID: Int,
        retryingWith reauthenticate: PaletteAPIReauthentication? = nil
    ) async throws -> (colors: [PaletteColorDTO], profile: PrinterProfileDTO?) {
        var components = URLComponents(url: endpoint(path: "colors"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "printer_profile_id", value: String(printerProfileID))]
        guard let url = components?.url else { throw PaletteAPIError.invalidURL }

        let envelope: ColorsResponse = try await get(url, retryingWith: reauthenticate)
        return (envelope.colors, envelope.printerProfile)
    }

    /// Lightweight reachability check used by the "Test connection" UI action.
    /// Succeeds on any 2xx from `/api/v1/printer_profiles`.
    public func testConnection(
        retryingWith reauthenticate: PaletteAPIReauthentication? = nil
    ) async throws {
        let request = request(url: endpoint(path: "printer_profiles"))
        _ = try await data(for: request, retryingWith: reauthenticate)
    }

    // MARK: - Internals

    private func endpoint(path: String) -> URL {
        baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
    }

    private func request(url: URL, acceptJSON: Bool = true, token overrideToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if acceptJSON {
            request.addValue("application/json", forHTTPHeaderField: "Accept")
        }
        authorize(&request, token: normalizedToken(overrideToken) ?? token)
        return request
    }

    private func authorize(_ request: inout URLRequest, token: String?) {
        if let token = normalizedToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func get<T: Decodable>(
        _ url: URL,
        retryingWith reauthenticate: PaletteAPIReauthentication? = nil
    ) async throws -> T {
        let request = request(url: url)
        let (data, _) = try await data(for: request, retryingWith: reauthenticate)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PaletteAPIError.malformedResponse
        }
    }

    private func data(
        for request: URLRequest,
        retryingWith reauthenticate: PaletteAPIReauthentication? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PaletteAPIError.malformedResponse }

        if http.statusCode == 401 {
            guard let reauthenticate else { throw PaletteAPIError.unauthorized }
            guard let refreshedToken = normalizedToken(try await reauthenticate()) else {
                throw PaletteAPIError.unauthorized
            }
            guard let url = request.url else { throw PaletteAPIError.invalidURL }
            let retriedRequest = request(
                url: url,
                acceptJSON: request.value(forHTTPHeaderField: "Accept") != nil,
                token: refreshedToken
            )
            return try await data(for: retriedRequest, retryingWith: nil)
        }

        guard (200..<300).contains(http.statusCode) else { throw PaletteAPIError.badStatus(http.statusCode) }
        return (data, http)
    }

    private func normalizedToken(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        return token
    }
}
