import Foundation

struct RuntimeOverride: Sendable, Equatable {
    let token: String
    let transport: ResponsesTransportKind
    let refreshToken: String?
    let authState: AuthState
}

struct AuthInspection: Sendable {
    let location: ResolvedCredentialLocation
    let state: AuthState
    let normalized: NormalizedCredential?
    let parsedFile: ParsedAuthFile?
}

struct ResolvedResponsesAuth: Sendable, Equatable {
    let token: String
    let accountID: String?
    let transport: ResponsesTransportKind
    let refreshToken: String?
}

extension SoaClient {
    func inspectAuth() throws -> AuthInspection {
        if let runtimeOverride {
            return AuthInspection(
                location: .init(
                    descriptor: runtimeOverride.authState.authPath,
                    source: runtimeOverride.authState.pathSource,
                    kind: .file(runtimeOverride.authState.authPath)
                ),
                state: runtimeOverride.authState,
                normalized: nil,
                parsedFile: nil
            )
        }

        let primaryLocation = try AuthPathResolver(authPath: configuration.authPath).resolve()
        let primary = try inspect(location: primaryLocation)

        if shouldKeepPrimary(primary.state) {
            return primary
        }

        if let apiKeyFallback = inspectAPIKeyFallback() {
            return apiKeyFallback
        }

        return primary
    }

    private func inspect(location: ResolvedCredentialLocation) throws -> AuthInspection {
        switch location.kind {
        case .file(let path):
            return try inspectFileAuth(path: path, source: location.source)
        case .keychain(let service):
            return try inspectKeychainAuth(descriptor: location.descriptor, source: location.source, service: service)
        }
    }

    private func shouldKeepPrimary(_ state: AuthState) -> Bool {
        switch configuration.preferredTransportKind {
        case .some(.chatGPTBackend):
            return true
        case .some(.openAIAPI):
            return state.transportKind == .openAIAPI
        case nil:
            return state.isReady
        }
    }

    private func inspectAPIKeyFallback() -> AuthInspection? {
        guard configuration.preferredTransportKind != .chatGPTBackend else {
            return nil
        }

        if let explicitAPIKey = configuration.apiKey?.nilIfEmpty {
            return inspectionForAPIKey(
                explicitAPIKey,
                descriptor: "config://openai-api-key",
                source: .configurationAPIKey,
                remediationHint: "Primary auth.json was unavailable or incompatible, so an injected OpenAI API key is active."
            )
        }

        if let environmentAPIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.nilIfEmpty {
            return inspectionForAPIKey(
                environmentAPIKey,
                descriptor: "env://OPENAI_API_KEY",
                source: .environmentAPIKey,
                remediationHint: "Primary auth.json was unavailable or incompatible, so OPENAI_API_KEY is active."
            )
        }

        return nil
    }

    private func inspectionForAPIKey(
        _ apiKey: String,
        descriptor: String,
        source: ResolvedAuthPathSource,
        remediationHint: String
    ) -> AuthInspection {
        let normalized = normalizedCredential(from: .openAIAPIKey(apiKey))
        return AuthInspection(
            location: .init(descriptor: descriptor, source: source, kind: .file(descriptor)),
            state: AuthState(
                authPath: descriptor,
                pathSource: source,
                credentialShape: normalized.shape,
                readiness: .readyOpenAI,
                issueCategory: nil,
                remediationHint: remediationHint,
                hasOpenAIAPIKey: true,
                hasRefreshToken: false,
                lastRefresh: nil,
                accountID: nil
            ),
            normalized: normalized,
            parsedFile: nil
        )
    }

    private func inspectFileAuth(path: String, source: ResolvedAuthPathSource) throws -> AuthInspection {
        do {
            let raw = try readAuthJSON(path: path)
            let parsed = try parseAuthJSON(raw)
            return AuthInspection(
                location: .init(descriptor: path, source: source, kind: .file(path)),
                state: buildState(descriptor: path, source: source, normalized: parsed.normalized),
                normalized: parsed.normalized,
                parsedFile: parsed
            )
        } catch let error as SoaError where error.category == .authMissing {
            return AuthInspection(
                location: .init(descriptor: path, source: source, kind: .file(path)),
                state: AuthState(
                    authPath: path,
                    pathSource: source,
                    credentialShape: .unknown,
                    readiness: .missing,
                    issueCategory: .authMissing,
                    remediationHint: "Provide ~/.codex/auth.json on macOS or set authPath explicitly.",
                    hasOpenAIAPIKey: false,
                    hasRefreshToken: false,
                    lastRefresh: nil,
                    accountID: nil
                ),
                normalized: nil,
                parsedFile: nil
            )
        } catch let error as SoaError {
            return AuthInspection(
                location: .init(descriptor: path, source: source, kind: .file(path)),
                state: buildInvalidState(descriptor: path, source: source, category: error.category),
                normalized: nil,
                parsedFile: nil
            )
        }
    }

    private func inspectKeychainAuth(
        descriptor: String,
        source: ResolvedAuthPathSource,
        service: String
    ) throws -> AuthInspection {
        do {
            let credential = try SoaCredentialStore(service: service).load()
            guard let credential else {
                return AuthInspection(
                    location: .init(descriptor: descriptor, source: source, kind: .keychain(service: service)),
                    state: AuthState(
                        authPath: descriptor,
                        pathSource: source,
                        credentialShape: .unknown,
                        readiness: .missing,
                        issueCategory: .authMissing,
                        remediationHint: "Inject a credential into Keychain with SoaCredentialStore.save(...) or importAuthJSON(...).",
                        hasOpenAIAPIKey: false,
                        hasRefreshToken: false,
                        lastRefresh: nil,
                        accountID: nil
                    ),
                    normalized: nil,
                    parsedFile: nil
                )
            }
            let normalized = normalizedCredential(from: credential)
            return AuthInspection(
                location: .init(descriptor: descriptor, source: source, kind: .keychain(service: service)),
                state: buildState(descriptor: descriptor, source: source, normalized: normalized),
                normalized: normalized,
                parsedFile: nil
            )
        } catch let error as SoaError {
            return AuthInspection(
                location: .init(descriptor: descriptor, source: source, kind: .keychain(service: service)),
                state: buildInvalidState(descriptor: descriptor, source: source, category: error.category),
                normalized: nil,
                parsedFile: nil
            )
        }
    }

    func resolveResponsesAuth() throws -> ResolvedResponsesAuth {
        if let runtimeOverride {
            let preferredMatchesRuntime: Bool
            switch configuration.preferredTransportKind {
            case nil:
                preferredMatchesRuntime = true
            case .some(let preferred):
                preferredMatchesRuntime = preferred == runtimeOverride.transport
            }
            if preferredMatchesRuntime {
                return ResolvedResponsesAuth(
                    token: runtimeOverride.token,
                    accountID: runtimeOverride.authState.accountID,
                    transport: runtimeOverride.transport,
                    refreshToken: runtimeOverride.refreshToken
                )
            }
        }

        let inspection = try inspectAuth()
        switch inspection.state.readiness {
        case .readyOpenAI, .readyChatGPT:
            guard let normalized = inspection.normalized else {
                throw SoaError.credentialInsufficient()
            }
            switch configuration.preferredTransportKind {
            case .some(.openAIAPI):
                guard let key = normalized.openAIAPIKey else { throw SoaError.credentialInsufficient() }
                return ResolvedResponsesAuth(token: key, accountID: nil, transport: .openAIAPI, refreshToken: nil)
            case .some(.chatGPTBackend):
                guard let accessToken = normalized.chatGPTAccessToken,
                      let accountID = normalized.accountID else {
                    throw SoaError.credentialInsufficient()
                }
                return ResolvedResponsesAuth(token: accessToken, accountID: accountID, transport: .chatGPTBackend, refreshToken: normalized.chatGPTRefreshToken)
            case nil:
                if let accessToken = normalized.chatGPTAccessToken,
                   let accountID = normalized.accountID {
                    return ResolvedResponsesAuth(token: accessToken, accountID: accountID, transport: .chatGPTBackend, refreshToken: normalized.chatGPTRefreshToken)
                }
                if let key = normalized.openAIAPIKey {
                    return ResolvedResponsesAuth(token: key, accountID: nil, transport: .openAIAPI, refreshToken: nil)
                }
                throw SoaError.credentialInsufficient()
            }
        case .missing, .invalid:
            throw mapStateIssueToError(inspection.state)
        }
    }

    func defaultResponsesBaseURL(for transport: ResponsesTransportKind) -> String {
        switch transport {
        case .openAIAPI:
            return configuration.responsesBaseURL ?? Self.defaultResponsesBaseURL
        case .chatGPTBackend:
            return configuration.responsesBaseURL ?? Self.defaultChatGPTResponsesBaseURL
        }
    }

    func runtimeStateForRefreshedCredential(from currentState: AuthState, accountID: String?) -> AuthState {
        AuthState(
            authPath: currentState.authPath,
            pathSource: currentState.pathSource,
            credentialShape: currentState.credentialShape,
            readiness: .readyChatGPT,
            issueCategory: nil,
            remediationHint: "Ready for Codex ChatGPT backend requests.",
            hasOpenAIAPIKey: currentState.hasOpenAIAPIKey,
            hasRefreshToken: true,
            lastRefresh: Date(),
            accountID: accountID ?? currentState.accountID
        )
    }

    func runtimeStateForBrowserRelogin(path: String, source: ResolvedAuthPathSource, accountID: String?) -> AuthState {
        AuthState(
            authPath: path,
            pathSource: source,
            credentialShape: .chatgptManaged,
            readiness: .readyOpenAI,
            issueCategory: nil,
            remediationHint: "Ready for OpenAI Responses API requests.",
            hasOpenAIAPIKey: true,
            hasRefreshToken: true,
            lastRefresh: Date(),
            accountID: accountID
        )
    }
}

private func buildState(
    descriptor: String,
    source: ResolvedAuthPathSource,
    normalized: NormalizedCredential
) -> AuthState {
    let readiness = normalized.readiness
    let remediationHint: String
    switch readiness {
    case .readyOpenAI:
        remediationHint = "Ready for OpenAI Responses API requests."
    case .readyChatGPT:
        remediationHint = normalized.chatGPTRefreshToken != nil && desktopRefreshSupported
            ? "Ready for Codex ChatGPT backend requests. macOS file-backed refresh is available if the access token expires."
            : "Ready for Codex ChatGPT backend requests."
    case .missing:
        remediationHint = "Inject a credential or provide auth.json."
    case .invalid:
        remediationHint = normalized.chatGPTRefreshToken != nil && desktopRefreshSupported
            ? "The credential is not currently usable, but the file includes refresh_token and may be recoverable with refreshAuth()."
            : "Repair the stored credential or re-import a valid auth payload."
    }
    return AuthState(
        authPath: descriptor,
        pathSource: source,
        credentialShape: normalized.shape,
        readiness: readiness,
        issueCategory: readiness.isReady ? nil : .credentialInsufficient,
        remediationHint: remediationHint,
        hasOpenAIAPIKey: normalized.openAIAPIKey != nil,
        hasRefreshToken: normalized.chatGPTRefreshToken != nil,
        lastRefresh: normalized.lastRefresh,
        accountID: normalized.accountID
    )
}

private func buildInvalidState(
    descriptor: String,
    source: ResolvedAuthPathSource,
    category: ErrorCategory
) -> AuthState {
    AuthState(
        authPath: descriptor,
        pathSource: source,
        credentialShape: .unknown,
        readiness: .invalid,
        issueCategory: category,
        remediationHint: "Repair the stored credential or re-import a valid auth payload.",
        hasOpenAIAPIKey: false,
        hasRefreshToken: false,
        lastRefresh: nil,
        accountID: nil
    )
}

private func mapStateIssueToError(_ state: AuthState) -> SoaError {
    switch state.issueCategory {
    case .some(.authMissing):
        return .authMissing(path: state.authPath)
    case .some(.authMalformed):
        return .authMalformed("the current credential source is malformed")
    case .some(.authUnsupported):
        return .authUnsupported("the current credential source shape is unsupported")
    case .some(.keychainUnavailable):
        return .keychainUnavailable()
    case .some(.keychainFailure):
        return .keychainFailure("the keychain item could not be loaded")
    case .some(.authReadFailed):
        return .authReadFailed(path: state.authPath, "the credential source could not be read")
    default:
        return .credentialInsufficient()
    }
}
