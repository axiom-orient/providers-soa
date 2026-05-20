@testable import soaKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

final class StreamingResponseTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testOpenAIStreamAccumulatesTextMetaAndConfiguredHeaders() async throws {
        URLProtocolStub.install { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Organization"), "org_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "proj_test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client-Request-Id"), "cid-stream-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

            let body = try JSONValue.decode(from: Data(try requestBodyString(from: request).utf8))
            XCTAssertEqual(body["stream"], .bool(true))
            XCTAssertEqual(body["model"], .string("gpt-5-mini"))

            let streamBody = #"""
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"hello "}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"world"}

            event: response.output_text.done
            data: {"type":"response.output_text.done","text":"hello world"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_stream","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"hello world"}]}]}}

            """#
            return stubResponse(
                url: try XCTUnwrap(request.url),
                status: 200,
                body: streamBody,
                headers: ["Content-Type": "text/event-stream", "x-request-id": "req_stream_test"]
            )
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authPath = directory.appendingPathComponent("auth.json").path
        try #"{"OPENAI_API_KEY":"sk-test"}"#.write(toFile: authPath, atomically: true, encoding: .utf8)

        let client = try SoaClient(
            configuration: SoaConfiguration(
                authPath: authPath,
                preferredTransportKind: .openAIAPI,
                defaultModel: "gpt-5-mini",
                responsesBaseURL: "https://stub.test",
                organization: "org_test",
                project: "proj_test",
                clientRequestID: "cid-stream-test"
            ),
            session: makeStubSession()
        )

        let stream = try await client.streamResponse(ResponsesRequest("hello"))
        XCTAssertEqual(stream.meta.requestID, "req_stream_test")

        var output = ""
        var sawTerminal = false
        var final: ResponsesResponse?
        for try await event in stream.events {
            if let chunk = event.textChunk {
                output += chunk
            }
            if event.isTerminal {
                sawTerminal = true
                final = event.response
            }
        }

        XCTAssertEqual(output, "hello world")
        XCTAssertTrue(sawTerminal)
        XCTAssertEqual(final?.meta.requestID, "req_stream_test")
        XCTAssertEqual(final?.outputText, "hello world")
    }
}
