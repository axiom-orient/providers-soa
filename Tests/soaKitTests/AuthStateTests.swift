import XCTest
@testable import soaKit

final class AuthStateTests: XCTestCase {
    func testOpenAIAPIKeyAuthStateFromExplicitPath() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("auth.json").path
        try #"{"OPENAI_API_KEY":"sk-proj-test"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authPath: path))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyOpenAI)
        XCTAssertEqual(state.pathSource, .explicitAuthPath)
        XCTAssertEqual(state.credentialShape, .apiKey)
        XCTAssertTrue(state.hasOpenAIAPIKey)
        XCTAssertFalse(state.hasRefreshToken)
    }

    func testChatGPTAuthStateFromLeanInjectedShape() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("auth.json").path
        try #"{"access_token":"atk_test","account_id":"ws_123"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authPath: path, preferredTransportKind: .chatGPTBackend))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyChatGPT)
        XCTAssertEqual(state.credentialShape, .chatgptExternalTokens)
        XCTAssertEqual(state.accountID, "ws_123")
        XCTAssertFalse(state.hasRefreshToken)
    }

    func testManagedChatGPTAuthReportsRefreshToken() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("auth.json").path
        try #"{"auth_mode":"chatgpt","tokens":{"access_token":"atk_test","refresh_token":"rft_test","id_token":"header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoid3NfMTIzIn19.sig"},"last_refresh":"2026-03-30T10:00:00Z"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authPath: path, preferredTransportKind: .chatGPTBackend))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyChatGPT)
        XCTAssertEqual(state.credentialShape, .chatgptManaged)
        XCTAssertEqual(state.accountID, "ws_123")
        XCTAssertTrue(state.hasRefreshToken)
        XCTAssertNotNil(state.lastRefresh)
    }

    func testMissingAuthProducesMissingState() async throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathComponent("auth.json").path
        let client = try SoaClient(configuration: .init(authPath: path))
        let state = try await client.authState()
        XCTAssertEqual(state.readiness, .authRefreshRequired)
        XCTAssertEqual(state.issueCategory, .authMissing)
    }

    func testMalformedAuthProducesInvalidState() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("auth.json").path
        try "{not-json}".write(toFile: path, atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authPath: path))
        let state = try await client.authState()
        XCTAssertEqual(state.readiness, .invalid)
        XCTAssertEqual(state.issueCategory, .authMalformed)
    }

    func testAuthHomeResolvesAuthJSON() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"OPENAI_API_KEY":"sk-proj-test"}"#.write(to: directory.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authHome: directory.path, preferredTransportKind: .openAIAPI))
        let state = try await client.authState()

        XCTAssertEqual(state.pathSource, .explicitAuthHome)
        XCTAssertEqual(state.readiness, .readyOpenAI)
    }
}
