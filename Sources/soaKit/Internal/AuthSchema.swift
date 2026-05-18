import Foundation

struct NormalizedCredential: Sendable, Equatable {
    let authMode: String?
    let shape: CredentialShape
    let openAIAPIKey: String?
    let chatGPTAccessToken: String?
    let chatGPTRefreshToken: String?
    let chatGPTIDToken: String?
    let accountID: String?
    let lastRefresh: Date?

    var readiness: AuthReadiness {
        if chatGPTAccessToken != nil, accountID != nil { return .readyChatGPT }
        if openAIAPIKey != nil { return .readyOpenAI }
        return .invalid
    }

    func preferredCredential(for preferredTransport: ResponsesTransportKind?) -> SoaCredential? {
        switch preferredTransport {
        case .some(.openAIAPI):
            guard let openAIAPIKey else { return nil }
            return .openAIAPIKey(openAIAPIKey)
        case .some(.chatGPTBackend):
            guard let chatGPTAccessToken, let accountID else { return nil }
            return .chatGPT(accessToken: chatGPTAccessToken, accountID: accountID)
        case nil:
            if let chatGPTAccessToken, let accountID {
                return .chatGPT(accessToken: chatGPTAccessToken, accountID: accountID)
            }
            if let openAIAPIKey {
                return .openAIAPIKey(openAIAPIKey)
            }
            return nil
        }
    }
}

struct ParsedAuthFile: Sendable, Equatable {
    let raw: JSONValue
    let normalized: NormalizedCredential
}

struct RefreshedAuthPayload: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date
}

func parseAuthJSON(_ raw: JSONValue) throws -> ParsedAuthFile {
    guard let root = raw.objectValue else {
        throw SoaError.authMalformed("auth.json root must be a JSON object")
    }

    let authMode = root["auth_mode"]?.stringValue?.lowercased()
    let openAIAPIKey = firstNonEmptyString(in: root, keys: ["OPENAI_API_KEY", "openai_api_key", "api_key"])

    let rootAccessToken = firstNonEmptyString(in: root, keys: ["access_token", "accessToken"])
    let rootRefreshToken = firstNonEmptyString(in: root, keys: ["refresh_token", "refreshToken"])
    let rootAccountID = firstNonEmptyString(in: root, keys: ["account_id", "chatgpt_account_id", "chatgptAccountId"])
    let rootIDToken = firstNonEmptyString(in: root, keys: ["id_token", "idToken"])

    let tokenMap = root["tokens"]?.objectValue
    let tokenAccessToken = tokenMap.flatMap { firstNonEmptyString(in: $0, keys: ["access_token", "accessToken"]) }
    let tokenRefreshToken = tokenMap.flatMap { firstNonEmptyString(in: $0, keys: ["refresh_token", "refreshToken"]) }
    let tokenAccountID = tokenMap.flatMap { firstNonEmptyString(in: $0, keys: ["account_id", "chatgpt_account_id", "chatgptAccountId"]) }
    let tokenIDToken = tokenMap.flatMap { firstNonEmptyString(in: $0, keys: ["id_token", "idToken"]) }

    let accessToken = rootAccessToken ?? tokenAccessToken
    let refreshToken = rootRefreshToken ?? tokenRefreshToken
    let idToken = rootIDToken ?? tokenIDToken
    let accountID = rootAccountID ?? tokenAccountID ?? rootIDToken.flatMap(chatGPTAccountIDFromJWT) ?? tokenIDToken.flatMap(chatGPTAccountIDFromJWT)
    let lastRefresh = try optionalDate(root, field: "last_refresh")

    if authMode == "apikey" || authMode == "api_key" {
        guard openAIAPIKey != nil else {
            throw SoaError.authMalformed("api key auth is missing OPENAI_API_KEY or api_key")
        }
    }

    if let authMode, authMode.contains("chatgpt") {
        guard accessToken != nil || refreshToken != nil else {
            throw SoaError.authMalformed("chatgpt auth is missing both access_token and refresh_token")
        }
        if accessToken != nil {
            guard accountID != nil else {
                throw SoaError.authMalformed("chatgpt auth is missing account_id and could not derive it from id_token")
            }
        }
    }

    let shape: CredentialShape
    if accessToken != nil || refreshToken != nil || idToken != nil || tokenMap != nil || (authMode?.contains("chatgpt") == true) {
        if authMode == "chatgptauthtokens" || (tokenMap == nil && authMode != "chatgpt") {
            shape = .chatgptExternalTokens
        } else {
            shape = .chatgptManaged
        }
    } else if openAIAPIKey != nil {
        shape = .apiKey
    } else {
        shape = .unknown
    }

    let normalized = NormalizedCredential(
        authMode: authMode,
        shape: shape,
        openAIAPIKey: openAIAPIKey,
        chatGPTAccessToken: accessToken,
        chatGPTRefreshToken: refreshToken,
        chatGPTIDToken: idToken,
        accountID: accountID,
        lastRefresh: lastRefresh
    )

    if normalized.readiness == .invalid,
       normalized.chatGPTRefreshToken == nil {
        throw SoaError.authUnsupported("no usable OPENAI_API_KEY or ChatGPT access_token/account_id pair was found")
    }

    return ParsedAuthFile(raw: raw, normalized: normalized)
}

func normalizedCredential(from credential: SoaCredential) -> NormalizedCredential {
    switch credential {
    case .openAIAPIKey(let key):
        return .init(
            authMode: "apikey",
            shape: .apiKey,
            openAIAPIKey: key.nilIfEmpty,
            chatGPTAccessToken: nil,
            chatGPTRefreshToken: nil,
            chatGPTIDToken: nil,
            accountID: nil,
            lastRefresh: nil
        )
    case let .chatGPT(accessToken, accountID):
        return .init(
            authMode: "chatgptauthtokens",
            shape: .chatgptExternalTokens,
            openAIAPIKey: nil,
            chatGPTAccessToken: accessToken.nilIfEmpty,
            chatGPTRefreshToken: nil,
            chatGPTIDToken: nil,
            accountID: accountID.nilIfEmpty,
            lastRefresh: Date()
        )
    }
}

func rewriteRefreshedAuthJSON(parsed: ParsedAuthFile, refreshed: RefreshedAuthPayload) throws -> JSONValue {
    guard var root = parsed.raw.objectValue else {
        throw SoaError.authMalformed("auth.json root must be an object")
    }

    let existingMode = root["auth_mode"]?.stringValue?.nilIfEmpty?.lowercased()
    if existingMode == nil || existingMode == "apikey" || existingMode == "api_key" {
        root["auth_mode"] = .string("chatgpt")
    }

    if case .object(var tokens)? = root["tokens"] {
        tokens["access_token"] = .string(refreshed.accessToken)
        tokens["refresh_token"] = .string(refreshed.refreshToken)
        if let idToken = refreshed.idToken {
            tokens["id_token"] = .string(idToken)
        }
        if let accountID = refreshed.accountID {
            tokens["account_id"] = .string(accountID)
        }
        root["tokens"] = .object(tokens)
    } else {
        root["access_token"] = .string(refreshed.accessToken)
        root["refresh_token"] = .string(refreshed.refreshToken)
        if let idToken = refreshed.idToken {
            root["id_token"] = .string(idToken)
        }
        if let accountID = refreshed.accountID {
            root["account_id"] = .string(accountID)
        }
    }

    root["last_refresh"] = .string(formatRFC3339(refreshed.lastRefresh))
    return .object(root)
}

private func firstNonEmptyString(in root: [String: JSONValue], keys: [String]) -> String? {
    for key in keys {
        if let value = root[key]?.stringValue?.nilIfEmpty {
            return value
        }
    }
    return nil
}

private func optionalDate(_ root: [String: JSONValue], field: String) throws -> Date? {
    switch root[field] {
    case .string(let value):
        if let date = parseRFC3339(value) {
            return date
        }
        throw SoaError.authMalformed("\(field) must be RFC3339")
    case .null, nil:
        return nil
    default:
        throw SoaError.authMalformed("\(field) must be a string or null")
    }
}

func chatGPTAccountIDFromJWT(_ jwt: String) -> String? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    guard let decoded = decodeBase64URL(String(parts[1])),
          let value = try? JSONValue.decode(from: decoded)
    else {
        return nil
    }
    return value["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue?.nilIfEmpty
}

func decodeBase64URL(_ value: String) -> Data? {
    var value = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    switch value.count % 4 {
    case 0: break
    case 2: value += "=="
    case 3: value += "="
    default: return nil
    }
    return Data(base64Encoded: value)
}

func parseRFC3339(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    let fallback = ISO8601DateFormatter()
    fallback.formatOptions = [.withInternetDateTime]
    return fallback.date(from: string)
}

func formatRFC3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let desktopRefreshSupported = false
#else
let desktopRefreshSupported = true
#endif

struct BrowserReloginAuthPayload: Sendable, Equatable {
    let openAIAPIKey: String
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let accountID: String?
    let lastRefresh: Date
}

func buildBrowserReloginAuthJSON(payload: BrowserReloginAuthPayload) -> JSONValue {
    var tokens: [String: JSONValue] = [
        "id_token": .string(payload.idToken),
        "access_token": .string(payload.accessToken),
        "refresh_token": .string(payload.refreshToken),
    ]
    if let accountID = payload.accountID?.nilIfEmpty {
        tokens["account_id"] = .string(accountID)
    }

    return .object([
        "auth_mode": .string("chatgpt"),
        "OPENAI_API_KEY": .string(payload.openAIAPIKey),
        "tokens": .object(tokens),
        "last_refresh": .string(formatRFC3339(payload.lastRefresh)),
    ])
}

func rewriteBrowserReloginAuthJSON(parsed: ParsedAuthFile, payload: BrowserReloginAuthPayload) throws -> JSONValue {
    guard var root = parsed.raw.objectValue else {
        throw SoaError.authMalformed("auth.json root must be an object")
    }

    root["auth_mode"] = .string("chatgpt")
    root["OPENAI_API_KEY"] = .string(payload.openAIAPIKey)

    var tokens: [String: JSONValue] = [
        "id_token": .string(payload.idToken),
        "access_token": .string(payload.accessToken),
        "refresh_token": .string(payload.refreshToken),
    ]
    if let accountID = payload.accountID?.nilIfEmpty {
        tokens["account_id"] = .string(accountID)
    }
    root["tokens"] = .object(tokens)
    root["last_refresh"] = .string(formatRFC3339(payload.lastRefresh))

    return .object(root)
}
