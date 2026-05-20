import soaKit
import Foundation

public struct CLIApplication {
    private let progress: @Sendable (String) -> Void

    public init(progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.progress = progress
    }

    public func run(arguments: [String]) async -> CLIResult {
        do {
            let invocation = try CLIParser().parse(arguments: arguments)
            let stdout = try await execute(invocation: invocation)
            return CLIResult(exitCode: 0, stdout: stdout)
        } catch let signal as CLIParseSignal {
            switch signal {
            case .help(let text):
                return CLIResult(exitCode: 0, stdout: text + "\n")
            case .failure(let text):
                return CLIResult(exitCode: 1, stderr: text + "\n")
            }
        } catch {
            return CLIResult(exitCode: 1, stderr: CLITextRenderer.renderError(error) + "\n")
        }
    }

    private func execute(invocation: CLIInvocation) async throws -> String {
        switch invocation.command {
        case .codex(let command):
            return try await executeCodex(invocation: invocation, command: command)
        case .gemini(let command):
            return try executeGemini(json: invocation.json, command: command)
        }
    }

    private func executeCodex(invocation: CLIInvocation, command: CodexCommand) async throws -> String {
        let configuration = invocation.configuration.applying(preferredTransport: .chatGPTBackend)
        let client = try SoaClient(configuration: configuration)

        switch command {
        case let .send(prompt, stdin, model, effort, stream):
            let resolvedPrompt = try resolvePrompt(prompt: prompt, stdin: stdin)
            var request = ResponsesRequest(resolvedPrompt)
            if let model { request = request.withModel(model) }
            if let effort { request = try request.tryWithReasoningEffort(choice: effort) }
            if stream {
                let responseStream = try await client.streamResponse(request)
                var output = ""
                for try await event in responseStream.events {
                    if invocation.json {
                        output += try CLITextRenderer.renderStreamEventJSON(event) + "\n"
                    } else if let chunk = event.textChunk {
                        output += chunk
                    }
                }
                return invocation.json ? output : output + "\n"
            }
            let response = try await client.createResponse(request)
            if invocation.json {
                return try CLITextRenderer.renderSendJSON(response) + "\n"
            }
            if let outputText = response.outputText {
                return outputText + "\n"
            }
            return try response.body.prettyPrinted() + "\n"

        case .modelsList:
            let models = try await client.listModels()
            let transport = try await client.transportKind()
            if !invocation.json {
                return CLITextRenderer.renderModels(models, transport: transport) + "\n"
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(models)
            return String(decoding: data, as: UTF8.self) + "\n"

        case .authStatus:
            let state = try await client.authState()
            if invocation.json {
                return try CLITextRenderer.renderAuthStatusJSON(state) + "\n"
            }
            return CLITextRenderer.renderAuthStatus(state) + "\n"

        case let .relogin(options):
            let session = try await client.startBrowserReloginSession(options: options)
            if invocation.json {
                progress(try CLITextRenderer.renderReloginStartedJSON(authURL: session.authURL, callbackPort: session.callbackPort) + "\n")
            } else {
                progress(CLITextRenderer.renderReloginStarted(authURL: session.authURL, callbackPort: session.callbackPort, openedBrowser: options.openBrowser) + "\n")
            }
            let outcome = try await session.wait()
            if invocation.json {
                return try CLITextRenderer.renderBrowserReloginJSON(outcome) + "\n"
            }
            return CLITextRenderer.renderBrowserRelogin(outcome) + "\n"
        }
    }

    private func executeGemini(json: Bool, command: GeminiCommand) throws -> String {
        switch command {
        case let .generate(prompt, model, adapterPath, nodePath):
            var request = GeminiGenerateRequest(prompt)
            if let model {
                request = request.withModel(model)
            }
            let response = try GeminiClient(nodePath: nodePath, adapterPath: adapterPath).generate(request)
            if json {
                return try prettyJSON(response) + "\n"
            }
            return response.text + "\n"
        case let .models(adapterPath, nodePath):
            let response = try GeminiClient(nodePath: nodePath, adapterPath: adapterPath).models()
            if json {
                return try prettyJSON(response) + "\n"
            }
            return CLITextRenderer.renderGeminiModels(response) + "\n"
        }
    }

    private func resolvePrompt(prompt: String?, stdin: Bool) throws -> String {
        switch (prompt, stdin) {
        case let (.some(prompt), false):
            return prompt
        case (.none, true):
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        case (.some, true):
            throw CLIParseSignal.failure("prompt argument and --stdin cannot be used together")
        case (.none, false):
            throw CLIParseSignal.failure("send requires a prompt or --stdin")
        }
    }

    private func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
