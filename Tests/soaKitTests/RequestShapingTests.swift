@testable import soaKit
import XCTest

final class RequestShapingTests: XCTestCase {
    func testOpenAIRequestSerializationWithDefaultsAndMetadata() throws {
        let request = ResponsesRequest("hello")
            .withBodyField("metadata", value: ["x": 1])
        let body = try request.intoJSONWithDefaults(
            defaultModel: "gpt-5-mini",
            defaultReasoning: .low
        )
        XCTAssertEqual(body["model"], .string("gpt-5-mini"))
        XCTAssertEqual(body["input"], .string("hello"))
        XCTAssertEqual(body["reasoning"]?["effort"], .string("low"))
        XCTAssertEqual(body["metadata"]?["x"], .number(1))
    }

    func testReservedFieldsAreRejectedBeforeRequestBuild() {
        let request = ResponsesRequest("hello").withBodyField("model", value: .string("bad"))
        XCTAssertThrowsError(try request.intoJSONWithDefaults(defaultModel: "gpt-5-mini", defaultReasoning: nil)) { error in
            XCTAssertEqual((error as? SoaError)?.category, .invalidConfiguration)
        }
    }

    func testChatGPTPayloadWrapsInputAndAddsBackendDefaults() throws {
        let request = try ResponsesRequest("hello")
            .withModel("gpt-5.4")
            .tryWithReasoningEffort(choice: "minimal")
        let body = try request.intoChatGPTJSONWithDefaults(defaultModel: nil, defaultReasoning: nil)
        XCTAssertEqual(body["model"], .string("gpt-5.4"))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["tool_choice"], .string("auto"))
        XCTAssertEqual(body["parallel_tool_calls"], .bool(false))
        XCTAssertEqual(body["include"], .array([]))
        XCTAssertEqual(body["store"], .bool(false))
        XCTAssertEqual(body["reasoning"]?["effort"], .string("low"))
        XCTAssertEqual(body["reasoning"]?["summary"], .string("auto"))
        XCTAssertEqual(body["input"]?.arrayValue?.first?["type"], .string("message"))
        XCTAssertEqual(body["input"]?.arrayValue?.first?["role"], .string("user"))
        XCTAssertEqual(body["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["type"], .string("input_text"))
        XCTAssertEqual(body["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["text"], .string("hello"))
    }

    func testTypedChatGPTRequestMovesSystemMessagesToInstructionsAndEncodesTools() throws {
        let weatherTool = try ResponsesFunctionTool(
            name: "lookup_weather",
            description: "Look up the weather",
            parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        )
        let request = ResponsesRequest(
            model: "gpt-5.4",
            items: [
                .message(.system("Keep answers terse.")),
                .message(.user("How is Seoul?")),
                .functionCallOutput(.init(callID: "call_weather", output: #"{"temp_c":19}"#)),
            ],
            tools: [weatherTool],
            toolChoice: .named("lookup_weather"),
            parallelToolCalls: true,
            reasoning: ReasoningConfig(.minimal)
        )

        let body = try request.intoChatGPTJSONWithDefaults(defaultModel: nil, defaultReasoning: nil)
        XCTAssertEqual(body["model"], .string("gpt-5.4"))
        XCTAssertEqual(body["instructions"], .string("Keep answers terse."))
        XCTAssertEqual(body["input"]?.arrayValue?.count, 2)
        XCTAssertEqual(body["input"]?.arrayValue?.first?["role"], .string("user"))
        XCTAssertEqual(body["input"]?.arrayValue?.last?["type"], .string("function_call_output"))
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["name"], .string("lookup_weather"))
        XCTAssertEqual(body["parallel_tool_calls"], .bool(true))
        XCTAssertEqual(body["tool_choice"]?["name"], .string("lookup_weather"))
        XCTAssertEqual(body["reasoning"]?["effort"], .string("low"))
        XCTAssertEqual(body["reasoning"]?["summary"], .string("auto"))
    }

    func testStructuredOutputHelperBuildsTextFormatMetadataAndDecodesJSON() throws {
        struct CalendarEvent: Decodable, Equatable {
            let name: String
            let date: String
        }

        let request = ResponsesRequest("extract the calendar event")
            .withText(.jsonSchema(
                name: "calendar_event",
                schema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "date": ["type": "string"],
                    ],
                    "required": ["name", "date"],
                    "additionalProperties": false,
                ],
                description: "A calendar event",
                strict: true
            ))
            .withMetadata("trace", value: "structured-test")

        let body = try request.intoJSONWithDefaults(defaultModel: "gpt-5-mini", defaultReasoning: nil)
        XCTAssertEqual(body["text"]?["format"]?["type"], .string("json_schema"))
        XCTAssertEqual(body["text"]?["format"]?["name"], .string("calendar_event"))
        XCTAssertEqual(body["text"]?["format"]?["strict"], .bool(true))
        XCTAssertEqual(body["metadata"]?["trace"], .string("structured-test"))

        let response = ResponsesResponse(
            status: 200,
            body: [
                "output": [
                    [
                        "type": "message",
                        "content": [
                            [
                                "type": "output_text",
                                "text": #"{"name":"Launch","date":"2026-05-16"}"#,
                            ],
                        ],
                    ],
                ],
            ],
            meta: ResponseMeta(requestID: "req_structured_test")
        )
        XCTAssertEqual(response.meta.requestID, "req_structured_test")
        XCTAssertEqual(try response.decodeStructuredOutput(CalendarEvent.self), CalendarEvent(name: "Launch", date: "2026-05-16"))
    }

    func testChatGPTSSEParserRebuildsFunctionCallArgumentsFromDeltaEvents() throws {
        let body = #"""
        event: response.output_item.added
        data: {"output_index":0,"item":{"id":"item_1","type":"function_call","call_id":"call_weather","name":"lookup_weather","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"item_id":"item_1","delta":"{\"city\":"}

        event: response.function_call_arguments.delta
        data: {"item_id":"item_1","delta":"\"Seoul\"}"}

        event: response.function_call_arguments.done
        data: {"item_id":"item_1","arguments":"{\"city\":\"Seoul\"}"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_fc","status":"completed","output":[]}}
        """#

        let value = try parseChatGPTSSEBody(Data(body.utf8), status: 200)
        let response = ResponsesResponse(status: 200, body: value)
        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls.first?.callID, "call_weather")
        XCTAssertEqual(response.functionCalls.first?.name, "lookup_weather")
        XCTAssertEqual(response.functionCalls.first?.argumentsJSON, #"{"city":"Seoul"}"#)
    }

    func testParseCompletedChatGPTSSEBody() throws {
        let body = "event: response.completed\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_chatgpt\",\"status\":\"completed\"}}\n\n"
        let value = try parseChatGPTSSEBody(Data(body.utf8), status: 200)
        XCTAssertEqual(value["id"], .string("resp_chatgpt"))
        XCTAssertEqual(value["status"], .string("completed"))
    }

    func testParseFailedChatGPTSSEBodySurfacesStructuredError() {
        let body = "event: response.failed\n" +
            "data: {\"error\":{\"message\":\"invalid api key\",\"code\":\"invalid_api_key\"}}\n\n"
        XCTAssertThrowsError(try parseChatGPTSSEBody(Data(body.utf8), status: 401)) { error in
            let providerError = error as? SoaError
            XCTAssertEqual(providerError?.category, .responsesRequestFailed)
            XCTAssertTrue(providerError?.message.contains("invalid api key") == true)
        }
    }
}
