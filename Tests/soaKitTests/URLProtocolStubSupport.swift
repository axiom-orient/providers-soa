import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class URLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func install(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        Self.lock.lock()
        handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolStub", code: 1))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
}

func stubResponse(
    url: URL,
    status: Int,
    body: String,
    headers: [String: String] = ["Content-Type": "application/json"]
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
        Data(body.utf8)
    )
}

func requestBodyString(from request: URLRequest) throws -> String {
    if let body = request.httpBody {
        return String(decoding: body, as: UTF8.self)
    }

    guard let stream = request.httpBodyStream else {
        return ""
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? NSError(domain: "URLProtocolStub", code: 2)
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}
