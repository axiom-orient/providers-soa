import Foundation

public struct GeminiGenerateRequest: Sendable, Equatable, Codable {
    public var prompt: String
    public var model: String?

    public init(_ prompt: String, model: String? = nil) {
        self.prompt = prompt
        self.model = model
    }

    public func withModel(_ model: String) -> Self {
        var copy = self
        copy.model = model
        return copy
    }
}

public struct GeminiGenerateResponse: Sendable, Equatable, Codable {
    public let text: String
    public let provider: String
    public let model: String
}

public struct GeminiModelQuota: Sendable, Equatable, Codable {
    public let remainingAmount: UInt64?
    public let remainingFraction: Double?
    public let resetTime: String?
}

public struct GeminiModelInfo: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let description: String
    public let tier: String
    public let source: String
    public let quota: GeminiModelQuota?
}

public struct GeminiModelsResponse: Sendable, Equatable, Codable {
    public let provider: String
    public let releaseChannel: String
    public let models: [GeminiModelInfo]
}

public enum GeminiError: Error, Sendable, Equatable, LocalizedError {
    case missingPrompt
    case adapterStart(String)
    case adapterProcess(String)
    case emptyResponse
    case write(String)
    case decode(String)
    case rpc(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "gemini prompt is required"
        case .adapterStart(let message):
            return "failed to start Gemini Core Adapter: \(message)"
        case .adapterProcess(let message):
            return "Gemini Core Adapter failed: \(message)"
        case .emptyResponse:
            return "Gemini Core Adapter returned an empty response"
        case .write(let message):
            return "failed to write Gemini Core Adapter request: \(message)"
        case .decode(let message):
            return "failed to decode Gemini Core Adapter response: \(message)"
        case let .rpc(code, message):
            return "Gemini Core Adapter RPC error code=\(code) message=\(message)"
        }
    }
}

public struct GeminiClient: Sendable, Equatable {
    public static let defaultNodePath = "node"
    public static let defaultAdapterPath = "gemini-core-adapter/dist/main.js"

    public var nodePath: String
    public var adapterPath: String

    public init(
        nodePath: String = Self.defaultNodePath,
        adapterPath: String = Self.defaultAdapterPath
    ) {
        self.nodePath = nodePath
        self.adapterPath = adapterPath
    }

    public func generate(_ request: GeminiGenerateRequest) throws -> GeminiGenerateResponse {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw GeminiError.missingPrompt
        }
        var params: [String: JSONValue] = ["prompt": .string(prompt)]
        if let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            params["model"] = .string(model)
        }
        return try callAdapter(
            payload: .object([
                "id": .string("1"),
                "method": .string("generate"),
                "params": .object(params),
            ])
        )
    }

    public func models() throws -> GeminiModelsResponse {
        try callAdapter(
            payload: .object([
                "id": .string("1"),
                "method": .string("models"),
                "params": .object([:]),
            ])
        )
    }

    private func callAdapter<T: Decodable>(payload: JSONValue) throws -> T {
        guard FileManager.default.fileExists(atPath: adapterPath) else {
            throw GeminiError.adapterStart(
                "adapter not found at \(adapterPath); run `cd gemini-core-adapter && npm install && npm run build`"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [nodePath, adapterPath]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GeminiError.adapterStart(sanitizeMessage(error.localizedDescription))
        }

        do {
            let data = try payload.encodedData() + Data("\n".utf8)
            try stdin.fileHandleForWriting.write(contentsOf: data)
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw GeminiError.write(sanitizeMessage(error.localizedDescription))
        }

        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw GeminiError.adapterProcess(sanitizeMessage(stderrText.isEmpty ? "exit status \(process.terminationStatus)" : stderrText))
        }

        return try decodeAdapterResponse(stdoutData)
    }
}

func decodeAdapterResponse<T: Decodable>(_ data: Data) throws -> T {
    let stdout = String(decoding: data, as: UTF8.self)
    var lastDecodeError: Error?
    for line in stdout.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
        guard line.first == "{" else { continue }
        do {
            let response = try JSONDecoder().decode(RPCResponse<T>.self, from: Data(line.utf8))
            return try response.resultValue()
        } catch let error as GeminiError {
            throw error
        } catch {
            lastDecodeError = error
        }
    }
    if let lastDecodeError {
        throw GeminiError.decode(sanitizeMessage(lastDecodeError.localizedDescription))
    }
    throw GeminiError.emptyResponse
}

private struct RPCResponse<T: Decodable>: Decodable {
    let result: T?
    let error: RPCError?

    func resultValue() throws -> T {
        if let error {
            throw GeminiError.rpc(code: error.code, message: sanitizeMessage(error.message))
        }
        guard let result else {
            throw GeminiError.emptyResponse
        }
        return result
    }
}

private struct RPCError: Decodable {
    let code: Int
    let message: String
}
