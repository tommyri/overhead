import Foundation

/// Tiny URLSession wrapper so adapters share error handling and JSON decoding.
public struct HTTP: Sendable {
    public var session: URLSession
    public var decoder: JSONDecoder

    public init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    public struct Request: Sendable {
        public var url: URL
        public var method: String = "GET"
        public var headers: [String: String] = [:]
        public var body: Data? = nil
        public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
            self.url = url; self.method = method; self.headers = headers; self.body = body
        }
    }

    public func data(_ req: Request) async throws -> Data {
        var r = URLRequest(url: req.url)
        r.httpMethod = req.method
        r.httpBody = req.body
        r.timeoutInterval = 30
        for (k, v) in req.headers { r.setValue(v, forHTTPHeaderField: k) }
        if req.body != nil, r.value(forHTTPHeaderField: "Content-Type") == nil {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.other("No HTTP response") }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.unauthorized(bodyText.prefix(300).description)
        default: throw ProviderError.http(status: http.statusCode, body: bodyText)
        }
    }

    public func json<T: Decodable>(_ type: T.Type, _ req: Request) async throws -> T {
        let data = try await data(req)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding("\(error)")
        }
    }

    public static func url(_ base: String, query: [String: String?]) -> URL {
        var comps = URLComponents(string: base)!
        let items = query.compactMap { k, v -> URLQueryItem? in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { comps.queryItems = items.sorted { $0.name < $1.name } }
        return comps.url!
    }
}
