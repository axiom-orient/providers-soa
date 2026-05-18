import Foundation

public enum ErrorCategory: String, Sendable, Equatable {
    case authMissing = "auth_missing"
    case authMalformed = "auth_malformed"
    case authUnsupported = "auth_unsupported"
    case authReadFailed = "auth_read_failed"
    case credentialInsufficient = "credential_insufficient"
    case authRefreshUnavailable = "auth_refresh_unavailable"
    case authRefreshFailed = "auth_refresh_failed"
    case keychainUnavailable = "keychain_unavailable"
    case keychainFailure = "keychain_failure"
    case responsesRequestFailed = "responses_request_failed"
    case invalidConfiguration = "invalid_configuration"
    case operationInProgress = "operation_in_progress"
    case reloginRequired = "relogin_required"
    case reloginTimeout = "relogin_timeout"
    case reloginDenied = "relogin_denied"
    case tokenExchangeFailed = "token_exchange_failed"
    case persistFailed = "persist_failed"
    case transport = "transport"
}

public struct SoaError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let category: ErrorCategory
    public let message: String
    public let remediationHint: String
    public let path: String?
    public let status: Int?

    public init(
        category: ErrorCategory,
        message: String,
        remediationHint: String,
        path: String? = nil,
        status: Int? = nil
    ) {
        self.category = category
        self.message = message
        self.remediationHint = remediationHint
        self.path = path
        self.status = status
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

extension SoaError {
    static func authMissing(path: String) -> Self {
        .init(
            category: .authMissing,
            message: "credential source is missing at \(path)",
            remediationHint: "On iPhone/iPad, import auth.json into Keychain or inject an API key. On macOS, provide ~/.codex/auth.json, set authPath, or fall back to OPENAI_API_KEY.",
            path: path
        )
    }

    static func authMalformed(_ message: String) -> Self {
        .init(
            category: .authMalformed,
            message: "credential source is malformed: \(sanitizeMessage(message))",
            remediationHint: "Repair the stored credential or re-import a valid auth payload."
        )
    }

    static func authUnsupported(_ message: String) -> Self {
        .init(
            category: .authUnsupported,
            message: "credential source shape is unsupported: \(sanitizeMessage(message))",
            remediationHint: "Use an OpenAI API key or a ChatGPT access token with account_id. macOS managed refresh additionally requires refresh_token in the auth file."
        )
    }

    static func authReadFailed(path: String, _ message: String) -> Self {
        .init(
            category: .authReadFailed,
            message: "credential source could not be read at \(path): \(sanitizeMessage(message))",
            remediationHint: "Check file permissions or the resolved credential source.",
            path: path
        )
    }

    static func credentialInsufficient() -> Self {
        .init(
            category: .credentialInsufficient,
            message: "credential is insufficient for the selected transport",
            remediationHint: "Use an OpenAI API key for OpenAI transport, or inject a ChatGPT access token plus account_id for ChatGPT transport. On macOS, auth refresh also requires refresh_token in the file-backed auth source."
        )
    }

    static func authRefreshUnavailable(_ message: String? = nil) -> Self {
        .init(
            category: .authRefreshUnavailable,
            message: message.map { "credential refresh is unavailable: \(sanitizeMessage($0))" } ?? "credential refresh is unavailable for the current source",
            remediationHint: "Refresh is supported only for file-backed ChatGPT auth on macOS-class environments with refresh_token. iPhone/iPad Keychain mode does not refresh."
        )
    }

    static func authRefreshFailed(_ message: String, path: String? = nil) -> Self {
        .init(
            category: .authRefreshFailed,
            message: "credential refresh failed: \(sanitizeMessage(message))",
            remediationHint: "Refresh the macOS auth.json source again, or replace it with a newly exported credential file.",
            path: path
        )
    }

    static func keychainUnavailable() -> Self {
        .init(
            category: .keychainUnavailable,
            message: "keychain is unavailable on this platform",
            remediationHint: "Use a file-backed auth source on macOS, or run on an Apple platform with Security.framework."
        )
    }

    static func keychainFailure(_ message: String) -> Self {
        .init(
            category: .keychainFailure,
            message: "keychain operation failed: \(sanitizeMessage(message))",
            remediationHint: "Check the app entitlements and Keychain accessibility settings."
        )
    }

    static func responsesRequestFailed(status: Int? = nil, _ message: String) -> Self {
        let suffix = status.map { " with status \($0)" } ?? ""
        return .init(
            category: .responsesRequestFailed,
            message: "responses request failed\(suffix): \(sanitizeMessage(message))",
            remediationHint: "Verify the model, the request body, and whether the credential is still valid. macOS file-backed ChatGPT auth can also be renewed with refreshAuth().",
            status: status
        )
    }

    static func invalidConfiguration(_ message: String) -> Self {
        .init(
            category: .invalidConfiguration,
            message: "invalid configuration: \(sanitizeMessage(message))",
            remediationHint: "Fix the client configuration and retry."
        )
    }

    static func operationInProgress(_ message: String? = nil) -> Self {
        .init(
            category: .operationInProgress,
            message: message.map { "operation is already in progress: \(sanitizeMessage($0))" } ?? "operation is already in progress",
            remediationHint: "Wait for the active response send to finish before starting another network-affecting operation on the same client."
        )
    }

    static func reloginRequired() -> Self {
        .init(
            category: .reloginRequired,
            message: "browser re-login is required",
            remediationHint: "Run browser re-login or provide a valid auth source."
        )
    }

    static func reloginTimeout() -> Self {
        .init(
            category: .reloginTimeout,
            message: "browser re-login timed out",
            remediationHint: "Retry browser re-login and complete the callback before the timeout."
        )
    }

    static func reloginDenied(_ message: String) -> Self {
        .init(
            category: .reloginDenied,
            message: "browser re-login was denied: \(sanitizeMessage(message))",
            remediationHint: "Retry browser re-login with an allowed account/workspace."
        )
    }

    static func tokenExchangeFailed(_ message: String, status: Int? = nil) -> Self {
        .init(
            category: .tokenExchangeFailed,
            message: "token exchange failed: \(sanitizeMessage(message))",
            remediationHint: "Retry browser re-login. If API-key exchange fails, verify OpenAI Platform organization/project setup.",
            status: status
        )
    }

    static func persistFailed(path: String, _ message: String) -> Self {
        .init(
            category: .persistFailed,
            message: "credential persistence failed at \(path): \(sanitizeMessage(message))",
            remediationHint: "Use an explicit persist path or check file permissions.",
            path: path
        )
    }

    static func transport(_ message: String) -> Self {
        .init(
            category: .transport,
            message: "transport failure: \(sanitizeMessage(message))",
            remediationHint: "Check connectivity, endpoint reachability, and TLS trust."
        )
    }
}

func sanitizeMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return trimmed
    }

    var sanitized = trimmed
    sanitized = redactPrefixedSecrets(
        in: sanitized,
        prefixes: ["Bearer ", "sk-proj-", "sk-", "rft_", "atk_", "sess_"]
    )
    sanitized = redactJWTLikeSegments(in: sanitized)
    sanitized = redactLongOpaqueTokens(in: sanitized)
    return sanitized
}

private func redactPrefixedSecrets(in input: String, prefixes: [String]) -> String {
    prefixes.reduce(input) { partial, prefix in
        replacePrefixedSecretOccurrences(in: partial, prefix: prefix)
    }
}

private func replacePrefixedSecretOccurrences(in input: String, prefix: String) -> String {
    var output = input
    while let range = output.range(of: prefix) {
        var end = range.upperBound
        while end < output.endIndex, isSecretCharacter(output[end]) {
            end = output.index(after: end)
        }
        output.replaceSubrange(range.lowerBound..<end, with: "<redacted>")
    }
    return output
}

private func isSecretCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." || character == "~"
}

private func redactJWTLikeSegments(in input: String) -> String {
    let parts = input.split(separator: " ", omittingEmptySubsequences: false)
    let rewritten = parts.map { part -> String in
        let token = String(part)
        if token.split(separator: ".").count == 3,
           token.contains("eyJ") {
            return "<redacted>"
        }
        return token
    }
    return rewritten.joined(separator: " ")
}

private func redactLongOpaqueTokens(in input: String) -> String {
    let parts = input.split(separator: " ", omittingEmptySubsequences: false)
    let rewritten = parts.map { part -> String in
        let token = String(part)
        guard token.count >= 48 else { return token }
        let alphaNumericCount = token.unicodeScalars.filter(CharacterSet.alphanumerics.contains).count
        guard alphaNumericCount >= 32 else { return token }
        guard !token.contains("/") && !token.contains("://") else { return token }
        return "<redacted>"
    }
    return rewritten.joined(separator: " ")
}

func sanitizeURLForDisplay(_ input: String) -> String {
    guard var components = URLComponents(string: input) else { return "" }
    components.user = nil
    components.password = nil
    components.fragment = nil
    if let items = components.queryItems {
        components.queryItems = items.map { item in
            switch item.name {
            case "access_token", "api_key", "client_secret", "code", "code_verifier", "id_token", "key", "refresh_token", "requested_token", "state", "subject_token", "token":
                return URLQueryItem(name: item.name, value: "<redacted>")
            default:
                return item
            }
        }
    }
    return components.string ?? input
}

func safeJSONErrorMessage(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unknown error" }
    if let data = trimmed.data(using: .utf8), let value = try? JSONValue.decode(from: data) {
        if let message = value["error"]?["message"]?.stringValue, !message.isEmpty {
            return sanitizeMessage(message)
        }
        if let message = value["message"]?.stringValue, !message.isEmpty {
            return sanitizeMessage(message)
        }
        if let code = value["error"]?["code"]?.stringValue, !code.isEmpty {
            return sanitizeMessage(code)
        }
    }
    return sanitizeMessage(trimmed)
}
