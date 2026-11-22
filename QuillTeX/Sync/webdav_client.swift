import Foundation

enum WebDAVError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case methodNotAllowed
    case tooLarge
    case rateLimited
    case quotaExceeded
    case server(Int, String?)
    case network(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The WebDAV address is not a valid https:// URL."
        case .unauthorized:
            return "The account or app password was rejected. Check your Nutstore WebDAV settings."
        case .forbidden:
            return "The server refused access. Make sure WebDAV is enabled for this Nutstore account."
        case .notFound:
            return "The WebDAV folder could not be found."
        case .conflict:
            return "A parent WebDAV folder is missing."
        case .methodNotAllowed:
            return "The WebDAV server did not accept this request."
        case .tooLarge:
            return "The PDF is larger than the WebDAV server allows."
        case .rateLimited:
            return "Nutstore is limiting requests right now. Wait a few minutes and try again."
        case .quotaExceeded:
            return "The Nutstore account has no space left."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                return "WebDAV returned HTTP \(status): \(message)"
            }
            return "WebDAV returned HTTP \(status)."
        case .network(let message):
            return "Could not reach the WebDAV server: \(message)"
        case .invalidResponse:
            return "The WebDAV server returned an unexpected response."
        }
    }
}

protocol WebDAVTransport {
    func testConnection() async throws
    func ensureDirectory(_ components: [String]) async throws
    func exists(_ components: [String]) async throws -> Bool
    func put(_ data: Data, at components: [String], contentType: String) async throws
    func put(fileAt url: URL, at components: [String], contentType: String) async throws
    func delete(_ components: [String]) async throws
}

/// A deliberately small WebDAV client for the one-way upload path. It only
/// needs Basic auth, MKCOL, PROPFIND (existence) and PUT; it never reads or
/// merges remote content.
final class WebDAVClient: WebDAVTransport {
    let baseURL: URL
    let username: String
    private let password: String
    private let session: URLSession
    private let authorization: String

    init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - WebDAVTransport

    func testConnection() async throws {
        let request = makeRequest("PROPFIND", url: baseURL,
                                  headers: ["Depth": "0", "Content-Type": "application/xml"],
                                  body: Self.propfindBody)
        let (data, response) = try await send(request)
        if response.statusCode == 405 {
            let head = makeRequest("HEAD", url: baseURL)
            let (headData, headResponse) = try await send(head)
            try require(headResponse.statusCode, allowed: [200, 207], data: headData)
            return
        }
        try require(response.statusCode, allowed: [200, 207], data: data)
    }

    func ensureDirectory(_ components: [String]) async throws {
        guard !components.isEmpty else { return }
        var path: [String] = []
        for component in components {
            path.append(component)
            let request = makeRequest("MKCOL", url: url(for: path, directory: true))
            let (data, response) = try await send(request)
            switch response.statusCode {
            case 200, 201, 204, 405:
                continue
            default:
                throw mapError(response.statusCode, data: data)
            }
        }
    }

    func exists(_ components: [String]) async throws -> Bool {
        let request = makeRequest("PROPFIND", url: url(for: components, directory: false),
                                  headers: ["Depth": "0", "Content-Type": "application/xml"],
                                  body: Self.propfindBody)
        let (data, response) = try await send(request)
        if response.statusCode == 404 { return false }
        if response.statusCode == 405 {
            let head = makeRequest("HEAD", url: url(for: components, directory: false))
            let (headData, headResponse) = try await send(head)
            if headResponse.statusCode == 404 { return false }
            try require(headResponse.statusCode, allowed: [200, 207], data: headData)
            return true
        }
        try require(response.statusCode, allowed: [200, 207], data: data)
        return true
    }

    func put(_ data: Data, at components: [String], contentType: String) async throws {
        let request = makeRequest("PUT", url: url(for: components, directory: false),
                                  headers: ["Content-Type": contentType], body: data)
        let (responseData, response) = try await send(request)
        try require(response.statusCode, allowed: [200, 201, 204], data: responseData)
    }

    func put(fileAt url: URL, at components: [String], contentType: String) async throws {
        let request = makeRequest("PUT", url: self.url(for: components, directory: false),
                                  headers: ["Content-Type": contentType])
        do {
            let (data, response) = try await session.upload(for: request, fromFile: url)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
            try require(http.statusCode, allowed: [200, 201, 204], data: data)
        } catch let error as WebDAVError {
            throw error
        } catch let error as URLError {
            throw WebDAVError.network(error.localizedDescription)
        } catch {
            throw WebDAVError.network(error.localizedDescription)
        }
    }

    func delete(_ components: [String]) async throws {
        let request = makeRequest("DELETE", url: url(for: components, directory: false))
        let (data, response) = try await send(request)
        // A file that is already gone is the desired end state.
        try require(response.statusCode, allowed: [200, 204, 404], data: data)
    }

    // MARK: - Requests

    private func url(for components: [String], directory: Bool) -> URL {
        guard !components.isEmpty else { return baseURL }
        var result = baseURL
        for (index, component) in components.enumerated() {
            result = result.appendingPathComponent(component, isDirectory: directory && index == components.count - 1)
        }
        return result
    }

    private func makeRequest(_ method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("QuillTeX", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
            return (data, http)
        } catch let error as WebDAVError {
            throw error
        } catch let error as URLError {
            throw WebDAVError.network(error.localizedDescription)
        } catch {
            throw WebDAVError.network(error.localizedDescription)
        }
    }

    private func require(_ status: Int, allowed: Set<Int>, data: Data) throws {
        guard allowed.contains(status) else { throw mapError(status, data: data) }
    }

    private func mapError(_ status: Int, data: Data) -> WebDAVError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 405: return .methodNotAllowed
        case 409: return .conflict
        case 413: return .tooLarge
        case 429: return .rateLimited
        case 507: return .quotaExceeded
        default:
            let message = String(decoding: data.prefix(240), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(status, message.isEmpty ? nil : message)
        }
    }

    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
    """.utf8)
}
