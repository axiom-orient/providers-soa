@testable import soaKit
import Foundation
import XCTest

final class GeminiClientTests: XCTestCase {
    func testDecodeAdapterResponseReturnsResultAfterLogLines() throws {
        let data = Data("""
        Loaded cached credentials.
        {"id":"1","result":{"text":"OK","provider":"gemini-cli-core","model":"gemini-2.5-pro"}}

        """.utf8)

        let response: GeminiGenerateResponse = try decodeAdapterResponse(data)

        XCTAssertEqual(response.text, "OK")
        XCTAssertEqual(response.provider, "gemini-cli-core")
        XCTAssertEqual(response.model, "gemini-2.5-pro")
    }

    func testDecodeAdapterResponseMapsRPCError() throws {
        let data = Data(#"{"id":"1","error":{"code":-32601,"message":"unsupported method"}}"#.utf8)

        XCTAssertThrowsError(try decodeAdapterResponse(data) as GeminiGenerateResponse) { error in
            XCTAssertEqual(error as? GeminiError, .rpc(code: -32601, message: "unsupported method"))
        }
    }

    func testGenerateRejectsEmptyPromptBeforeStartingAdapter() throws {
        XCTAssertThrowsError(
            try GeminiClient(nodePath: "/missing/node").generate(GeminiGenerateRequest("  "))
        ) { error in
            XCTAssertEqual(error as? GeminiError, .missingPrompt)
        }
    }

    func testMissingAdapterPathReturnsActionableError() throws {
        XCTAssertThrowsError(
            try GeminiClient(nodePath: "/bin/sh", adapterPath: "/missing/adapter.js")
                .generate(GeminiGenerateRequest("hello"))
        ) { error in
            guard case .adapterStart(let message) = error as? GeminiError else {
                return XCTFail("expected adapterStart, got \(error)")
            }
            XCTAssertTrue(message.contains("adapter not found"))
            XCTAssertTrue(message.contains("npm run build"))
        }
    }

    func testGenerateRoundTripsThroughAdapterProcess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adapter = directory.appendingPathComponent("adapter.sh")
        try """
        read line
        case "$line" in
          *'"prompt":"hello"'*) ;;
          *) printf '%s\\n' '{"id":"1","error":{"code":-32602,"message":"bad prompt"}}'; exit 0 ;;
        esac
        printf '%s\\n' '{"id":"1","result":{"text":"OK","provider":"test-adapter","model":"gemini-test"}}'
        """.write(to: adapter, atomically: true, encoding: .utf8)

        let response = try GeminiClient(nodePath: "/bin/sh", adapterPath: adapter.path)
            .generate(GeminiGenerateRequest("hello").withModel("gemini-test"))

        XCTAssertEqual(response.text, "OK")
        XCTAssertEqual(response.provider, "test-adapter")
        XCTAssertEqual(response.model, "gemini-test")
    }

    func testModelsRoundTripsThroughAdapterProcess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adapter = directory.appendingPathComponent("adapter.sh")
        try """
        read line
        case "$line" in
          *'"method":"models"'*) ;;
          *) printf '%s\\n' '{"id":"1","error":{"code":-32601,"message":"bad method"}}'; exit 0 ;;
        esac
        printf '%s\\n' '{"id":"1","result":{"provider":"gemini-cli-core","releaseChannel":"stable","models":[{"id":"auto","name":"Auto","description":"Let Gemini CLI decide","tier":"auto","source":"gemini-cli-core","quota":null}]}}'
        """.write(to: adapter, atomically: true, encoding: .utf8)

        let response = try GeminiClient(nodePath: "/bin/sh", adapterPath: adapter.path).models()

        XCTAssertEqual(response.provider, "gemini-cli-core")
        XCTAssertEqual(response.releaseChannel, "stable")
        XCTAssertEqual(response.models.first?.id, "auto")
    }
}
