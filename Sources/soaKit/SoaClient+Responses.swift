import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct PreparedResponseSend {
    let auth: ResolvedResponsesAuth
    let defaultModel: String?
}

private struct RefreshableFileCredential {
    let path: String
    let parsed: ParsedAuthFile
    let readyAuth: ResolvedResponsesAuth?
    let refreshToken: String?
}

extension SoaClient {
    public func createResponse(_ request: ResponsesRequest) async throws -> ResponsesResponse {
        try beginExclusiveResponseSend()
        defer { endExclusiveResponseSend() }

        let prepared = try await prepareResponseSend(for: request)

        let payload: JSONValue
        switch prepared.auth.transport {
        case .openAIAPI:
            payload = try request.intoJSONWithDefaults(
                defaultModel: prepared.defaultModel,
                defaultReasoning: configuration.defaultReasoningEffort
            )
        case .chatGPTBackend:
            payload = try request.intoChatGPTJSONWithDefaults(
                defaultModel: prepared.defaultModel,
                defaultReasoning: configuration.defaultReasoningEffort
            )
        }

        let url = responsesURL(
            baseURL: defaultResponsesBaseURL(for: prepared.auth.transport),
            transport: prepared.auth.transport
        )

        if let key = try sharedCredentialCoordinationKey(for: prepared.auth) {
            await SharedCredentialCoordinator.shared.beginSend(for: key)
            do {
                let sendAuth = try resolveSendAuth(afterPreflight: prepared.auth)
                let response = try await executeResponseSend(auth: sendAuth, url: url, payload: payload)
                await SharedCredentialCoordinator.shared.endSend(for: key)
                return response
            } catch {
                await SharedCredentialCoordinator.shared.endSend(for: key)
                throw error
            }
        }

        return try await executeResponseSend(auth: prepared.auth, url: url, payload: payload)
    }

    public func streamResponse(_ request: ResponsesRequest) async throws -> ResponsesStream {
        try beginExclusiveResponseSend()
        do {
            let prepared = try await prepareResponseSend(for: request)

            var payload: JSONValue
            switch prepared.auth.transport {
            case .openAIAPI:
                payload = try request.intoJSONWithDefaults(
                    defaultModel: prepared.defaultModel,
                    defaultReasoning: configuration.defaultReasoningEffort
                )
                if case .object(var root) = payload {
                    root["stream"] = .bool(true)
                    payload = .object(root)
                }
            case .chatGPTBackend:
                payload = try request.intoChatGPTJSONWithDefaults(
                    defaultModel: prepared.defaultModel,
                    defaultReasoning: configuration.defaultReasoningEffort
                )
            }

            let url = responsesURL(
                baseURL: defaultResponsesBaseURL(for: prepared.auth.transport),
                transport: prepared.auth.transport
            )
            let stream = try await openResponsesStream(auth: prepared.auth, url: url, payload: payload)
            return stream
        } catch {
            endExclusiveResponseSend()
            throw error
        }
    }

    public func listModels() async throws -> [ResponsesModelInfo] {
        try assertNoActiveResponseSend(operation: "models list")

        let auth = try resolveResponsesAuth()
        switch auth.transport {
        case .openAIAPI:
            let url = modelsURL(
                baseURL: defaultResponsesBaseURL(for: .openAIAPI),
                transport: .openAIAPI,
                clientVersion: configuration.clientVersion
            )
            var request = URLRequest(url: try makeURL(url))
            request.httpMethod = "GET"
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            applyConfiguredHeaders(to: &request)
            let (data, http) = try await performData(request)
            guard (200..<300).contains(http.statusCode) else {
                throw SoaError.responsesRequestFailed(status: http.statusCode, safeJSONErrorMessage(String(decoding: data, as: UTF8.self)))
            }
            let value = try parseJSONBody(data, status: http.statusCode)
            return (value["data"]?.arrayValue ?? []).compactMap { item in
                guard let slug = item["id"]?.stringValue else { return nil }
                return ResponsesModelInfo(
                    slug: slug,
                    transport: .openAIAPI,
                    priority: Int.max,
                    visibility: nil,
                    supportedInAPI: true,
                    defaultReasoningEffort: nil,
                    supportedReasoningEfforts: []
                )
            }
        case .chatGPTBackend:
            return try await fetchChatGPTModels(auth: auth)
        }
    }

    func performData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SoaError.transport("request did not return an HTTP response")
            }
            return (data, http)
        } catch let error as SoaError {
            throw error
        } catch {
            let safeURL = sanitizeURLForDisplay(request.url?.absoluteString ?? "")
            throw SoaError.transport("request to \(safeURL) failed: \(error.localizedDescription)")
        }
    }

    private func prepareResponseSend(for request: ResponsesRequest) async throws -> PreparedResponseSend {
        var auth = try resolveResponsesAuth()
        switch auth.transport {
        case .openAIAPI:
            return PreparedResponseSend(auth: auth, defaultModel: configuration.defaultModel)
        case .chatGPTBackend:
            let models = try await fetchChatGPTModels(auth: auth)
            auth = try resolveResponsesAuth()
            let defaultModel: String?
            if request.model != nil || configuration.defaultModel != nil {
                defaultModel = configuration.defaultModel
            } else {
                defaultModel = try selectDefaultChatGPTModel(from: models)
            }
            return PreparedResponseSend(auth: auth, defaultModel: defaultModel)
        }
    }

    private func resolveSendAuth(afterPreflight preparedAuth: ResolvedResponsesAuth) throws -> ResolvedResponsesAuth {
        let latest = try resolveResponsesAuth()
        guard latest.transport == preparedAuth.transport else {
            throw SoaError.credentialInsufficient()
        }
        return latest
    }

    private func executeResponseSend(
        auth: ResolvedResponsesAuth,
        url: String,
        payload: JSONValue
    ) async throws -> ResponsesResponse {
        let response = try await sendResponsesRequest(auth: auth, url: url, payload: payload)

        guard (200..<300).contains(response.status) else {
            let errorMessage = safeJSONErrorMessage(String(decoding: response.data, as: UTF8.self))
            if auth.transport == .chatGPTBackend, response.status == 401 {
                throw SoaError.responsesRequestFailed(
                    status: response.status,
                    "chatgpt backend rejected the response send and the request was not retried automatically to avoid duplicate sends: \(errorMessage)"
                )
            }
            throw SoaError.responsesRequestFailed(status: response.status, errorMessage)
        }

        let body: JSONValue
        switch auth.transport {
        case .openAIAPI:
            body = try parseJSONBody(response.data, status: response.status)
        case .chatGPTBackend:
            body = try parseChatGPTSSEBody(response.data, status: response.status)
        }
        return ResponsesResponse(status: response.status, body: body, meta: response.meta)
    }

    private func sendResponsesRequest(
        auth: ResolvedResponsesAuth,
        url: String,
        payload: JSONValue
    ) async throws -> (status: Int, data: Data, meta: ResponseMeta) {
        switch auth.transport {
        case .openAIAPI:
            var request = URLRequest(url: try makeURL(url))
            request.httpMethod = "POST"
            request.httpBody = try jsonData(from: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            applyConfiguredHeaders(to: &request)
            let (data, http) = try await performData(request)
            return (http.statusCode, data, responseMeta(from: http))
        case .chatGPTBackend:
            var request = URLRequest(url: try makeURL(url))
            request.httpMethod = "POST"
            request.httpBody = try jsonData(from: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(configuration.clientVersion, forHTTPHeaderField: "version")
            applyConfiguredHeaders(to: &request)
            if let accountID = auth.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
            let (data, http) = try await performData(request)
            return (http.statusCode, data, responseMeta(from: http))
        }
    }

    private func openResponsesStream(
        auth: ResolvedResponsesAuth,
        url: String,
        payload: JSONValue
    ) async throws -> ResponsesStream {
        var request = URLRequest(url: try makeURL(url))
        request.httpMethod = "POST"
        request.httpBody = try jsonData(from: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        applyConfiguredHeaders(to: &request)
        if auth.transport == .chatGPTBackend {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(configuration.clientVersion, forHTTPHeaderField: "version")
            if let accountID = auth.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
        } else {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoaError.transport("request did not return an HTTP response")
        }
        let meta = responseMeta(from: http)
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            throw SoaError.responsesRequestFailed(status: http.statusCode, safeJSONErrorMessage(String(decoding: body, as: UTF8.self)))
        }

        let events = AsyncThrowingStream<ResponsesStreamEvent, Error> { continuation in
            let task = Task {
                var eventName: String?
                var dataLines: [String] = []
                do {
                    func emitIfReady() throws {
                        guard !dataLines.isEmpty else {
                            eventName = nil
                            return
                        }
                        let name = eventName
                        let data = dataLines.joined(separator: "\n")
                        eventName = nil
                        dataLines.removeAll()
                        guard data.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]" else {
                            return
                        }
                        let event = try parseStreamEvent(name: name, data: data, status: http.statusCode, meta: meta)
                        continuation.yield(event)
                    }

                    func processLine(_ line: String) throws {
                        if line.isEmpty {
                            try emitIfReady()
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }

                    var lineBytes: [UInt8] = []
                    for try await byte in bytes {
                        if byte == 0x0a {
                            if lineBytes.last == 0x0d {
                                lineBytes.removeLast()
                            }
                            try processLine(String(decoding: lineBytes, as: UTF8.self))
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    if !lineBytes.isEmpty {
                        try processLine(String(decoding: lineBytes, as: UTF8.self))
                    }
                    try emitIfReady()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.endExclusiveResponseSend()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.endExclusiveResponseSend() }
            }
        }
        return ResponsesStream(meta: meta, events: events)
    }

    private func applyConfiguredHeaders(to request: inout URLRequest) {
        if let organization = configuration.organization {
            request.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
        }
        if let project = configuration.project {
            request.setValue(project, forHTTPHeaderField: "OpenAI-Project")
        }
        if let clientRequestID = configuration.clientRequestID {
            request.setValue(clientRequestID, forHTTPHeaderField: "X-Client-Request-Id")
        }
    }

    private func fetchChatGPTModels(auth: ResolvedResponsesAuth) async throws -> [ResponsesModelInfo] {
        let url = modelsURL(
            baseURL: defaultResponsesBaseURL(for: .chatGPTBackend),
            transport: .chatGPTBackend,
            clientVersion: configuration.clientVersion
        )
        let (data, http) = try await performChatGPTDataRequest(auth: auth, allowsRefreshRetry: true) { refreshedAuth in
            guard let accountID = refreshedAuth.accountID else {
                throw SoaError.credentialInsufficient()
            }
            var request = URLRequest(url: try makeURL(url))
            request.httpMethod = "GET"
            request.setValue("Bearer \(refreshedAuth.token)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.setValue(configuration.clientVersion, forHTTPHeaderField: "version")
            return request
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SoaError.responsesRequestFailed(status: http.statusCode, safeJSONErrorMessage(String(decoding: data, as: UTF8.self)))
        }
        let value = try parseJSONBody(data, status: http.statusCode)
        return (value["models"]?.arrayValue ?? []).compactMap(parseChatGPTModelInfo)
    }

    private func selectDefaultChatGPTModel(from models: [ResponsesModelInfo]) throws -> String {
        guard let best = models
            .filter({ $0.supportedInAPI })
            .filter({ $0.visibility != "hidden" })
            .min(by: { ($0.priority, $0.slug) < ($1.priority, $1.slug) })
        else {
            throw SoaError.responsesRequestFailed(
                "chatgpt backend did not return a usable model during safety preflight"
            )
        }
        return best.slug
    }

    func performChatGPTDataRequest(
        auth: ResolvedResponsesAuth,
        allowsRefreshRetry: Bool,
        makeRequest: (ResolvedResponsesAuth) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let first = try await performData(makeRequest(auth))
        guard allowsRefreshRetry,
              first.1.statusCode == 401,
              auth.refreshToken != nil,
              desktopRefreshSupported
        else {
            return first
        }

        let refreshedAuth = try await refreshChatGPTAuth(auth: auth)
        return try await performData(makeRequest(refreshedAuth))
    }

    func refreshChatGPTAuth(auth: ResolvedResponsesAuth) async throws -> ResolvedResponsesAuth {
        guard desktopRefreshSupported else {
            throw SoaError.authRefreshUnavailable()
        }
        guard let initialRefreshToken = auth.refreshToken?.nilIfEmpty else {
            throw SoaError.authRefreshUnavailable("refresh_token is missing")
        }

        let session = session
        let issuer = configuration.authIssuerURL ?? Self.defaultAuthIssuerURL
        let clientID = Self.defaultOAuthClientID

        let operation: @Sendable () async throws -> ResolvedResponsesAuth = {
            if let key = try await self.sharedCredentialCoordinationKey(for: auth) {
                let lock = try ExclusiveAuthFileLock.acquire(forAuthPath: key.descriptor)
                defer { lock.release() }
                let reloaded = try await self.loadRefreshableFileCredential(path: key.descriptor)
                if let readyAuth = reloaded.readyAuth,
                   readyAuth.token != auth.token {
                    await self.clearRuntimeOverrideState()
                    return readyAuth
                }
                let refreshToken = reloaded.refreshToken?.nilIfEmpty ?? initialRefreshToken
                let refreshed = try await refreshChatGPTTokens(
                    session: session,
                    issuer: issuer,
                    clientID: clientID,
                    refreshToken: refreshToken
                )
                return try await self.completeChatGPTAuthRefresh(refreshed: refreshed, persistedSource: reloaded)
            }

            let refreshed = try await refreshChatGPTTokens(
                session: session,
                issuer: issuer,
                clientID: clientID,
                refreshToken: initialRefreshToken
            )
            return try await self.completeChatGPTAuthRefresh(refreshed: refreshed, persistedSource: nil)
        }

        if let key = try sharedCredentialCoordinationKey(for: auth) {
            return try await SharedCredentialCoordinator.shared.refresh(for: key, operation: operation)
        }

        return try await operation()
    }

    private func completeChatGPTAuthRefresh(
        refreshed: RefreshedTokens,
        persistedSource: RefreshableFileCredential?
    ) async throws -> ResolvedResponsesAuth {
        let stateBeforeRefresh = try authState()
        let nextState = runtimeStateForRefreshedCredential(
            from: stateBeforeRefresh,
            accountID: refreshed.accountID
        )

        if let persistedSource {
            let payload = RefreshedAuthPayload(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                idToken: refreshed.idToken,
                accountID: refreshed.accountID ?? nextState.accountID,
                lastRefresh: nextState.lastRefresh ?? Date()
            )
            try persistRefreshedAuth(path: persistedSource.path, parsed: persistedSource.parsed, refreshed: payload)
            runtimeOverride = nil
        } else if let persisted = try persistRefreshedAuthIfPossible(refreshed: refreshed, state: nextState) {
            runtimeOverride = nil
            _ = persisted
        } else {
            runtimeOverride = RuntimeOverride(
                token: refreshed.accessToken,
                transport: .chatGPTBackend,
                refreshToken: refreshed.refreshToken,
                authState: nextState
            )
        }

        return ResolvedResponsesAuth(
            token: refreshed.accessToken,
            accountID: refreshed.accountID ?? stateBeforeRefresh.accountID,
            transport: .chatGPTBackend,
            refreshToken: refreshed.refreshToken
        )
    }

    private func loadRefreshableFileCredential(path: String) async throws -> RefreshableFileCredential {
        let raw = try readAuthJSON(path: path)
        let parsed = try parseAuthJSON(raw)
        let readyAuth: ResolvedResponsesAuth?
        if let accessToken = parsed.normalized.chatGPTAccessToken,
           let accountID = parsed.normalized.accountID {
            readyAuth = ResolvedResponsesAuth(
                token: accessToken,
                accountID: accountID,
                transport: .chatGPTBackend,
                refreshToken: parsed.normalized.chatGPTRefreshToken
            )
        } else {
            readyAuth = nil
        }
        return RefreshableFileCredential(
            path: path,
            parsed: parsed,
            readyAuth: readyAuth,
            refreshToken: parsed.normalized.chatGPTRefreshToken
        )
    }

    func persistRefreshedAuthIfPossible(
        refreshed: RefreshedTokens,
        state: AuthState
    ) throws -> String? {
        let location = try AuthPathResolver(authPath: configuration.authPath).resolve()
        guard case .file(let path) = location.kind else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let raw = try readAuthJSON(path: path)
        let parsed = try parseAuthJSON(raw)
        let payload = RefreshedAuthPayload(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            idToken: refreshed.idToken,
            accountID: refreshed.accountID ?? state.accountID,
            lastRefresh: state.lastRefresh ?? Date()
        )
        try persistRefreshedAuth(path: path, parsed: parsed, refreshed: payload)
        return path
    }
}

private func parseChatGPTModelInfo(_ value: JSONValue) -> ResponsesModelInfo? {
    guard let slug = value["slug"]?.stringValue else { return nil }
    let supportedInAPI = value["supported_in_api"]?.boolValue ?? true
    let visibility = value["visibility"]?.stringValue
    let priority = Int(value["priority"]?.doubleValue ?? Double(Int.max))
    let defaultReasoningEffort = value["default_reasoning_level"]?.stringValue.flatMap(ReasoningEffort.parseChoice) ?? value["default_reasoning_level"]?.stringValue.map(ReasoningEffort.raw)
    let supportedReasoningEfforts = (value["supported_reasoning_levels"]?.arrayValue ?? []).compactMap { item in
        item["effort"]?.stringValue.flatMap(ReasoningEffort.parseChoice) ?? item["effort"]?.stringValue.map(ReasoningEffort.raw)
    }
    return ResponsesModelInfo(
        slug: slug,
        transport: .chatGPTBackend,
        priority: priority,
        visibility: visibility,
        supportedInAPI: supportedInAPI,
        defaultReasoningEffort: defaultReasoningEffort,
        supportedReasoningEfforts: supportedReasoningEfforts
    )
}

func modelsURL(baseURL: String, transport: ResponsesTransportKind, clientVersion: String?) -> String {
    switch transport {
    case .openAIAPI:
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models"
    case .chatGPTBackend:
        let version = SoaClient.normalizeClientVersion(clientVersion)
        let encodedVersion = version.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? version
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models?client_version=\(encodedVersion)"
    }
}


func responsesURL(baseURL: String, transport: ResponsesTransportKind) -> String {
    switch transport {
    case .openAIAPI:
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/responses"
    case .chatGPTBackend:
        return baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/responses"
    }
}

private func responseMeta(from response: HTTPURLResponse) -> ResponseMeta {
    let requestID = response.value(forHTTPHeaderField: "x-request-id")
    return ResponseMeta(requestID: requestID)
}

private func parseStreamEvent(
    name: String?,
    data: String,
    status: Int,
    meta: ResponseMeta
) throws -> ResponsesStreamEvent {
    let body = try JSONValue.decode(from: Data(data.utf8))
    let type = body["type"]?.stringValue ?? name ?? "message"
    let response = body["response"].map {
        ResponsesResponse(status: status, body: $0, meta: meta)
    }
    return ResponsesStreamEvent(
        event: name ?? type,
        type: type,
        delta: body["delta"]?.stringValue,
        text: body["text"]?.stringValue,
        response: response,
        body: body
    )
}
