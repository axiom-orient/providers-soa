import XCTest
@testable import soaCLIKit

final class CLIParserTests: XCTestCase {
    func testParseSendWithGlobalOverrides() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "--json",
            "codex",
            "--auth-path", "/tmp/auth.json",
            "--auth-home", "/tmp/codex-home",
            "--base-url", "https://example.com",
            "--issuer", "https://issuer.example.com",
            "--client-version", "0.130.0",
            "send",
            "hello",
            "--model", "gpt-5"
        ])

        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.configuration.authPath, "/tmp/auth.json")
        XCTAssertEqual(invocation.configuration.authHome, "/tmp/codex-home")
        XCTAssertEqual(invocation.configuration.responsesBaseURL, "https://example.com")
        XCTAssertEqual(invocation.configuration.authIssuerURL, "https://issuer.example.com")
        XCTAssertEqual(invocation.configuration.clientVersion, "0.130.0")
        XCTAssertEqual(invocation.command, .codex(.send(prompt: "hello", stdin: false, model: "gpt-5", effort: nil, stream: false)))
    }

    func testParseAuthStatusCommand() throws {
        let invocation = try CLIParser().parse(arguments: ["soa", "codex", "auth", "status"])
        XCTAssertEqual(invocation.command, .codex(.authStatus))
    }

    func testParseReloginCommand() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "codex",
            "relogin",
            "--no-browser",
            "--callback-port", "0",
            "--timeout-seconds", "30",
            "--persist-path", "/tmp/auth.json",
            "--client-id", "client_123",
            "--allowed-workspace-id", "ws_123",
            "--issuer", "https://issuer.example.com"
        ])

        guard case let .codex(.relogin(options)) = invocation.command else {
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

    func testParseGeminiGenerateCommand() throws {
        let invocation = try CLIParser().parse(arguments: [
            "soa",
            "--json",
            "gemini",
            "generate",
            "hello",
            "--model", "flash",
            "--adapter-path", "/tmp/adapter.js",
            "--node-path", "/tmp/node"
        ])

        XCTAssertTrue(invocation.json)
        XCTAssertEqual(invocation.command, .gemini(.generate(prompt: "hello", model: "flash", adapterPath: "/tmp/adapter.js", nodePath: "/tmp/node")))
    }
}
