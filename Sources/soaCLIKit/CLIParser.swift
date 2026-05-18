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

        var useAPIKeyTransport = false
        var configuration = ProviderConfigurationOverrides()

        func requireValue(_ flag: String) throws -> String {
            guard !args.isEmpty else {
                throw CLIParseSignal.failure("missing value for \(flag)")
            }
            return args.removeFirst()
        }

        while let first = args.first, first.hasPrefix("--") {
            switch first {
            case "--api-key":
                useAPIKeyTransport = true
                args.removeFirst()
            case "--auth-path":
                args.removeFirst()
                configuration.authPath = try requireValue("--auth-path")
            case "--api-key-value":
                useAPIKeyTransport = true
                args.removeFirst()
                configuration.apiKey = try requireValue("--api-key-value")
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
                throw CLIParseSignal.failure("unknown global option \(first)")
            }
        }

        guard let command = args.first else {
            throw CLIParseSignal.help(CLITextRenderer.usage(executableName: executable))
        }
        args.removeFirst()

        let parsedCommand: CLICommand
        switch command {
        case "send":
            parsedCommand = try parseSend(arguments: &args)
        case "models":
            guard args.first == "list" else {
                throw CLIParseSignal.failure("models requires the subcommand list")
            }
            args.removeFirst()
            parsedCommand = .modelsList
        case "auth":
            guard let subcommand = args.first else {
                throw CLIParseSignal.failure("auth requires a subcommand")
            }
            args.removeFirst()
            switch subcommand {
            case "status":
                parsedCommand = .authStatus
            case "refresh":
                parsedCommand = .authRefresh
            default:
                throw CLIParseSignal.failure("auth requires the subcommand status or refresh")
            }
        case "relogin":
            parsedCommand = try parseRelogin(arguments: &args)
        default:
            throw CLIParseSignal.failure("unknown command \(command)")
        }

        guard args.isEmpty else {
            throw CLIParseSignal.failure("unexpected trailing arguments: \(args.joined(separator: " "))")
        }

        return CLIInvocation(
            executableName: executable,
            useAPIKeyTransport: useAPIKeyTransport,
            configuration: configuration,
            command: parsedCommand
        )
    }

    private func parseSend(arguments args: inout [String]) throws -> CLICommand {
        var model: String?
        var effort: String?
        var prompt: String?
        var stream = false

        while !args.isEmpty {
            let current = args.removeFirst()
            switch current {
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

        guard let prompt, !prompt.isEmpty else {
            throw CLIParseSignal.failure("send requires a prompt")
        }
        return .send(prompt: prompt, model: model, effort: effort, stream: stream)
    }

    private func parseRelogin(arguments args: inout [String]) throws -> CLICommand {
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
