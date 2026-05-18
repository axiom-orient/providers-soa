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
        let transport: ResponsesTransportKind = invocation.useAPIKeyTransport ? .openAIAPI : .chatGPTBackend
        let configuration = invocation.configuration.applying(transport: transport)
        let client = try SoaClient(configuration: configuration)

        switch invocation.command {
        case let .send(prompt, model, effort, stream):
            var request = ResponsesRequest(prompt)
            if let model { request = request.withModel(model) }
            if let effort { request = try request.tryWithReasoningEffort(choice: effort) }
            if stream {
                let responseStream = try await client.streamResponse(request)
                var output = ""
                for try await event in responseStream.events {
                    if let chunk = event.textChunk {
                        output += chunk
                    }
                }
                return output + "\n"
            }
            let response = try await client.createResponse(request)
            if let outputText = response.outputText {
                return outputText + "\n"
            }
            return try response.body.prettyPrinted() + "\n"

        case .modelsList:
            let models = try await client.listModels()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(models)
            return String(decoding: data, as: UTF8.self) + "\n"

        case .authStatus:
            let state = try await client.authState()
            return CLITextRenderer.renderAuthStatus(state) + "\n"

        case .authRefresh:
            if invocation.useAPIKeyTransport {
                throw CLIParseSignal.failure("--api-key cannot be used with auth refresh")
            }
            let outcome = try await client.refreshAuth()
            return CLITextRenderer.renderAuthRefresh(outcome) + "\n"

        case let .relogin(options):
            if invocation.useAPIKeyTransport {
                throw CLIParseSignal.failure("--api-key cannot be used with relogin")
            }
            let session = try await client.startBrowserReloginSession(options: options)
            progress(CLITextRenderer.renderReloginStarted(authURL: session.authURL, callbackPort: session.callbackPort, openedBrowser: options.openBrowser) + "\n")
            let outcome = try await session.wait()
            return CLITextRenderer.renderBrowserRelogin(outcome) + "\n"
        }
    }
}
