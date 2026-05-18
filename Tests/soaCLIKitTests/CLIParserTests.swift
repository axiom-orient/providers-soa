import XCTest
@testable import soaCLIKit

final class CLIParserTests: XCTestCase {
    func testParseSendWithGlobalOverrides() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "--api-key",
            "--auth-path", "/tmp/auth.json",
            "--base-url", "https://example.com",
            "--issuer", "https://issuer.example.com",
            "--client-version", "0.130.0",
            "send",
            "hello",
            "--model", "gpt-5"
        ])

        XCTAssertTrue(invocation.useAPIKeyTransport)
        XCTAssertEqual(invocation.configuration.authPath, "/tmp/auth.json")
        XCTAssertEqual(invocation.configuration.responsesBaseURL, "https://example.com")
        XCTAssertEqual(invocation.configuration.authIssuerURL, "https://issuer.example.com")
        XCTAssertEqual(invocation.configuration.clientVersion, "0.130.0")
        XCTAssertEqual(invocation.command, .send(prompt: "hello", model: "gpt-5", effort: nil, stream: false))
    }

    func testParseExplicitAPIKeyValue() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "--api-key-value", "sk-cli-test",
            "send",
            "hello"
        ])

        XCTAssertTrue(invocation.useAPIKeyTransport)
        XCTAssertEqual(invocation.configuration.apiKey, "sk-cli-test")
        XCTAssertEqual(invocation.command, .send(prompt: "hello", model: nil, effort: nil, stream: false))
    }

    func testParseAuthStatusCommand() throws {
        let invocation = try CLIParser().parse(arguments: ["soa", "auth", "status"])
        XCTAssertEqual(invocation.command, .authStatus)
    }

    func testParseAuthRefreshCommand() throws {
        let invocation = try CLIParser().parse(arguments: ["soa", "auth", "refresh"])
        XCTAssertEqual(invocation.command, .authRefresh)
    }

    func testParseReloginCommand() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "relogin",
            "--no-browser",
            "--callback-port", "0",
            "--timeout-seconds", "30",
            "--persist-path", "/tmp/auth.json",
            "--client-id", "client_123",
            "--allowed-workspace-id", "ws_123",
            "--issuer", "https://issuer.example.com"
        ])

        guard case let .relogin(options) = invocation.command else {
            return XCTFail("expected relogin command")
        }
        XCTAssertFalse(options.openBrowser)
        XCTAssertEqual(options.callbackPort, 0)
        XCTAssertEqual(options.timeoutSeconds, 30)
        XCTAssertEqual(options.persistPath, "/tmp/auth.json")
        XCTAssertEqual(options.clientID, "client_123")
        XCTAssertEqual(options.allowedWorkspaceID, "ws_123")
        XCTAssertEqual(options.issuer, "https://issuer.example.com")
    }
}
