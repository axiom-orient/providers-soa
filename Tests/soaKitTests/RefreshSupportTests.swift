import XCTest
@testable import soaKit

final class RefreshSupportTests: XCTestCase {
    func testRewriteRefreshedAuthJSONPreservesShapeAndUpdatesTokens() throws {
        let raw = try JSONValue.decode(from: Data(#"{"auth_mode":"chatgpt","OPENAI_API_KEY":"sk-proj-test","tokens":{"access_token":"atk_old","refresh_token":"rft_old","account_id":"ws_old"},"last_refresh":"2026-03-30T10:00:00Z","other":"keep"}"#.utf8))
        let parsed = try parseAuthJSON(raw)
        let updated = try rewriteRefreshedAuthJSON(
            parsed: parsed,
            refreshed: .init(
                accessToken: "atk_new",
                refreshToken: "rft_new",
                idToken: nil,
                accountID: "ws_new",
                lastRefresh: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(updated["other"], .string("keep"))
        XCTAssertEqual(updated["tokens"]?["access_token"], .string("atk_new"))
        XCTAssertEqual(updated["tokens"]?["refresh_token"], .string("rft_new"))
        XCTAssertEqual(updated["tokens"]?["account_id"], .string("ws_new"))
        XCTAssertEqual(updated["OPENAI_API_KEY"], .string("sk-proj-test"))
    }

    func testSafeJSONErrorMessageDoesNotCorruptInvalidTokenCode() {
        let message = safeJSONErrorMessage(#"{"error":{"code":"invalid_token"}}"#)
        XCTAssertEqual(message, "invalid_token")
    }
}
