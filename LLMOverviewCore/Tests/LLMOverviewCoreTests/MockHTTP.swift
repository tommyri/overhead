import Foundation
@testable import LLMOverviewCore

/// URLProtocol stub. Each `mockHTTP(...)` call gets its own route table and request log, keyed
/// by a private header the session adds, so test suites can run in parallel.
final class MockURLProtocol: URLProtocol {
    struct Route { let pathSuffix: String; let status: Int; let body: Data }

    final class Recorder: @unchecked Sendable {
        let routes: [Route]
        private(set) var requests: [URLRequest] = []
        private let lock = NSLock()
        init(routes: [Route]) { self.routes = routes }
        func record(_ r: URLRequest) { lock.lock(); requests.append(r); lock.unlock() }
    }

    nonisolated(unsafe) private static var recorders: [String: Recorder] = [:]
    private static let lock = NSLock()
    static let headerName = "X-Mock-Session"

    static func register(_ recorder: Recorder) -> String {
        let id = UUID().uuidString
        lock.lock(); recorders[id] = recorder; lock.unlock()
        return id
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let recorder = request.value(forHTTPHeaderField: Self.headerName).flatMap { Self.recorders[$0] }
        Self.lock.unlock()
        guard let recorder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        recorder.record(request)
        guard let route = recorder.routes.first(where: { request.url?.path.hasSuffix($0.pathSuffix) == true }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func mockHTTP(_ routes: [MockURLProtocol.Route]) -> (HTTP, MockURLProtocol.Recorder) {
    let recorder = MockURLProtocol.Recorder(routes: routes)
    let id = MockURLProtocol.register(recorder)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    cfg.httpAdditionalHeaders = [MockURLProtocol.headerName: id]
    return (HTTP(session: URLSession(configuration: cfg)), recorder)
}

func fixtureData(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

func octoberWindow() -> DateInterval {
    let start = DayKey.localDay(year: 2026, month: 9, day: 28)!
    let end = DayKey.localDay(year: 2026, month: 10, day: 5)!
    return DateInterval(start: start, end: end)
}

/// Body of a recorded request, whether URLSession kept it as data or as a stream.
func requestBody(_ req: URLRequest) -> Data? {
    if let b = req.httpBody { return b }
    guard let stream = req.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n > 0 { d.append(buf, count: n) } else { break }
    }
    return d
}
