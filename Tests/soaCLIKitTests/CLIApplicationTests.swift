import XCTest
import Foundation
@testable import soaCLIKit

final class CLIApplicationTests: XCTestCase {
    func testHelpWhenNoArgumentsProvided() async {
        let result = await CLIApplication().run(arguments: ["soa"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage:"))
        XCTAssertTrue(result.stdout.contains("relogin"))
        XCTAssertTrue(result.stdout.contains("gemini"))
    }

    func testUnknownCommandReturnsFailure() async {
        let result = await CLIApplication().run(arguments: ["soa", "unknown"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("unknown provider"))
    }

    func testCodexRejectsUnknownOption() async {
        let result = await CLIApplication().run(arguments: ["soa", "codex", "--unknown-option", "relogin"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("unknown codex option --unknown-option"))
    }

    func testGeminiGenerateRunsAdapterProcess() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adapter = directory.appendingPathComponent("adapter.sh")
        try """
        read line
        printf '%s\\n' '{"id":"1","result":{"text":"OK","provider":"test-adapter","model":"gemini-test"}}'
        """.write(to: adapter, atomically: true, encoding: .utf8)

        let result = await CLIApplication().run(arguments: [
            "soa",
            "gemini",
            "generate",
            "hello",
            "--node-path", "/bin/sh",
            "--adapter-path", adapter.path
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "OK\n")
    }
}
