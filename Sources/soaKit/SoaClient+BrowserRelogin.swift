import Foundation

public struct BrowserReloginSession: Sendable {
    private let client: SoaClient
    private let inspection: AuthInspection
    private let persistPath: String?
    private let loginSession: BrowserLoginSession

    init(
        client: SoaClient,
        inspection: AuthInspection,
        persistPath: String?,
        loginSession: BrowserLoginSession
    ) {
        self.client = client
        self.inspection = inspection
        self.persistPath = persistPath
        self.loginSession = loginSession
    }

    public var authURL: String { loginSession.authURL }
    public var callbackPort: UInt16 { loginSession.callbackPort }

    public func wait() async throws -> BrowserReloginOutcome {
        let completed = try await loginSession.wait()
        return try await client.finalizeBrowserRelogin(
            inspection: inspection,
            persistPath: persistPath,
            completed: completed
        )
    }
}

extension SoaClient {
    public func reloginBrowser(options: BrowserReloginOptions = .init()) async throws -> BrowserReloginOutcome {
        try await startBrowserReloginSession(options: options).wait()
    }

    public func startBrowserReloginSession(options: BrowserReloginOptions = .init()) async throws -> BrowserReloginSession {
        try assertNoActiveResponseSend(operation: "browser re-login")

        let inspection = try inspectAuth()
        let persistPath = try options.persistPath.map(resolvePersistPath)
        let issuer = try Self.normalizeURL(options.issuer ?? configuration.authIssuerURL, defaultValue: Self.defaultAuthIssuerURL)
        let clientID = (options.clientID ?? Self.defaultOAuthClientID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw SoaError.invalidConfiguration("browser re-login client id must not be empty")
        }
        guard options.timeoutSeconds > 0 else {
            throw SoaError.invalidConfiguration("browser re-login timeout must be greater than zero")
        }

        let loginSession = try await startBrowserLoginSession(
            session: session,
            config: BrowserLoginConfig(
                issuer: issuer,
                clientID: clientID,
                callbackPort: options.callbackPort,
                openBrowser: options.openBrowser,
                timeoutSeconds: options.timeoutSeconds,
                allowedWorkspaceID: options.allowedWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        )

        return BrowserReloginSession(
            client: self,
            inspection: inspection,
            persistPath: persistPath,
            loginSession: loginSession
        )
    }

    func finalizeBrowserRelogin(
        inspection: AuthInspection,
        persistPath: String?,
        completed: CompletedBrowserLogin
    ) throws -> BrowserReloginOutcome {
        let targetPath: String
        let source: ResolvedAuthPathSource
        let document: JSONValue?
        let payload = BrowserReloginAuthPayload(
            openAIAPIKey: completed.apiKey,
            accessToken: completed.tokens.accessToken,
            refreshToken: completed.tokens.refreshToken,
            idToken: completed.tokens.idToken,
            accountID: completed.tokens.accountID,
            lastRefresh: Date()
        )

        if let persistPath {
            targetPath = persistPath
            source = .explicitAuthPath
            document = buildBrowserReloginAuthJSON(payload: payload)
        } else {
            switch inspection.state.issueCategory {
            case .some(.authMalformed), .some(.authUnsupported), .some(.authReadFailed):
                throw SoaError.persistFailed(
                    path: inspection.state.authPath,
                    "current auth file is not safely rewriteable; pass BrowserReloginOptions.persistPath"
                )
            default:
                targetPath = inspection.state.authPath
                source = inspection.state.pathSource
                if let parsed = inspection.parsedFile {
                    document = try rewriteBrowserReloginAuthJSON(parsed: parsed, payload: payload)
                } else {
                    document = buildBrowserReloginAuthJSON(payload: payload)
                }
            }
        }

        let runtimeState = runtimeStateForBrowserRelogin(
            path: targetPath,
            source: source,
            accountID: completed.tokens.accountID
        )
        runtimeOverride = RuntimeOverride(
            token: completed.apiKey,
            transport: .openAIAPI,
            refreshToken: nil,
            authState: runtimeState
        )

        do {
            if let document {
                try persistBrowserReloginAuth(path: targetPath, document: document)
            }
        } catch {
            clearRuntimeOverrideState()
            throw error
        }

        return BrowserReloginOutcome(
            authURL: completed.authURL,
            callbackPort: completed.callbackPort,
            persistedTo: targetPath,
            authState: runtimeState
        )
    }
}

private func resolvePersistPath(_ raw: String) throws -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    guard (expanded as NSString).isAbsolutePath else {
        throw SoaError.invalidConfiguration("BrowserReloginOptions.persistPath must be absolute")
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}
