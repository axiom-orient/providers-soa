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
            "has_refresh_token=\(state.hasRefreshToken)",
            "account_id=\(accountID)",
            "last_refresh=\(lastRefresh)",
            "remediation_hint=\(state.remediationHint)",
        ].joined(separator: "\n")
    }

    public static func renderAuthStatusJSON(_ state: AuthState) throws -> String {
        try prettyJSON([
            "auth_path": .string(state.authPath),
            "path_source": .string(state.pathSource.rawValue),
            "credential_shape": .string(state.credentialShape.rawValue),
            "readiness": .string(state.readiness.rawValue),
            "ready_transport": .string(state.transportKind?.rawValue ?? "none"),
            "has_refresh_token": .bool(state.hasRefreshToken),
            "account_id": .string(state.accountID ?? "none"),
            "last_refresh": .string(state.lastRefresh.map(rfc3339) ?? "none"),
            "remediation_hint": .string(state.remediationHint),
        ])
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

    public static func renderReloginStartedJSON(authURL: String, callbackPort: UInt16) throws -> String {
        try compactJSON([
            "event": .string("started"),
            "auth_url": .string(authURL),
            "callback_port": .number(Double(callbackPort)),
        ])
    }

    public static func renderBrowserRelogin(_ outcome: BrowserReloginOutcome) -> String {
        var lines = renderAuthStatus(outcome.authState).components(separatedBy: "\n")
        lines.insert("relogin=completed", at: 0)
        lines.append("callback_port=\(outcome.callbackPort)")
        lines.append("persisted_to=\(outcome.persistedTo ?? "none")")
        return lines.joined(separator: "\n")
    }

    public static func renderBrowserReloginJSON(_ outcome: BrowserReloginOutcome) throws -> String {
        try compactJSON([
            "event": .string("completed"),
            "auth_url": .string(outcome.authURL),
            "callback_port": .number(Double(outcome.callbackPort)),
            "persisted_to": .string(outcome.persistedTo ?? "none"),
            "account_id": .string(outcome.authState.accountID ?? "none"),
            "ready_transport": .string(outcome.authState.transportKind?.rawValue ?? "none"),
        ])
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

    public static func renderModels(_ models: [ResponsesModelInfo], transport: ResponsesTransportKind) -> String {
        let visible = models
            .sorted { left, right in
                if left.priority != right.priority { return left.priority < right.priority }
                return left.slug < right.slug
            }
            .filter { $0.supportedInAPI && $0.visibility != "hide" && $0.visibility != "hidden" }
        var lines = ["Models (\(transport.rawValue))"]
        if visible.isEmpty {
            lines.append("No visible models are currently available for the configured backend.")
        } else {
            for (index, model) in visible.enumerated() {
                lines.append("\(index + 1). \(model.slug)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func renderSendJSON(_ response: ResponsesResponse) throws -> String {
        try prettyJSON([
            "status": .number(Double(response.status)),
            "request_id": .string(response.meta.requestID ?? "none"),
            "output_text": .string(response.outputText ?? ""),
            "body": response.body,
        ])
    }

    public static func renderStreamEventJSON(_ event: ResponsesStreamEvent) throws -> String {
        try compactJSON([
            "event": .string(event.event),
            "event_type": .string(event.type),
            "text": .string(event.textChunk ?? ""),
            "body": event.body,
        ])
    }

    public static func renderGeminiModels(_ response: GeminiModelsResponse) -> String {
        var lines = ["Gemini models from \(response.provider) (\(response.releaseChannel))"]
        for (index, model) in response.models.enumerated() {
            let quota = model.quota?.remainingFraction.map { " quota \(Int($0 * 100))%" } ?? ""
            let description = model.description.isEmpty ? "" : " - \(model.description)"
            lines.append("\(index + 1). \(model.id) [\(model.tier)]\(quota)\(description)")
        }
        return lines.joined(separator: "\n")
    }

    public static func usage(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--json] codex [--auth-path PATH] [--auth-home DIR]
                            [--base-url URL] [--issuer URL] [--default-model MODEL]
                            [--default-effort EFFORT] [--client-version VERSION]
                            [--organization ORG] [--project PROJECT]
                            [--client-request-id ID] <command>
          \(executableName) [--json] gemini <command>

        Commands:
          codex send <prompt> [--stdin] [--model MODEL] [--effort EFFORT] [--stream]
          codex models list
          codex auth status
          codex relogin [--no-browser] [--callback-port PORT] [--timeout-seconds SECONDS]
                  [--persist-path PATH] [--issuer URL] [--client-id ID]
                  [--allowed-workspace-id ID]
          gemini generate <prompt> [--model MODEL] [--adapter-path PATH] [--node-path PATH]
          gemini models [--adapter-path PATH] [--node-path PATH]

        Rules:
          codex => resolved auth.json decides the usable transport
          default auth source => CODEX_HOME/auth.json, then ~/.codex/auth.json
          default client version => \(SoaClient.defaultCodexClientVersion)
          relogin => browser OAuth flow that refreshes or writes auth.json
          gemini => local Gemini Core Adapter backed by @google/gemini-cli-core
        """
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func prettyJSON(_ object: [String: JSONValue]) throws -> String {
        try JSONValue.object(object).prettyPrinted()
    }

    private static func compactJSON(_ object: [String: JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
    }
}
