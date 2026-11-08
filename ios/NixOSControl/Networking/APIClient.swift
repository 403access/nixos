import Foundation

struct APIError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? { message }
}

private struct ServerError: Decodable {
    let error: String
}

struct APIClient {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", query: query)
        return try await perform(request)
    }

    func post<T: Decodable>(_ path: String) async throws -> T {
        let request = try makeRequest(path: path, method: "POST")
        return try await perform(request)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") {
            base.removeLast()
        }
        let suffix = path.hasPrefix("/") ? path : "/" + path

        guard var components = URLComponents(string: base + suffix) else {
            throw APIError(statusCode: 0, message: "The server URL is not valid.")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError(statusCode: 0, message: "The request URL is not valid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError(statusCode: 0, message: "The server returned an invalid response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverError = try? JSONDecoder().decode(ServerError.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw APIError(
                statusCode: httpResponse.statusCode,
                message: serverError?.error ?? fallback
            )
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(
                statusCode: httpResponse.statusCode,
                message: "Could not decode the server response: \(error.localizedDescription)"
            )
        }
    }
}
