import XCTest
import Foundation
@testable import soaCLIKit
import soaKit

final class TextRenderingTests: XCTestCase {
    func testRenderAuthStatusIncludesCoreFields() {
        let state = AuthState(
            authPath: "/tmp/auth.json",
            pathSource: .explicitAuthPath,
            credentialShape: .apiKey,
            readiness: .readyOpenAI,
            issueCategory: nil,
            remediationHint: "ok",
            hasOpenAIAPIKey: true,
            hasRefreshToken: false,
            lastRefresh: nil,
            accountID: nil
        )

        let rendered = CLITextRenderer.renderAuthStatus(state)
        XCTAssertTrue(rendered.contains("auth_path=/tmp/auth.json"))
        XCTAssertTrue(rendered.contains("credential_shape=api_key"))
        XCTAssertTrue(rendered.contains("has_refresh_token=false"))
    }
}
