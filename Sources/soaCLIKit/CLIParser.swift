import soaKit
import Foundation

public struct CLIParser {
    public init() {}

    public func parse(arguments: [String]) throws -> CLIInvocation {
        let executable = arguments.first ?? "soa"
        var args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") || args.isEmpty {
            throw CLIParseSignal.help(CLITextRenderer.usage(executableName: executable))
        }

        var json = false
        while let first = args.first, first == "--json" {
            json = true
            args.removeFirst()
        }

        guard let provider = args.first else {
            throw CLIParseSignal.help(CLITextRenderer.usage(executableName: executable))
        }
        args.removeFirst()

        switch provider {
        case "codex":
            return try parseCodex(executable: executable, json: json, arguments: &args)
        case "gemini":
            return try parseGemini(executable: executable, json: json, arguments: &args)
        default:
            throw CLIParseSignal.failure("unknown provider \(provider)")
        }
    }

    private func parseCodex(executable: String, json: Bool, arguments args: inout [String]) throws -> CLIInvocation {
        var outputJSON = json
        var configuration = ProviderConfigurationOverrides()

        func requireValue(_ flag: String) throws -> String {
            guard !args.isEmpty else {
                throw CLIParseSignal.failure("missing value for \(flag)")
            }
            return args.removeFirst()
        }

        while let first = args.first, first.hasPrefix("--") {
            switch first {
            case "--json":
                outputJSON = true
                args.removeFirst()
            case "--auth-path":
                args.removeFirst()
                configuration.authPath = try requireValue("--auth-path")
            case "--auth-home":
                args.removeFirst()
                configuration.authHome = try requireValue("--auth-home")
            case "--base-url":
                args.removeFirst()
                configuration.responsesBaseURL = try requireValue("--base-url")
            case "--default-model":
                args.removeFirst()
                configuration.defaultModel = try requireValue("--default-model")
            case "--default-effort":
                args.removeFirst()
                let raw = try requireValue("--default-effort")
                configuration.defaultReasoningEffort = ReasoningEffort.parseChoice(raw) ?? .raw(raw)
            case "--issuer":
                args.removeFirst()
                configuration.authIssuerURL = try requireValue("--issuer")
            case "--client-version":
                args.removeFirst()
                configuration.clientVersion = try requireValue("--client-version")
            case "--organization":
                args.removeFirst()
                configuration.organization = try requireValue("--organization")
            case "--project":
                args.removeFirst()
                configuration.project = try requireValue("--project")
            case "--client-request-id":
                args.removeFirst()
                configuration.clientRequestID = try requireValue("--client-request-id")
            default:
                throw CLIParseSignal.failure("unknown codex option \(first)")
            }
        }

        guard let command = args.first else {
            throw CLIParseSignal.failure("codex requires a command")
        }
        args.removeFirst()

        let parsedCommand: CodexCommand
        switch command {
        case "send":
            parsedCommand = try parseCodexSend(arguments: &args)
        case "models":
            guard args.first == "list" else {
                throw CLIParseSignal.failure("codex models requires the subcommand list")
            }
            args.removeFirst()
            parsedCommand = .modelsList
        case "auth":
            guard args.first == "status" else {
                throw CLIParseSignal.failure("codex auth requires the subcommand status")
            }
            args.removeFirst()
            parsedCommand = .authStatus
        case "relogin":
            parsedCommand = try parseRelogin(arguments: &args)
        default:
            throw CLIParseSignal.failure("unknown codex command \(command)")
        }

        guard args.isEmpty else {
            throw CLIParseSignal.failure("unexpected trailing arguments: \(args.joined(separator: " "))")
        }

        return CLIInvocation(
            executableName: executable,
            json: outputJSON,
            configuration: configuration,
            command: .codex(parsedCommand)
        )
    }

    private func parseCodexSend(arguments args: inout [String]) throws -> CodexCommand {
        var model: String?
        var effort: String?
        var prompt: String?
        var stream = false
        var stdin = false

        while !args.isEmpty {
            let current = args.removeFirst()
            switch current {
            case "--stdin":
                stdin = true
            case "--stream":
                stream = true
            case "--model":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --model") }
                model = args.removeFirst()
            case "--effort":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --effort") }
                effort = args.removeFirst()
            case let value where value.hasPrefix("--"):
                throw CLIParseSignal.failure("unknown send option \(value)")
            default:
                if prompt == nil {
                    prompt = current
                } else {
                    prompt! += " \(current)"
                }
            }
        }

        if stdin, prompt != nil {
            throw CLIParseSignal.failure("prompt argument and --stdin cannot be used together")
        }
        guard stdin || prompt?.isEmpty == false else {
            throw CLIParseSignal.failure("send requires a prompt or --stdin")
        }
        return .send(prompt: prompt, stdin: stdin, model: model, effort: effort, stream: stream)
    }

    private func parseRelogin(arguments args: inout [String]) throws -> CodexCommand {
        var options = BrowserReloginOptions()

        func requireValue(_ flag: String) throws -> String {
            guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for \(flag)") }
            return args.removeFirst()
        }

        while !args.isEmpty {
            let current = args.removeFirst()
            switch current {
            case "--no-browser":
                options.openBrowser = false
            case "--callback-port":
                let raw = try requireValue("--callback-port")
                guard let port = UInt16(raw) else { throw CLIParseSignal.failure("--callback-port must be a UInt16") }
                options.callbackPort = port
            case "--timeout-seconds":
                let raw = try requireValue("--timeout-seconds")
                guard let seconds = Double(raw), seconds > 0 else { throw CLIParseSignal.failure("--timeout-seconds must be greater than zero") }
                options.timeoutSeconds = seconds
            case "--persist-path":
                options.persistPath = try requireValue("--persist-path")
            case "--client-id":
                options.clientID = try requireValue("--client-id")
            case "--allowed-workspace-id":
                options.allowedWorkspaceID = try requireValue("--allowed-workspace-id")
            case "--issuer":
                options.issuer = try requireValue("--issuer")
            default:
                throw CLIParseSignal.failure("unknown relogin option \(current)")
            }
        }

        return .relogin(options)
    }

    private func parseGemini(executable: String, json: Bool, arguments args: inout [String]) throws -> CLIInvocation {
        var outputJSON = json
        while args.first == "--json" {
            outputJSON = true
            args.removeFirst()
        }

        guard let command = args.first else {
            throw CLIParseSignal.failure("gemini requires a command")
        }
        args.removeFirst()

        let parsedCommand: GeminiCommand
        switch command {
        case "generate":
            parsedCommand = try parseGeminiGenerate(arguments: &args)
        case "models":
            parsedCommand = try parseGeminiModels(arguments: &args)
        default:
            throw CLIParseSignal.failure("unknown gemini command \(command)")
        }

        guard args.isEmpty else {
            throw CLIParseSignal.failure("unexpected trailing arguments: \(args.joined(separator: " "))")
        }

        return CLIInvocation(
            executableName: executable,
            json: outputJSON,
            configuration: .init(),
            command: .gemini(parsedCommand)
        )
    }

    private func parseGeminiGenerate(arguments args: inout [String]) throws -> GeminiCommand {
        var prompt: String?
        var model: String?
        var adapterPath = GeminiClient.defaultAdapterPath
        var nodePath = GeminiClient.defaultNodePath

        while !args.isEmpty {
            let current = args.removeFirst()
            switch current {
            case "--model":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --model") }
                model = args.removeFirst()
            case "--adapter-path":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --adapter-path") }
                adapterPath = args.removeFirst()
            case "--node-path":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --node-path") }
                nodePath = args.removeFirst()
            case let value where value.hasPrefix("--"):
                throw CLIParseSignal.failure("unknown gemini generate option \(value)")
            default:
                if prompt == nil {
                    prompt = current
                } else {
                    prompt! += " \(current)"
                }
            }
        }

        guard let prompt, !prompt.isEmpty else {
            throw CLIParseSignal.failure("gemini generate requires a prompt")
        }
        return .generate(prompt: prompt, model: model, adapterPath: adapterPath, nodePath: nodePath)
    }

    private func parseGeminiModels(arguments args: inout [String]) throws -> GeminiCommand {
        var adapterPath = GeminiClient.defaultAdapterPath
        var nodePath = GeminiClient.defaultNodePath

        while !args.isEmpty {
            let current = args.removeFirst()
            switch current {
            case "--adapter-path":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --adapter-path") }
                adapterPath = args.removeFirst()
            case "--node-path":
                guard !args.isEmpty else { throw CLIParseSignal.failure("missing value for --node-path") }
                nodePath = args.removeFirst()
            default:
                throw CLIParseSignal.failure("unknown gemini models option \(current)")
            }
        }
        return .models(adapterPath: adapterPath, nodePath: nodePath)
    }
}

public enum CLIParseSignal: Error, Equatable, LocalizedError {
    case help(String)
    case failure(String)

    public var errorDescription: String? {
        switch self {
        case .help(let text), .failure(let text): text
        }
    }
}
