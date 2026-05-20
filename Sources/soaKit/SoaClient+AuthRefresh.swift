import Foundation

extension SoaClient {
    public func refreshAuth() async throws -> AuthRefreshOutcome {
        try assertNoActiveResponseSend(operation: "auth refresh")

        let auth = try resolveResponsesAuth()
        guard auth.transport == .chatGPTBackend else {
            throw SoaError.authRefreshUnavailable("refresh is only defined for ChatGPT-backed auth")
        }

        let refreshed = try await refreshChatGPTAuth(auth: auth)
        let state = try authState()
        let persistedTo: String?
        if let runtimeOverride,
           runtimeOverride.token == refreshed.token {
            persistedTo = nil
        } else {
            persistedTo = state.pathSource == .explicitAuthPath
                || state.pathSource == .explicitAuthHome
                || state.pathSource == .codexHomeEnv
                || state.pathSource == .defaultHome
                ? state.authPath
                : nil
        }
        return AuthRefreshOutcome(persistedTo: persistedTo, authState: state)
    }
}
