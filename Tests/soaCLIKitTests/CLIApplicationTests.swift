import XCTest
@testable import soaCLIKit

final class CLIApplicationTests: XCTestCase {
    func testHelpWhenNoArgumentsProvided() async {
        let result = await CLIApplication().run(arguments: ["soa"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Usage:"))
        XCTAssertTrue(result.stdout.contains("relogin"))
        XCTAssertTrue(result.stdout.contains("auth refresh"))
    }

    func testUnknownCommandReturnsFailure() async {
        let result = await CLIApplication().run(arguments: ["soa", "unknown"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("unknown command"))
    }

    func testAuthRefreshRejectsAPIKeyTransport() async {
        let result = await CLIApplication().run(arguments: ["soa", "--api-key", "auth", "refresh"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("--api-key cannot be used with auth refresh"))
    }
}
