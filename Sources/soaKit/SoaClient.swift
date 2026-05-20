import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor SoaClient {
    public static let defaultResponsesBaseURL = "https://api.openai.com"
    public static let defaultChatGPTResponsesBaseURL = "https://chatgpt.com/backend-api/codex"
    public static let defaultAuthIssuerURL = "https://auth.openai.com"
    public static let defaultCodexClientVersion = "0.130.0"
    static let defaultOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let defaultMacOSAuthRelativePath = ".codex/auth.json"
    public static let defaultMacOSAuthPath = "~/.codex/auth.json"

    let configuration: SoaConfiguration
    let session: URLSession
    var runtimeOverride: RuntimeOverride?
    var responseSendInFlight: Bool

    public init(
        configuration: SoaConfiguration = .init(),
        session: URLSession? = nil
    ) throws {
        self.configuration = SoaConfiguration(
            authPath: configuration.authPath?.nilIfEmpty,
            authHome: configuration.authHome?.nilIfEmpty,
            preferredTransportKind: configuration.preferredTransportKind,
            defaultModel: configuration.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            defaultReasoningEffort: configuration.defaultReasoningEffort,
            responsesBaseURL: try Self.normalizeOptionalURL(configuration.responsesBaseURL),
            authIssuerURL: try Self.normalizeURL(configuration.authIssuerURL, defaultValue: Self.defaultAuthIssuerURL),
            clientVersion: Self.normalizeClientVersion(configuration.clientVersion),
            organization: configuration.organization?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            project: configuration.project?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            clientRequestID: try Self.normalizeClientRequestID(configuration.clientRequestID)
        )
        self.session = session ?? makeSecureDefaultSession()
        self.runtimeOverride = nil
        self.responseSendInFlight = false
    }

    public func authState() throws -> AuthState {
        try inspectAuth().state
    }

    public func transportKind() throws -> ResponsesTransportKind {
        guard let kind = try authState().transportKind else {
            throw SoaError.credentialInsufficient()
        }
        return kind
    }

    func beginExclusiveResponseSend() throws {
        guard !responseSendInFlight else {
            throw SoaError.operationInProgress(
                "another response send is already in flight on this client"
            )
        }
        responseSendInFlight = true
    }

    func endExclusiveResponseSend() {
        responseSendInFlight = false
    }

    func clearRuntimeOverrideState() {
        runtimeOverride = nil
    }

    func assertNoActiveResponseSend(operation: String) throws {
        guard !responseSendInFlight else {
            throw SoaError.operationInProgress(
                "\(operation) is blocked while a response send is already in flight"
            )
        }
    }

    func sharedCredentialCoordinationKey(for auth: ResolvedResponsesAuth) throws -> SharedCredentialCoordinationKey? {
        guard auth.transport == .chatGPTBackend else {
            return nil
        }
        let state = try authState()
        switch state.pathSource {
        case .explicitAuthPath, .explicitAuthHome, .codexHomeEnv, .defaultHome:
            return SharedCredentialCoordinationKey(
                transport: .chatGPTBackend,
                descriptor: state.authPath
            )
        }
    }

    static func normalizeOptionalURL(_ input: String?) throws -> String? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw SoaError.invalidConfiguration("URL configuration values must not be empty")
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw SoaError.invalidConfiguration("invalid URL \(String(reflecting: trimmed))")
        }
        return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func normalizeURL(_ input: String?, defaultValue: String) throws -> String {
        try normalizeOptionalURL(input) ?? defaultValue
    }

    static func normalizeClientVersion(_ input: String?) -> String {
        input?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ProcessInfo.processInfo.environment["CODEX_CLIENT_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? codexHomeLatestVersion()
            ?? defaultCodexClientVersion
    }

    static func normalizeClientRequestID(_ input: String?) throws -> String? {
        guard let value = input?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        guard value.utf8.count <= 512 else {
            throw SoaError.invalidConfiguration("client request id must be at most 512 ASCII bytes")
        }
        guard value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw SoaError.invalidConfiguration("client request id must contain only printable ASCII characters")
        }
        return value
    }

    static func codexHomeLatestVersion() -> String? {
        #if os(macOS)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/version.json")
            .path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = root["latest_version"] as? String
        else {
            return nil
        }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        #else
        return nil
        #endif
    }
}

private func makeSecureDefaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration)
}
