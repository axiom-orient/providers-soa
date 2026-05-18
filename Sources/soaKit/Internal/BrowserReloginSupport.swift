import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct BrowserLoginConfig: Sendable, Equatable {
    let issuer: String
    let clientID: String
    let callbackPort: UInt16
    let openBrowser: Bool
    let timeoutSeconds: TimeInterval
    let allowedWorkspaceID: String?
}

struct PKCECodes: Sendable, Equatable {
    let codeVerifier: String
    let codeChallenge: String
}

struct ExchangedOAuthTokens: Sendable, Equatable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String?
}

struct CompletedBrowserLogin: Sendable, Equatable {
    let authURL: String
    let callbackPort: UInt16
    let apiKey: String
    let tokens: ExchangedOAuthTokens
}

struct BrowserLoginSession: Sendable {
    let authURL: String
    let callbackPort: UInt16
    private let task: Task<CompletedBrowserLogin, Error>

    init(authURL: String, callbackPort: UInt16, task: Task<CompletedBrowserLogin, Error>) {
        self.authURL = authURL
        self.callbackPort = callbackPort
        self.task = task
    }

    func wait() async throws -> CompletedBrowserLogin {
        try await task.value
    }
}

func startBrowserLoginSession(
    session: URLSession,
    config: BrowserLoginConfig
) async throws -> BrowserLoginSession {
    let server = try LocalHTTPCallbackServer(port: config.callbackPort)
    let actualPort = server.port
    let pkce = generatePKCE()
    let state = generateRandomBase64URL(byteCount: 32)
    let redirectURI = "http://localhost:\(actualPort)/auth/callback"
    let authURL = try buildAuthorizeURL(
        issuer: config.issuer,
        clientID: config.clientID,
        redirectURI: redirectURI,
        pkce: pkce,
        state: state,
        allowedWorkspaceID: config.allowedWorkspaceID
    )

    if config.openBrowser {
        try openSystemBrowser(authURL)
    }

    let task = Task(priority: .userInitiated) {
        try await awaitCallbackAndExchange(
            server: server,
            session: session,
            config: config,
            pkce: pkce,
            state: state,
            redirectURI: redirectURI,
            authURL: authURL
        )
    }

    return BrowserLoginSession(authURL: authURL, callbackPort: actualPort, task: task)
}

private func awaitCallbackAndExchange(
    server: LocalHTTPCallbackServer,
    session: URLSession,
    config: BrowserLoginConfig,
    pkce: PKCECodes,
    state: String,
    redirectURI: String,
    authURL: String
) async throws -> CompletedBrowserLogin {
    let deadline = Date().addingTimeInterval(config.timeoutSeconds)

    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw SoaError.reloginTimeout() }

        guard let connection = try server.accept(timeoutSeconds: remaining) else {
            throw SoaError.reloginTimeout()
        }
        defer { connection.close() }

        let request = try connection.readRequest(maxBytes: 16 * 1024)
        guard let path = requestLinePath(request) else {
            try connection.writeHTML(status: 400, reason: "Bad Request", body: "Malformed HTTP request")
            continue
        }
        guard let components = URLComponents(string: "http://localhost\(path)") else {
            try connection.writeHTML(status: 400, reason: "Bad Request", body: "Malformed callback URL")
            continue
        }

        switch components.path {
        case "/auth/callback":
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] {
                if params[item.name] == nil {
                    params[item.name] = item.value ?? ""
                }
            }
            guard params["state"] == state else {
                try connection.writeHTML(status: 400, reason: "State mismatch", body: "State mismatch")
                throw SoaError.reloginDenied("state mismatch")
            }

            if let errorCode = params["error"] {
                let message = oauthCallbackErrorMessage(errorCode: errorCode, description: params["error_description"])
                try connection.writeHTML(status: 403, reason: "Login denied", body: message)
                throw SoaError.reloginDenied(message)
            }

            guard let code = params["code"]?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                try connection.writeHTML(status: 400, reason: "Missing code", body: "Missing authorization code in callback.")
                throw SoaError.tokenExchangeFailed("missing authorization code in callback")
            }

            let tokens: ExchangedOAuthTokens
            do {
                tokens = try await exchangeCodeForTokens(
                    session: session,
                    issuer: config.issuer,
                    clientID: config.clientID,
                    redirectURI: redirectURI,
                    pkce: pkce,
                    code: code
                )
            } catch {
                try connection.writeHTML(status: 502, reason: "Token exchange failed", body: "Sign-in failed while exchanging OAuth tokens. Return to the application for details.")
                throw error
            }

            do {
                try ensureWorkspaceAllowed(expectedWorkspaceID: config.allowedWorkspaceID, idToken: tokens.idToken)
            } catch {
                try connection.writeHTML(status: 403, reason: "Workspace mismatch", body: "The selected account is not allowed for this workspace restriction.")
                throw error
            }

            let apiKey: String
            do {
                apiKey = try await obtainAPIKey(
                    session: session,
                    issuer: config.issuer,
                    clientID: config.clientID,
                    idToken: tokens.idToken
                )
            } catch {
                try connection.writeHTML(status: 502, reason: "API key exchange failed", body: apiKeyExchangeFailurePageMessage(error))
                throw error
            }

            try connection.writeHTML(status: 200, reason: "OK", body: "Sign-in completed. You can return to the application.")
            return CompletedBrowserLogin(
                authURL: authURL,
                callbackPort: server.port,
                apiKey: apiKey,
                tokens: tokens
            )

        case "/cancel":
            try connection.writeHTML(status: 200, reason: "OK", body: "Login cancelled")
            throw SoaError.reloginDenied("login cancelled")

        default:
            try connection.writeHTML(status: 404, reason: "Not Found", body: "Not Found")
        }
    }
}

private func exchangeCodeForTokens(
    session: URLSession,
    issuer: String,
    clientID: String,
    redirectURI: String,
    pkce: PKCECodes,
    code: String
) async throws -> ExchangedOAuthTokens {
    let body = formURLEncoded([
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", redirectURI),
        ("client_id", clientID),
        ("code_verifier", pkce.codeVerifier),
    ])
    let json = try await postTokenForm(session: session, issuer: issuer, body: body, operation: "authorization-code exchange")
    guard let object = json.objectValue,
          let idToken = object["id_token"]?.stringValue?.nilIfEmpty,
          let accessToken = object["access_token"]?.stringValue?.nilIfEmpty,
          let refreshToken = object["refresh_token"]?.stringValue?.nilIfEmpty
    else {
        throw SoaError.tokenExchangeFailed("token endpoint returned invalid JSON")
    }
    return ExchangedOAuthTokens(
        idToken: idToken,
        accessToken: accessToken,
        refreshToken: refreshToken,
        accountID: chatGPTAccountIDFromJWT(idToken)
    )
}

private func obtainAPIKey(
    session: URLSession,
    issuer: String,
    clientID: String,
    idToken: String
) async throws -> String {
    let body = formURLEncoded([
        ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
        ("client_id", clientID),
        ("requested_token", "openai-api-key"),
        ("subject_token", idToken),
        ("subject_token_type", "urn:ietf:params:oauth:token-type:id_token"),
    ])
    let json = try await postTokenForm(session: session, issuer: issuer, body: body, operation: "API-key exchange")
    guard let key = json.objectValue?["access_token"]?.stringValue?.nilIfEmpty else {
        throw SoaError.tokenExchangeFailed("API-key exchange returned invalid JSON")
    }
    return key
}

private func postTokenForm(
    session: URLSession,
    issuer: String,
    body: Data,
    operation: String
) async throws -> JSONValue {
    let endpoint = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth/token"
    guard let url = URL(string: endpoint) else {
        throw SoaError.invalidConfiguration("invalid token endpoint \(String(reflecting: endpoint))")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoaError.tokenExchangeFailed("\(operation) returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw SoaError.tokenExchangeFailed("\(operation) returned status \(http.statusCode): \(bodyText)", status: http.statusCode)
        }
        do {
            return try JSONValue.decode(from: data)
        } catch {
            throw SoaError.tokenExchangeFailed("\(operation) returned invalid JSON: \(error)")
        }
    } catch let error as SoaError {
        throw error
    } catch {
        throw SoaError.tokenExchangeFailed("\(operation) transport failure: \(error.localizedDescription)")
    }
}

func buildAuthorizeURL(
    issuer: String,
    clientID: String,
    redirectURI: String,
    pkce: PKCECodes,
    state: String,
    allowedWorkspaceID: String?
) throws -> String {
    var components = URLComponents(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth/authorize")
    guard components != nil else {
        throw SoaError.invalidConfiguration("invalid issuer URL \(String(reflecting: issuer))")
    }
    var queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
        URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "id_token_add_organizations", value: "true"),
        URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "originator", value: "soa"),
    ]
    if let allowedWorkspaceID = allowedWorkspaceID?.nilIfEmpty {
        queryItems.append(URLQueryItem(name: "allowed_workspace_id", value: allowedWorkspaceID))
    }
    components?.queryItems = queryItems
    guard let url = components?.url else {
        throw SoaError.invalidConfiguration("could not build authorize URL")
    }
    return url.absoluteString
}

private func generatePKCE() -> PKCECodes {
    let verifier = generateRandomBase64URL(byteCount: 32)
    let challenge = base64URLEncode(Data(sha256(Array(verifier.utf8))))
    return PKCECodes(codeVerifier: verifier, codeChallenge: challenge)
}

private func generateRandomBase64URL(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    return base64URLEncode(Data(bytes))
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func ensureWorkspaceAllowed(expectedWorkspaceID: String?, idToken: String) throws {
    guard let expected = expectedWorkspaceID?.nilIfEmpty else { return }
    guard let actual = chatGPTAccountIDFromJWT(idToken) else {
        throw SoaError.reloginDenied("workspace restriction is active but the ID token did not include chatgpt_account_id")
    }
    guard actual == expected else {
        throw SoaError.reloginDenied("login is restricted to workspace id \(expected)")
    }
}

private func oauthCallbackErrorMessage(errorCode: String, description: String?) -> String {
    if errorCode == "access_denied",
       description?.lowercased().contains("missing_codex_entitlement") == true {
        return "Codex is not enabled for this workspace. Contact your workspace administrator."
    }
    if let description = description?.nilIfEmpty {
        return "Sign-in failed: \(sanitizeMessage(description))"
    }
    return "Sign-in failed: \(sanitizeMessage(errorCode))"
}

private func apiKeyExchangeFailurePageMessage(_ error: Error) -> String {
    if String(describing: error).contains("organization_id") {
        return "Sign-in succeeded, but OpenAI Platform setup is incomplete for API-key issuance. Complete organization/project setup or use an explicit OPENAI_API_KEY, then retry."
    }
    return "Sign-in succeeded but the API-key exchange failed. Return to the application for details."
}

private func requestLinePath(_ request: String) -> String? {
    guard let firstLine = request.split(separator: "\n", maxSplits: 1).first else { return nil }
    let parts = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    return String(parts[1])
}

private func htmlEscape(_ input: String) -> String {
    input
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func openSystemBrowser(_ url: String) throws {
    #if os(macOS)
    let executable = "/usr/bin/open"
    #elseif os(Linux)
    let executable = "/usr/bin/xdg-open"
    #else
    throw SoaError.transport("automatic browser open is not supported on this platform; retry with openBrowser=false")
    #endif

    #if os(macOS) || os(Linux)
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw SoaError.transport("browser launcher not found at \(executable); retry with openBrowser=false")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = [url]
    do {
        try process.run()
    } catch {
        throw SoaError.transport("failed to open system browser: \(error.localizedDescription)")
    }
    #endif
}

#if os(Linux) || canImport(Darwin)
private final class LocalHTTPCallbackServer: @unchecked Sendable {
    let descriptor: Int32
    let port: UInt16

    init(port: UInt16) throws {
        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else { throw SoaError.transport(currentPOSIXErrorDescription()) }
        self.descriptor = fd

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = currentPOSIXErrorDescription()
            close(fd)
            throw SoaError.transport(message)
        }
        guard listen(fd, 16) == 0 else {
            let message = currentPOSIXErrorDescription()
            close(fd)
            throw SoaError.transport(message)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let portResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard portResult == 0 else {
            let message = currentPOSIXErrorDescription()
            close(fd)
            throw SoaError.transport(message)
        }
        self.port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit {
        close(descriptor)
    }

    func accept(timeoutSeconds: TimeInterval) throws -> LocalHTTPConnection? {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = max(0, min(Int(timeoutSeconds * 1000), Int(Int32.max)))
        let ready = poll(&pollDescriptor, 1, Int32(timeoutMilliseconds))
        if ready == 0 { return nil }
        guard ready > 0 else { throw SoaError.transport(currentPOSIXErrorDescription()) }
        #if os(Linux)
        let client = Glibc.accept(descriptor, nil, nil)
        #else
        let client = Darwin.accept(descriptor, nil, nil)
        #endif
        guard client >= 0 else { throw SoaError.transport(currentPOSIXErrorDescription()) }
        return LocalHTTPConnection(descriptor: client)
    }
}

private final class LocalHTTPConnection {
    let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        #if os(Linux)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
    }

    func readRequest(maxBytes: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            recv(descriptor, rawBuffer.baseAddress, maxBytes, 0)
        }
        guard count >= 0 else { throw SoaError.transport(currentPOSIXErrorDescription()) }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    func writeHTML(status: Int, reason: String, body: String) throws {
        let escaped = htmlEscape(body)
        let html = "<html><body><p>\(escaped)</p></body></html>"
        let response = "HTTP/1.1 \(status) \(reason)\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: \(html.utf8.count)\r\nconnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        let sent = bytes.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return send(descriptor, baseAddress, pointer.count, 0)
        }
        guard sent >= 0 else { throw SoaError.transport(currentPOSIXErrorDescription()) }
    }
}
#else
private final class LocalHTTPCallbackServer: @unchecked Sendable {
    let port: UInt16
    init(port: UInt16) throws {
        self.port = port
        throw SoaError.transport("browser relogin callback server is not supported on this platform")
    }
    func accept(timeoutSeconds: TimeInterval) throws -> LocalHTTPConnection? { nil }
}
private final class LocalHTTPConnection {
    func close() {}
    func readRequest(maxBytes: Int) throws -> String {
        throw SoaError.transport("browser relogin callback server is not supported on this platform")
    }
    func writeHTML(status: Int, reason: String, body: String) throws {
        throw SoaError.transport("browser relogin callback server is not supported on this platform")
    }
}
#endif

private func currentPOSIXErrorDescription() -> String {
    String(cString: strerror(errno))
}

private func sha256(_ bytes: [UInt8]) -> [UInt8] {
    var message = bytes
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 {
        message.append(0)
    }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var h0: UInt32 = 0x6a09e667
    var h1: UInt32 = 0xbb67ae85
    var h2: UInt32 = 0x3c6ef372
    var h3: UInt32 = 0xa54ff53a
    var h4: UInt32 = 0x510e527f
    var h5: UInt32 = 0x9b05688c
    var h6: UInt32 = 0x1f83d9ab
    var h7: UInt32 = 0x5be0cd19

    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        let chunk = Array(message[chunkStart..<chunkStart + 64])
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = (UInt32(chunk[j]) << 24) | (UInt32(chunk[j + 1]) << 16) | (UInt32(chunk[j + 2]) << 8) | UInt32(chunk[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7

        for i in 0..<64 {
            let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h0 = h0 &+ a
        h1 = h1 &+ b
        h2 = h2 &+ c
        h3 = h3 &+ d
        h4 = h4 &+ e
        h5 = h5 &+ f
        h6 = h6 &+ g
        h7 = h7 &+ h
    }

    var digest: [UInt8] = []
    for value in [h0, h1, h2, h3, h4, h5, h6, h7] {
        digest.append(UInt8((value >> 24) & 0xff))
        digest.append(UInt8((value >> 16) & 0xff))
        digest.append(UInt8((value >> 8) & 0xff))
        digest.append(UInt8(value & 0xff))
    }
    return digest
}

private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
}
