import Foundation

public enum AuthReadiness: String, Sendable, Equatable, Codable {
    case readyOpenAI = "ready_openai"
    case readyChatGPT = "ready_chatgpt"
    case authRefreshRequired = "auth_refresh_required"
    case invalid = "invalid"

    public var isReady: Bool {
        switch self {
        case .readyOpenAI, .readyChatGPT: true
        case .authRefreshRequired, .invalid: false
        }
    }

    public var transportKind: ResponsesTransportKind? {
        switch self {
        case .readyOpenAI: .openAIAPI
        case .readyChatGPT: .chatGPTBackend
        case .authRefreshRequired, .invalid: nil
        }
    }
}

public enum CredentialShape: String, Sendable, Equatable, Codable {
    case apiKey = "api_key"
    case chatgptManaged = "chatgpt_managed"
    case chatgptExternalTokens = "chatgpt_external_tokens"
    case unknown
}

public enum ResolvedAuthPathSource: String, Sendable, Equatable, Codable {
    case explicitAuthPath = "explicit_auth_path"
    case explicitAuthHome = "explicit_auth_home"
    case codexHomeEnv = "codex_home_env"
    case defaultHome = "default_home"
}

public struct AuthState: Sendable, Equatable {
    public let authPath: String
    public let pathSource: ResolvedAuthPathSource
    public let credentialShape: CredentialShape
    public let readiness: AuthReadiness
    public let issueCategory: ErrorCategory?
    public let remediationHint: String
    public let hasOpenAIAPIKey: Bool
    public let hasRefreshToken: Bool
    public let lastRefresh: Date?
    public let accountID: String?

    public init(
        authPath: String,
        pathSource: ResolvedAuthPathSource,
        credentialShape: CredentialShape,
        readiness: AuthReadiness,
        issueCategory: ErrorCategory?,
        remediationHint: String,
        hasOpenAIAPIKey: Bool,
        hasRefreshToken: Bool,
        lastRefresh: Date?,
        accountID: String?
    ) {
        self.authPath = authPath
        self.pathSource = pathSource
        self.credentialShape = credentialShape
        self.readiness = readiness
        self.issueCategory = issueCategory
        self.remediationHint = remediationHint
        self.hasOpenAIAPIKey = hasOpenAIAPIKey
        self.hasRefreshToken = hasRefreshToken
        self.lastRefresh = lastRefresh
        self.accountID = accountID
    }

    public var isReady: Bool { readiness.isReady }
    public var transportKind: ResponsesTransportKind? { readiness.transportKind }
}

public struct BrowserReloginOptions: Sendable, Equatable {
    public var openBrowser: Bool
    public var callbackPort: UInt16
    public var timeoutSeconds: TimeInterval
    public var persistPath: String?
    public var issuer: String?
    public var clientID: String?
    public var allowedWorkspaceID: String?

    public init(
        openBrowser: Bool = true,
        callbackPort: UInt16 = 1455,
        timeoutSeconds: TimeInterval = 180,
        persistPath: String? = nil,
        issuer: String? = nil,
        clientID: String? = nil,
        allowedWorkspaceID: String? = nil
    ) {
        self.openBrowser = openBrowser
        self.callbackPort = callbackPort
        self.timeoutSeconds = timeoutSeconds
        self.persistPath = persistPath
        self.issuer = issuer
        self.clientID = clientID
        self.allowedWorkspaceID = allowedWorkspaceID
    }

    public func withOpenBrowser(_ value: Bool) -> Self {
        var copy = self
        copy.openBrowser = value
        return copy
    }

    public func withCallbackPort(_ value: UInt16) -> Self {
        var copy = self
        copy.callbackPort = value
        return copy
    }

    public func withTimeoutSeconds(_ value: TimeInterval) -> Self {
        var copy = self
        copy.timeoutSeconds = value
        return copy
    }

    public func withPersistPath(_ value: String) -> Self {
        var copy = self
        copy.persistPath = value
        return copy
    }

    public func withIssuer(_ value: String) -> Self {
        var copy = self
        copy.issuer = value
        return copy
    }

    public func withClientID(_ value: String) -> Self {
        var copy = self
        copy.clientID = value
        return copy
    }

    public func withAllowedWorkspaceID(_ value: String) -> Self {
        var copy = self
        copy.allowedWorkspaceID = value
        return copy
    }
}

public struct BrowserReloginOutcome: Sendable, Equatable {
    public let authURL: String
    public let callbackPort: UInt16
    public let persistedTo: String?
    public let authState: AuthState

    public init(authURL: String, callbackPort: UInt16, persistedTo: String?, authState: AuthState) {
        self.authURL = authURL
        self.callbackPort = callbackPort
        self.persistedTo = persistedTo
        self.authState = authState
    }
}

public enum ResponsesTransportKind: String, Sendable, Equatable, Codable {
    case openAIAPI = "openai_api"
    case chatGPTBackend = "chatgpt_backend"
}

public struct ResponsesModelInfo: Sendable, Equatable, Codable {
    public let slug: String
    public let transport: ResponsesTransportKind
    public let priority: Int
    public let visibility: String?
    public let supportedInAPI: Bool
    public let defaultReasoningEffort: ReasoningEffort?
    public let supportedReasoningEfforts: [ReasoningEffort]

    public init(
        slug: String,
        transport: ResponsesTransportKind,
        priority: Int,
        visibility: String?,
        supportedInAPI: Bool,
        defaultReasoningEffort: ReasoningEffort?,
        supportedReasoningEfforts: [ReasoningEffort]
    ) {
        self.slug = slug
        self.transport = transport
        self.priority = priority
        self.visibility = visibility
        self.supportedInAPI = supportedInAPI
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

public struct ResponseMeta: Sendable, Equatable, Codable {
    public let requestID: String?

    public init(requestID: String? = nil) {
        self.requestID = requestID
    }
}

public enum ReasoningEffort: Sendable, Equatable, Codable {
    case none
    case minimal
    case low
    case medium
    case high
    case xHigh
    case raw(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.lowercased() {
        case "none": self = .none
        case "minimal": self = .minimal
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "xhigh": self = .xHigh
        default: self = .raw(rawValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apiString)
    }

    public static func parseChoice(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": ReasoningEffort.none
        case "minimal": ReasoningEffort.minimal
        case "low": ReasoningEffort.low
        case "medium", "middle", "mid", "liddle": ReasoningEffort.medium
        case "high": ReasoningEffort.high
        case "xhigh", "x-high", "extra-high", "extra_high": ReasoningEffort.xHigh
        default: nil
        }
    }

    public var apiString: String {
        switch self {
        case .none: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xHigh: "xhigh"
        case .raw(let value): value
        }
    }
}

public struct ReasoningConfig: Sendable, Equatable, Codable {
    public let effort: ReasoningEffort

    public init(_ effort: ReasoningEffort) {
        self.effort = effort
    }

    func toJSON() -> JSONValue {
        ["effort": .string(effort.apiString)]
    }
}

public struct ResponsesTextConfig: Sendable, Equatable, Codable {
    public var format: ResponsesTextFormat?
    public var verbosity: String?

    public init(format: ResponsesTextFormat? = nil, verbosity: String? = nil) {
        self.format = format
        self.verbosity = verbosity
    }

    public static func plainText() -> Self {
        .init(format: .text)
    }

    public static func jsonObject() -> Self {
        .init(format: .jsonObject)
    }

    public static func jsonSchema(
        name: String,
        schema: JSONValue,
        description: String? = nil,
        strict: Bool = true
    ) -> Self {
        .init(format: .jsonSchema(name: name, description: description, schema: schema, strict: strict))
    }

    func toJSON() -> JSONValue {
        var root: [String: JSONValue] = [:]
        if let format {
            root["format"] = format.toJSON()
        }
        if let verbosity = verbosity?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            root["verbosity"] = .string(verbosity)
        }
        return .object(root)
    }
}

public enum ResponsesTextFormat: Sendable, Equatable, Codable {
    case text
    case jsonObject
    case jsonSchema(name: String, description: String?, schema: JSONValue, strict: Bool)

    func toJSON() -> JSONValue {
        switch self {
        case .text:
            return ["type": "text"]
        case .jsonObject:
            return ["type": "json_object"]
        case let .jsonSchema(name, description, schema, strict):
            var root: [String: JSONValue] = [
                "type": "json_schema",
                "name": .string(name),
                "schema": schema,
                "strict": .bool(strict),
            ]
            if let description {
                root["description"] = .string(description)
            }
            return .object(root)
        }
    }
}

public enum ResponsesMessageRole: String, Sendable, Equatable, Codable {
    case system
    case developer
    case user
    case assistant
}

public struct ResponsesMessage: Sendable, Equatable, Codable {
    public let role: ResponsesMessageRole
    public let content: String

    public init(role: ResponsesMessageRole, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> Self { .init(role: .system, content: text) }
    public static func developer(_ text: String) -> Self { .init(role: .developer, content: text) }
    public static func user(_ text: String) -> Self { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> Self { .init(role: .assistant, content: text) }
}

public struct ResponsesFunctionTool: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let strict: Bool

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        strict: Bool = true
    ) throws {
        guard parameters.objectValue != nil else {
            throw SoaError.invalidConfiguration("tool parameters for \(String(reflecting: name)) must be a JSON object")
        }
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }

    public init(
        name: String,
        description: String,
        parametersJSON: String,
        strict: Bool = true
    ) throws {
        guard let data = parametersJSON.data(using: .utf8) else {
            throw SoaError.invalidConfiguration("tool parameters for \(String(reflecting: name)) are not valid UTF-8")
        }
        let value = try JSONValue.decode(from: data)
        try self.init(name: name, description: description, parameters: value, strict: strict)
    }
}

public struct ResponsesFunctionCall: Sendable, Equatable, Codable {
    public let id: String?
    public let callID: String
    public let name: String
    public let argumentsJSON: String

    public init(
        id: String? = nil,
        callID: String,
        name: String,
        argumentsJSON: String
    ) {
        self.id = id
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ResponsesFunctionCallOutput: Sendable, Equatable, Codable {
    public let callID: String
    public let output: String

    public init(callID: String, output: String) {
        self.callID = callID
        self.output = output
    }
}

public enum ResponsesToolChoice: Sendable, Equatable, Codable {
    case auto
    case none
    case required
    case named(String)
}

public enum ResponsesInputItem: Sendable, Equatable, Codable {
    case message(ResponsesMessage)
    case functionCall(ResponsesFunctionCall)
    case functionCallOutput(ResponsesFunctionCallOutput)
}

public struct ResponsesRequest: Sendable, Equatable {
    public var model: String?
    public var input: JSONValue
    public var typedInput: [ResponsesInputItem]?
    public var tools: [ResponsesFunctionTool]
    public var toolChoice: ResponsesToolChoice
    public var parallelToolCalls: Bool
    public var reasoning: ReasoningConfig?
    public var text: ResponsesTextConfig?
    public var metadata: [String: JSONValue]
    public var extraBody: [String: JSONValue]

    public init(_ input: String) {
        self.model = nil
        self.input = .string(input)
        self.typedInput = nil
        self.tools = []
        self.toolChoice = .auto
        self.parallelToolCalls = false
        self.reasoning = nil
        self.text = nil
        self.metadata = [:]
        self.extraBody = [:]
    }

    public init(input: JSONValue) {
        self.model = nil
        self.input = input
        self.typedInput = nil
        self.tools = []
        self.toolChoice = .auto
        self.parallelToolCalls = false
        self.reasoning = nil
        self.text = nil
        self.metadata = [:]
        self.extraBody = [:]
    }

    public init(
        model: String? = nil,
        items: [ResponsesInputItem],
        tools: [ResponsesFunctionTool] = [],
        toolChoice: ResponsesToolChoice = .auto,
        parallelToolCalls: Bool = false,
        reasoning: ReasoningConfig? = nil
    ) {
        self.model = model
        self.input = .array([])
        self.typedInput = items
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.reasoning = reasoning
        self.text = nil
        self.metadata = [:]
        self.extraBody = [:]
    }

    public init(
        model: String? = nil,
        messages: [ResponsesMessage],
        tools: [ResponsesFunctionTool] = [],
        toolChoice: ResponsesToolChoice = .auto,
        parallelToolCalls: Bool = false,
        reasoning: ReasoningConfig? = nil
    ) {
        self.init(
            model: model,
            items: messages.map(ResponsesInputItem.message),
            tools: tools,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            reasoning: reasoning
        )
    }

    public var messages: [ResponsesMessage] {
        typedInput?.compactMap {
            guard case .message(let message) = $0 else { return nil }
            return message
        } ?? []
    }

    public func withModel(_ model: String) -> Self {
        var copy = self
        copy.model = model
        return copy
    }

    public func withReasoningEffort(_ effort: ReasoningEffort) -> Self {
        var copy = self
        copy.reasoning = ReasoningConfig(effort)
        return copy
    }

    public func withReasoning(_ reasoning: ReasoningConfig) -> Self {
        var copy = self
        copy.reasoning = reasoning
        return copy
    }

    public func tryWithReasoningEffort(choice: String) throws -> Self {
        guard let effort = ReasoningEffort.parseChoice(choice) else {
            throw SoaError.invalidConfiguration(
                "unsupported reasoning effort \(String(reflecting: choice)); supported choices are none, minimal, low, medium, high, xhigh"
            )
        }
        return withReasoningEffort(effort)
    }

    public func withBodyField(_ key: String, value: JSONValue) -> Self {
        var copy = self
        copy.extraBody[key] = value
        return copy
    }

    public func withTools(_ tools: [ResponsesFunctionTool]) -> Self {
        var copy = self
        copy.tools = tools
        return copy
    }

    public func withToolChoice(_ toolChoice: ResponsesToolChoice) -> Self {
        var copy = self
        copy.toolChoice = toolChoice
        return copy
    }

    public func withParallelToolCalls(_ enabled: Bool) -> Self {
        var copy = self
        copy.parallelToolCalls = enabled
        return copy
    }

    public func withText(_ text: ResponsesTextConfig) -> Self {
        var copy = self
        copy.text = text
        return copy
    }

    public func withMetadata(_ key: String, value: JSONValue) -> Self {
        var copy = self
        copy.metadata[key] = value
        return copy
    }

    public func withItems(_ items: [ResponsesInputItem]) -> Self {
        var copy = self
        copy.typedInput = items
        copy.input = .array([])
        return copy
    }

    public func withMessages(_ messages: [ResponsesMessage]) -> Self {
        withItems(messages.map(ResponsesInputItem.message))
    }

    func intoJSONWithDefaults(
        defaultModel: String?,
        defaultReasoning: ReasoningEffort?
    ) throws -> JSONValue {
        try validateReservedExtraBodyFields()

        let resolvedModel = try resolvedModel(defaultModel: defaultModel)
        var root: [String: JSONValue] = [
            "model": .string(resolvedModel),
            "input": try encodedInput(for: .openAIAPI),
        ]
        if let reasoning = reasoning ?? defaultReasoning.map(ReasoningConfig.init) {
            root["reasoning"] = reasoning.toJSON()
        }
        if !tools.isEmpty {
            root["tools"] = .array(try tools.map(encodeTool))
            root["tool_choice"] = toolChoice.requestValueJSON
            root["parallel_tool_calls"] = .bool(parallelToolCalls)
        }
        if let text {
            root["text"] = text.toJSON()
        }
        if !metadata.isEmpty {
            root["metadata"] = .object(metadata)
        }
        for (key, value) in extraBody {
            root[key] = value
        }
        return .object(root)
    }

    func intoChatGPTJSONWithDefaults(
        defaultModel: String?,
        defaultReasoning: ReasoningEffort?
    ) throws -> JSONValue {
        try validateReservedExtraBodyFields()

        guard case .array(let items) = try encodedInput(for: .chatGPTBackend) else {
            throw SoaError.invalidConfiguration("chatgpt transport requires an array-shaped input")
        }

        let resolvedModel = try resolvedModel(defaultModel: defaultModel)
        let instructions = typedInput.map(chatGPTInstructions(from:))?.nilIfEmpty ?? ""

        var root: [String: JSONValue] = [
            "model": .string(resolvedModel),
            "input": .array(items),
            "stream": .bool(true),
            "store": .bool(false),
            "include": .array([]),
            "tools": .array(try tools.map(encodeTool)),
            "parallel_tool_calls": .bool(parallelToolCalls),
            "tool_choice": toolChoice.requestValueJSON,
            "instructions": .string(instructions),
        ]
        for (key, value) in extraBody {
            root[key] = value
        }
        if let text {
            root["text"] = text.toJSON()
        }
        if let reasoning = reasoning ?? defaultReasoning.map(ReasoningConfig.init),
           case .object(var config) = reasoning.toJSON() {
            if config["effort"] == .string("minimal") {
                config["effort"] = .string("low")
            }
            config["summary"] = .string("auto")
            root["reasoning"] = .object(config)
        }
        return .object(root)
    }

    private func validateReservedExtraBodyFields() throws {
        for reserved in ["model", "input", "reasoning", "tools", "tool_choice", "parallel_tool_calls", "instructions", "text"] {
            if extraBody.keys.contains(reserved) {
                throw SoaError.invalidConfiguration("\(reserved) must be set through the typed request fields")
            }
        }
    }

    private func resolvedModel(defaultModel: String?) throws -> String {
        let resolvedModel = (model ?? defaultModel)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedModel, !resolvedModel.isEmpty else {
            throw SoaError.invalidConfiguration(
                "a model must be supplied either on the request or on the client configuration"
            )
        }
        return resolvedModel
    }

    private func encodedInput(for transport: ResponsesTransportKind) throws -> JSONValue {
        if let typedInput {
            let normalizedItems: [ResponsesInputItem]
            if transport == .chatGPTBackend {
                normalizedItems = typedInput.filter { item in
                    guard case .message(let message) = item else { return true }
                    return message.role != .system
                }
            } else {
                normalizedItems = typedInput
            }
            return .array(normalizedItems.map { $0.encodedJSON(for: transport) })
        }

        switch transport {
        case .openAIAPI:
            return input
        case .chatGPTBackend:
            return chatGPTInput(from: input)
        }
    }
}

public struct ResponsesResponse: Sendable, Equatable {
    public let status: Int
    public let body: JSONValue
    public let meta: ResponseMeta

    public init(status: Int, body: JSONValue, meta: ResponseMeta = .init()) {
        self.status = status
        self.body = body
        self.meta = meta
    }

    public var outputText: String? {
        let texts = (body["output"]?.arrayValue ?? []).flatMap { item in
            (item["content"]?.arrayValue ?? []).compactMap { content -> String? in
                guard let type = content["type"]?.stringValue,
                      type == "output_text" || type == "refusal"
                else {
                    return nil
                }
                guard let text = content["text"]?.stringValue, !text.isEmpty else { return nil }
                return text
            }
        }
        let combined = texts.joined()
        return combined.isEmpty ? nil : combined
    }

    public var functionCalls: [ResponsesFunctionCall] {
        (body["output"]?.arrayValue ?? []).compactMap { item in
            guard item["type"]?.stringValue == "function_call",
                  let callID = item["call_id"]?.stringValue,
                  let name = item["name"]?.stringValue,
                  let argumentsJSON = item["arguments"]?.stringValue
            else {
                return nil
            }
            return ResponsesFunctionCall(
                id: item["id"]?.stringValue,
                callID: callID,
                name: name,
                argumentsJSON: argumentsJSON
            )
        }
    }

    public var refusalText: String? {
        let texts = (body["output"]?.arrayValue ?? []).flatMap { item in
            (item["content"]?.arrayValue ?? []).compactMap { content -> String? in
                if let refusal = content["refusal"]?.stringValue, !refusal.isEmpty {
                    return refusal
                }
                guard content["type"]?.stringValue == "refusal",
                      let text = content["text"]?.stringValue,
                      !text.isEmpty
                else {
                    return nil
                }
                return text
            }
        }
        let combined = texts.joined()
        return combined.isEmpty ? nil : combined
    }

    public func outputJSON() throws -> JSONValue {
        if let refusalText, !refusalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SoaError.responsesRequestFailed(status: status, "structured output refusal: \(refusalText)")
        }
        guard let outputText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outputText.isEmpty
        else {
            throw SoaError.responsesRequestFailed(status: status, "response did not contain structured JSON output")
        }
        guard let data = outputText.data(using: .utf8) else {
            throw SoaError.responsesRequestFailed(status: status, "structured output was not valid UTF-8")
        }
        return try JSONValue.decode(from: data)
    }

    public func decodeStructuredOutput<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try outputJSON().encodedData()
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public struct ResponsesStreamEvent: Sendable, Equatable {
    public let event: String
    public let type: String
    public let delta: String?
    public let text: String?
    public let response: ResponsesResponse?
    public let body: JSONValue

    public var textChunk: String? {
        switch type {
        case "response.output_text.delta":
            return delta
        default:
            return nil
        }
    }

    public var isTerminal: Bool {
        switch type {
        case "response.completed", "response.done", "response.failed", "response.incomplete", "response.error", "error":
            return true
        default:
            return false
        }
    }
}

public struct ResponsesStream: Sendable {
    public let meta: ResponseMeta
    public let events: AsyncThrowingStream<ResponsesStreamEvent, Error>

    public init(meta: ResponseMeta, events: AsyncThrowingStream<ResponsesStreamEvent, Error>) {
        self.meta = meta
        self.events = events
    }
}

public struct AuthRefreshOutcome: Sendable, Equatable {
    public let persistedTo: String?
    public let authState: AuthState

    public init(persistedTo: String?, authState: AuthState) {
        self.persistedTo = persistedTo
        self.authState = authState
    }
}

public struct SoaConfiguration: Sendable, Equatable {
    public var authPath: String?
    public var authHome: String?
    public var preferredTransportKind: ResponsesTransportKind?
    public var defaultModel: String?
    public var defaultReasoningEffort: ReasoningEffort?
    public var responsesBaseURL: String?
    public var authIssuerURL: String?
    public var clientVersion: String?
    public var organization: String?
    public var project: String?
    public var clientRequestID: String?

    public init(
        authPath: String? = nil,
        authHome: String? = nil,
        preferredTransportKind: ResponsesTransportKind? = nil,
        defaultModel: String? = nil,
        defaultReasoningEffort: ReasoningEffort? = nil,
        responsesBaseURL: String? = nil,
        authIssuerURL: String? = nil,
        clientVersion: String? = nil,
        organization: String? = nil,
        project: String? = nil,
        clientRequestID: String? = nil
    ) {
        self.authPath = authPath
        self.authHome = authHome
        self.preferredTransportKind = preferredTransportKind
        self.defaultModel = defaultModel
        self.defaultReasoningEffort = defaultReasoningEffort
        self.responsesBaseURL = responsesBaseURL
        self.authIssuerURL = authIssuerURL
        self.clientVersion = clientVersion
        self.organization = organization
        self.project = project
        self.clientRequestID = clientRequestID
    }
}

private func chatGPTInstructions(from items: [ResponsesInputItem]) -> String {
    items.compactMap { item -> String? in
        guard case .message(let message) = item, message.role == .system else {
            return nil
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    .joined(separator: "\n\n")
}

private func encodeTool(_ tool: ResponsesFunctionTool) throws -> JSONValue {
    guard let parameters = tool.parameters.objectValue else {
        throw SoaError.invalidConfiguration("tool parameters for \(String(reflecting: tool.name)) must be a JSON object")
    }
    return .object([
        "type": .string("function"),
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": .object(parameters),
        "strict": .bool(tool.strict),
    ])
}

private extension ResponsesInputItem {
    func encodedJSON(for transport: ResponsesTransportKind) -> JSONValue {
        switch self {
        case .message(let message):
            switch transport {
            case .openAIAPI:
                return .object([
                    "type": .string("message"),
                    "role": .string(message.role.rawValue),
                    "content": .string(message.content),
                ])
            case .chatGPTBackend:
                let contentType: String = message.role == .assistant ? "output_text" : "input_text"
                return .object([
                    "type": .string("message"),
                    "role": .string(message.role.rawValue),
                    "content": .array([
                        .object([
                            "type": .string(contentType),
                            "text": .string(message.content),
                        ]),
                    ]),
                ])
            }

        case .functionCall(let call):
            var object: [String: JSONValue] = [
                "type": .string("function_call"),
                "call_id": .string(call.callID),
                "name": .string(call.name),
                "arguments": .string(call.argumentsJSON),
            ]
            if let id = call.id {
                object["id"] = .string(id)
            }
            return .object(object)

        case .functionCallOutput(let output):
            return .object([
                "type": .string("function_call_output"),
                "call_id": .string(output.callID),
                "output": .string(output.output),
            ])
        }
    }
}

private extension ResponsesToolChoice {
    var requestValueJSON: JSONValue {
        switch self {
        case .auto:
            .string("auto")
        case .none:
            .string("none")
        case .required:
            .string("required")
        case .named(let name):
            .object([
                "type": .string("function"),
                "name": .string(name),
            ])
        }
    }
}

func chatGPTInput(from input: JSONValue) -> JSONValue {
    switch input {
    case .string(let text):
        return [
            [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": .string(text),
                    ],
                ],
            ],
        ]
    default:
        return input
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
