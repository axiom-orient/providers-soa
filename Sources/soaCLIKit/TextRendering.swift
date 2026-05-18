import soaKit
import Foundation

public enum CLITextRenderer {
    public static func renderAuthStatus(_ state: AuthState) -> String {
        let lastRefresh = state.lastRefresh.map(rfc3339) ?? "none"
        let accountID = state.accountID ?? "none"
        return [
            "auth_path=\(state.authPath)",
            "path_source=\(state.pathSource.rawValue)",
            "credential_shape=\(state.credentialShape.rawValue)",
            "readiness=\(state.readiness.rawValue)",
            "transport=\(state.transportKind?.rawValue ?? "none")",
            "has_openai_api_key=\(state.hasOpenAIAPIKey)",
            "has_refresh_token=\(state.hasRefreshToken)",
            "account_id=\(accountID)",
            "last_refresh=\(lastRefresh)",
            "remediation_hint=\(state.remediationHint)",
        ].joined(separator: "\n")
    }

    public static func renderAuthRefresh(_ outcome: AuthRefreshOutcome) -> String {
        var lines = renderAuthStatus(outcome.authState).components(separatedBy: "\n")
        lines.append("persisted_to=\(outcome.persistedTo ?? "none")")
        return lines.joined(separator: "\n")
    }

    public static func renderReloginStarted(authURL: String, callbackPort: UInt16, openedBrowser: Bool) -> String {
        let browserLine = openedBrowser ? "browser_opened=true" : "browser_opened=false"
        return [
            "relogin=started",
            browserLine,
            "auth_url=\(authURL)",
            "callback_url=http://localhost:\(callbackPort)/auth/callback",
        ].joined(separator: "\n")
    }

    public static func renderBrowserRelogin(_ outcome: BrowserReloginOutcome) -> String {
        var lines = renderAuthStatus(outcome.authState).components(separatedBy: "\n")
        lines.insert("relogin=completed", at: 0)
        lines.append("callback_port=\(outcome.callbackPort)")
        lines.append("persisted_to=\(outcome.persistedTo ?? "none")")
        return lines.joined(separator: "\n")
    }

    public static func renderError(_ error: Error) -> String {
        if let providerError = error as? SoaError {
            return [
                providerError.message,
                "category=\(providerError.category.rawValue)",
                "remediation_hint=\(providerError.remediationHint)",
            ].joined(separator: "\n")
        }
        return String(describing: error)
    }

    public static func usage(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--api-key] [--api-key-value KEY] [--auth-path PATH]
                            [--base-url URL] [--issuer URL] [--default-model MODEL]
                            [--default-effort EFFORT] [--client-version VERSION]
                            [--organization ORG] [--project PROJECT]
                            [--client-request-id ID] <command>

        Commands:
          send <prompt> [--model MODEL] [--effort EFFORT] [--stream]
          models list
          auth status
          auth refresh
          relogin [--no-browser] [--callback-port PORT] [--timeout-seconds SECONDS]
                  [--persist-path PATH] [--issuer URL] [--client-id ID]
                  [--allowed-workspace-id ID]

        Rules:
          no --api-key flag => ChatGPT backend transport
          --api-key => OpenAI API transport
          --api-key-value => OpenAI API transport with an injected API key
          fallback env => OPENAI_API_KEY
          default auth source => iPhone/iPad Keychain, macOS ~/.codex/auth.json
          default client version => \(SoaClient.defaultCodexClientVersion)
          auth refresh => macOS-class file-backed ChatGPT auth only
          relogin => browser OAuth flow that writes auth.json and activates OpenAI API transport
        """
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
