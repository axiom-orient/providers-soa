import soaKit
import Foundation

public struct ProviderConfigurationOverrides: Sendable, Equatable {
    public var authPath: String?
    public var authHome: String?
    public var responsesBaseURL: String?
    public var defaultModel: String?
    public var defaultReasoningEffort: ReasoningEffort?
    public var authIssuerURL: String?
    public var clientVersion: String?
    public var organization: String?
    public var project: String?
    public var clientRequestID: String?

    public init(
        authPath: String? = nil,
        authHome: String? = nil,
        responsesBaseURL: String? = nil,
        defaultModel: String? = nil,
        defaultReasoningEffort: ReasoningEffort? = nil,
        authIssuerURL: String? = nil,
        clientVersion: String? = nil,
        organization: String? = nil,
        project: String? = nil,
        clientRequestID: String? = nil
    ) {
        self.authPath = authPath
        self.authHome = authHome
        self.responsesBaseURL = responsesBaseURL
        self.defaultModel = defaultModel
        self.defaultReasoningEffort = defaultReasoningEffort
        self.authIssuerURL = authIssuerURL
        self.clientVersion = clientVersion
        self.organization = organization
        self.project = project
        self.clientRequestID = clientRequestID
    }

    func applying(preferredTransport: ResponsesTransportKind? = nil) -> SoaConfiguration {
        SoaConfiguration(
            authPath: authPath,
            authHome: authHome,
            preferredTransportKind: preferredTransport,
            defaultModel: defaultModel,
            defaultReasoningEffort: defaultReasoningEffort,
            responsesBaseURL: responsesBaseURL,
            authIssuerURL: authIssuerURL,
            clientVersion: clientVersion,
            organization: organization,
            project: project,
            clientRequestID: clientRequestID
        )
    }
}

public enum CLICommand: Sendable, Equatable {
    case codex(CodexCommand)
    case gemini(GeminiCommand)
}

public enum CodexCommand: Sendable, Equatable {
    case send(prompt: String?, stdin: Bool, model: String?, effort: String?, stream: Bool)
    case modelsList
    case authStatus
    case relogin(BrowserReloginOptions)
}

public enum GeminiCommand: Sendable, Equatable {
    case generate(prompt: String, model: String?, adapterPath: String, nodePath: String)
    case models(adapterPath: String, nodePath: String)
}

public struct CLIInvocation: Sendable, Equatable {
    public var executableName: String
    public var json: Bool
    public var configuration: ProviderConfigurationOverrides
    public var command: CLICommand

    public init(
        executableName: String,
        json: Bool = false,
        configuration: ProviderConfigurationOverrides,
        command: CLICommand
    ) {
        self.executableName = executableName
        self.json = json
        self.configuration = configuration
        self.command = command
    }
}

public struct CLIResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
