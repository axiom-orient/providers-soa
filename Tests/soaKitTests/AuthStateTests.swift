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
        XCTAssertEqual(state.readiness, .missing)
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

    func testConfigurationAPIKeyFallbackWinsWhenAuthMissing() async throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathComponent("auth.json").path
        let client = try SoaClient(configuration: .init(authPath: path, apiKey: "sk-test", preferredTransportKind: .openAIAPI))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyOpenAI)
        XCTAssertEqual(state.pathSource, .configurationAPIKey)
        XCTAssertEqual(state.authPath, "config://openai-api-key")
        XCTAssertTrue(state.hasOpenAIAPIKey)
    }

    func testConfigurationAPIKeyFallbackWinsWhenAuthCannotSatisfyOpenAITransport() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("auth.json").path
        try #"{"access_token":"atk_test","account_id":"ws_123"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let client = try SoaClient(configuration: .init(authPath: path, apiKey: "sk-test", preferredTransportKind: .openAIAPI))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyOpenAI)
        XCTAssertEqual(state.pathSource, .configurationAPIKey)
    }

    func testEnvironmentAPIKeyFallbackWinsWhenConfiguredPathMissing() async throws {
        setenv("OPENAI_API_KEY", "sk-env-test", 1)
        defer { unsetenv("OPENAI_API_KEY") }

        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathComponent("auth.json").path
        let client = try SoaClient(configuration: .init(authPath: path, preferredTransportKind: .openAIAPI))
        let state = try await client.authState()

        XCTAssertEqual(state.readiness, .readyOpenAI)
        XCTAssertEqual(state.pathSource, .environmentAPIKey)
        XCTAssertEqual(state.authPath, "env://OPENAI_API_KEY")
    }

    func testImportAuthJSONPrefersChatGPTCredentialWhenBothArePresent() throws {
        let json = #"{"OPENAI_API_KEY":"sk-test","tokens":{"access_token":"atk_test","account_id":"ws_123"}}"#
        let credential = try SoaCredentialStore().importAuthJSONForTesting(json)
        XCTAssertEqual(credential, .chatGPT(accessToken: "atk_test", accountID: "ws_123"))
    }
}

private extension SoaCredentialStore {
    func importAuthJSONForTesting(_ json: String) throws -> SoaCredential {
        guard let data = json.data(using: .utf8) else {
            throw SoaError.authMalformed("auth payload is not valid UTF-8")
        }
        let parsed = try parseAuthJSON(try JSONValue.decode(from: data))
        guard let credential = parsed.normalized.preferredCredential(for: nil) else {
            throw SoaError.credentialInsufficient()
        }
        return credential
    }
}
