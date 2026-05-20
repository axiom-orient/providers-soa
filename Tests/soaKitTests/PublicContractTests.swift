import XCTest
@testable import soaKit

final class PublicContractTests: XCTestCase {
    func testDefaultMacOSAuthPathContract() {
        XCTAssertEqual(SoaClient.defaultMacOSAuthPath, "~/.codex/auth.json")
        XCTAssertEqual(SoaClient.defaultMacOSAuthRelativePath, ".codex/auth.json")
    }

    func testDefaultCodexClientVersionContract() {
        XCTAssertEqual(SoaClient.defaultCodexClientVersion, "0.130.0")
    }

    func testResponseOutputTextJoinsAssistantOutputTextContent() {
        let response = ResponsesResponse(
            status: 200,
            body: .object([
                "output": .array([
                    .object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .array([
                            .object([
                                "type": .string("output_text"),
                                "text": .string("OK"),
                            ]),
                            .object([
                                "type": .string("output_text"),
                                "text": .string(" done"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(response.outputText, "OK done")
    }

    func testBrowserReloginDefaultsUseCodexCompatibleCallback() {
        let options = BrowserReloginOptions()
        XCTAssertTrue(options.openBrowser)
        XCTAssertEqual(options.callbackPort, 1455)
        XCTAssertEqual(options.timeoutSeconds, 180)
        XCTAssertNil(options.persistPath)
    }
}
