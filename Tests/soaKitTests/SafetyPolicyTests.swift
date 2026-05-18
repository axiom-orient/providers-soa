import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import soaKit

final class SafetyPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCreateResponsePerformsSafePreflightRefreshAndSinglePostSend() async throws {
        let authPath = try temporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_old","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = RequestCounters()

        URLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                if authorization == "Bearer atk_old" {
                    return stubResponse(
                        url: url,
                        status: 401,
                        body: #"{"error":{"code":"invalid_token"}}"#
                    )
                }
                XCTAssertEqual(authorization, "Bearer atk_new")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/oauth/token"):
                counters.increment("refresh")
                let body = try requestBodyString(from: request)
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("refresh_token=rft_old"))
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"access_token":"atk_new","refresh_token":"rft_new","account_id":"ws_123"}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                XCTAssertEqual(authorization, "Bearer atk_new")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n"
                )
            default:
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let client = try SoaClient(
            configuration: .init(
                authPath: authPath,
                preferredTransportKind: .chatGPTBackend,
                responsesBaseURL: "http://stub.test/backend-api/codex",
                authIssuerURL: "http://stub.test"
            ),
            session: makeStubSession()
        )

        let response = try await client.createResponse(ResponsesRequest("hello"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body["id"], .string("resp_1"))
        XCTAssertEqual(counters.value(for: "refresh"), 1)
        XCTAssertEqual(counters.value(for: "responses"), 1)
        XCTAssertEqual(counters.value(for: "models"), 2)

        let persisted = try String(contentsOfFile: authPath, encoding: .utf8)
        XCTAssertTrue(persisted.contains("atk_new"))
        XCTAssertTrue(persisted.contains("rft_new"))
    }

    func testCreateResponseDoesNotRetryPostAfter401() async throws {
        let authPath = try temporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_valid","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = RequestCounters()

        URLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                return stubResponse(
                    url: url,
                    status: 401,
                    body: #"{"error":{"code":"invalid_token"}}"#
                )
            case ("POST", "/oauth/token"):
                counters.increment("refresh")
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"refresh should not happen"}}"#)
            default:
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let client = try SoaClient(
            configuration: .init(
                authPath: authPath,
                preferredTransportKind: .chatGPTBackend,
                defaultModel: "gpt-5.4",
                responsesBaseURL: "http://stub.test/backend-api/codex",
                authIssuerURL: "http://stub.test"
            ),
            session: makeStubSession()
        )

        do {
            _ = try await client.createResponse(ResponsesRequest("hello"))
            XCTFail("expected createResponse to fail")
        } catch let error as SoaError {
            XCTAssertEqual(error.category, .responsesRequestFailed)
            XCTAssertTrue(error.message.contains("not retried automatically"))
        }

        XCTAssertEqual(counters.value(for: "responses"), 1)
        XCTAssertEqual(counters.value(for: "refresh"), 0)
        XCTAssertEqual(counters.value(for: "models"), 1)
    }

    func testConcurrentCreateResponseRejectsSecondSendBeforeFirstCompletes() async throws {
        let authPath = try temporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_valid","account_id":"ws_123"}}"#
        )
        let counters = RequestCounters()
        let postStarted = DispatchSemaphore(value: 0)
        let allowPostToFinish = DispatchSemaphore(value: 0)

        URLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                postStarted.signal()
                _ = allowPostToFinish.wait(timeout: .now() + 5)
                return stubResponse(
                    url: url,
                    status: 200,
                    body: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_blocked\",\"status\":\"completed\"}}\n\n"
                )
            default:
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let client = try SoaClient(
            configuration: .init(
                authPath: authPath,
                preferredTransportKind: .chatGPTBackend,
                defaultModel: "gpt-5.4",
                responsesBaseURL: "http://stub.test/backend-api/codex"
            ),
            session: makeStubSession()
        )

        let firstTask = Task { try await client.createResponse(ResponsesRequest("first")) }
        XCTAssertEqual(postStarted.wait(timeout: .now() + 5), .success)

        do {
            _ = try await client.createResponse(ResponsesRequest("second"))
            XCTFail("expected second send to be rejected")
        } catch let error as SoaError {
            XCTAssertEqual(error.category, .operationInProgress)
        }

        allowPostToFinish.signal()
        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.body["id"], .string("resp_blocked"))
        XCTAssertEqual(counters.value(for: "responses"), 1)
    }


    func testNetworkAffectingOperationsAreRejectedWhileResponseSendActive() async throws {
        let authPath = try temporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_valid","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = RequestCounters()
        let postStarted = DispatchSemaphore(value: 0)
        let allowPostToFinish = DispatchSemaphore(value: 0)

        URLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/backend-api/codex/responses"):
                counters.increment("responses")
                postStarted.signal()
                _ = allowPostToFinish.wait(timeout: .now() + 5)
                return stubResponse(
                    url: url,
                    status: 200,
                    body: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_guarded\",\"status\":\"completed\"}}\n\n"
                )
            default:
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let client = try SoaClient(
            configuration: .init(
                authPath: authPath,
                preferredTransportKind: .chatGPTBackend,
                defaultModel: "gpt-5.4",
                responsesBaseURL: "http://stub.test/backend-api/codex",
                authIssuerURL: "http://stub.test"
            ),
            session: makeStubSession()
        )

        let firstTask = Task { try await client.createResponse(ResponsesRequest("first")) }
        XCTAssertEqual(postStarted.wait(timeout: .now() + 5), .success)

        do {
            _ = try await client.listModels()
            XCTFail("expected models list to be rejected")
        } catch let error as SoaError {
            XCTAssertEqual(error.category, .operationInProgress)
        }

        do {
            _ = try await client.refreshAuth()
            XCTFail("expected auth refresh to be rejected")
        } catch let error as SoaError {
            XCTAssertEqual(error.category, .operationInProgress)
        }

        allowPostToFinish.signal()
        let firstResponse = try await firstTask.value
        XCTAssertEqual(firstResponse.body["id"], .string("resp_guarded"))
        XCTAssertEqual(counters.value(for: "responses"), 1)
        XCTAssertEqual(counters.value(for: "models"), 1)
    }

    func testConcurrentModelListingUsesSingleRefreshExchange() async throws {
        let authPath = try temporaryAuthFile(
            #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_old","refresh_token":"rft_old","account_id":"ws_123"}}"#
        )
        let counters = RequestCounters()

        URLProtocolStub.install { request in
            let url = try XCTUnwrap(request.url)
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/backend-api/codex/models"):
                counters.increment("models")
                if authorization == "Bearer atk_old" {
                    return stubResponse(
                        url: url,
                        status: 401,
                        body: #"{"error":{"code":"invalid_token"}}"#
                    )
                }
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"models":[{"slug":"gpt-5.4","priority":1,"visibility":"public","supported_in_api":true}]}"#
                )
            case ("POST", "/oauth/token"):
                counters.increment("refresh")
                return stubResponse(
                    url: url,
                    status: 200,
                    body: #"{"access_token":"atk_new","refresh_token":"rft_new","account_id":"ws_123"}"#
                )
            default:
                return stubResponse(url: url, status: 500, body: #"{"error":{"message":"unexpected request"}}"#)
            }
        }

        let client = try SoaClient(
            configuration: .init(
                authPath: authPath,
                preferredTransportKind: .chatGPTBackend,
                responsesBaseURL: "http://stub.test/backend-api/codex",
                authIssuerURL: "http://stub.test"
            ),
            session: makeStubSession()
        )

        async let first = client.listModels()
        async let second = client.listModels()
        let firstModels = try await first
        let secondModels = try await second

        XCTAssertEqual(firstModels.first?.slug, "gpt-5.4")
        XCTAssertEqual(secondModels.first?.slug, "gpt-5.4")
        XCTAssertEqual(counters.value(for: "refresh"), 1)
    }
}

private final class RequestCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key, default: 0] += 1
    }

    func value(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[key, default: 0]
    }
}

private func temporaryAuthFile(_ contents: String) throws -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("auth.json").path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}
