import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import soaKit

final class SharedCoordinationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedURLProtocolStub.reset()
    }

    override func tearDown() {
        SharedURLProtocolStub.reset()
        super.tearDown()
    }

    func testSharedCoordinatorAllowsMultipleConcurrentSendsForSameCredentialKey() async {
        let key = SharedCredentialCoordinationKey(
            transport: .chatGPTBackend,
            descriptor: UUID().uuidString
        )

        async let first: Void = SharedCredentialCoordinator.shared.beginSend(for: key)
        async let second: Void = SharedCredentialCoordinator.shared.beginSend(for: key)
        _ = await (first, second)

        await SharedCredentialCoordinator.shared.endSend(for: key)
        await SharedCredentialCoordinator.shared.endSend(for: key)
    }

    func testConcurrentClientsShareSingleRefreshBeforeSends() async throws {
        let authPath = try sharedTemporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_old","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = SharedRequestCounters()

        SharedURLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                if authorization == "Bearer atk_old" {
                    return sharedStubResponse(
                        url: url,
                        status: 401,
                        body: #"{"error":{"code":"invalid_token"}}"#
                    )
                }
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/oauth/token"):
                counters.increment("refresh")
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: #"{"access_token":"atk_new","refresh_token":"rft_new","account_id":"ws_123"}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
                XCTAssertEqual(token, "Bearer atk_new")
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
                )
            default:
                return sharedStubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let first = try makeSharedClient(authPath: authPath)
        let second = try makeSharedClient(authPath: authPath)

        async let firstResponse = first.createResponse(ResponsesRequest("first"))
        async let secondResponse = second.createResponse(ResponsesRequest("second"))
        _ = try await firstResponse
        _ = try await secondResponse

        XCTAssertEqual(counters.value(for: "refresh"), 1)
        XCTAssertEqual(counters.value(for: "responses"), 2)
    }

    func testRefreshWaitsForOtherClientSendToFinish() async throws {
        let authPath = try sharedTemporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_valid","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = SharedRequestCounters()
        let postStarted = DispatchSemaphore(value: 0)
        let allowPostToFinish = DispatchSemaphore(value: 0)

        SharedURLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                postStarted.signal()
                _ = allowPostToFinish.wait(timeout: .now() + 5)
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
                )
            case ("POST", "/oauth/token"):
                counters.increment("refresh")
                return sharedStubResponse(
                    url: url,
                    status: 200,
                    body: #"{"access_token":"atk_new","refresh_token":"rft_new","account_id":"ws_123"}"#
                )
            default:
                return sharedStubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let sender = try makeSharedClient(authPath: authPath)
        let refresher = try makeSharedClient(authPath: authPath)

        let sendTask = Task { try await sender.createResponse(ResponsesRequest("first")) }
        XCTAssertEqual(postStarted.wait(timeout: .now() + 5), .success)

        let refreshTask = Task { try await refresher.refreshAuth() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counters.value(for: "refresh"), 0)

        allowPostToFinish.signal()
        _ = try await sendTask.value
        _ = try await refreshTask.value
        XCTAssertEqual(counters.value(for: "refresh"), 1)
    }

    func testChatGPTSSEParserRebuildsOutputTextFromIncrementalEvents() throws {
        let sse = """
        event: response.output_text.done
        data: {\"output_index\":0,\"content_index\":0,\"text\":\"Hel\"}

        event: response.output_text.done
        data: {\"output_index\":0,\"content_index\":1,\"text\":\"lo\"}

        event: response.completed
        data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}

        """

        let parsed = try parseChatGPTSSEBody(Data(sse.utf8), status: 200)
        let response = ResponsesResponse(status: 200, body: parsed)
        XCTAssertEqual(response.outputText, "Hello")
    }
}

private final class SharedRequestCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key, default: 0] += 1
    }

    func incrementAndReturn(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        values[key, default: 0] += 1
        return values[key, default: 0]
    }

    func value(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[key, default: 0]
    }
}

private final class SharedURLProtocolStub: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: NSError(domain: "SharedURLProtocolStub", code: 1))
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

private func makeSharedStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SharedURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private func sharedStubResponse(url: URL, status: Int, body: String) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
        Data(body.utf8)
    )
}

private func sharedTemporaryAuthFile(_ contents: String) throws -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("auth.json").path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func makeSharedClient(authPath: String) throws -> SoaClient {
    try SoaClient(
        configuration: .init(
            authPath: authPath,
            preferredTransportKind: .chatGPTBackend,
            defaultModel: "gpt-5.4",
            responsesBaseURL: "http://stub.test/backend-api/codex",
            authIssuerURL: "http://stub.test"
        ),
        session: makeSharedStubSession()
    )
}
