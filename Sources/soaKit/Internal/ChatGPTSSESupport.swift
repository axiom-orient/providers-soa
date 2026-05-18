import Foundation

private struct ChatGPTSSEEvent {
    let name: String?
    let dataLines: [String]

    var data: String { dataLines.joined(separator: "\n") }

    var payload: JSONValue? {
        guard !data.isEmpty else { return nil }
        return try? JSONValue.decode(from: Data(data.utf8))
    }
}

private struct ChatGPTFunctionCallState {
    var id: String?
    var itemID: String?
    var callID: String
    var name: String
    var argumentsJSON: String
    var outputIndex: Int?

    var itemJSON: JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("function_call"),
            "call_id": .string(callID),
            "name": .string(name),
            "arguments": .string(argumentsJSON),
        ]
        if let id {
            object["id"] = .string(id)
        } else if let itemID {
            object["id"] = .string(itemID)
        }
        return .object(object)
    }
}

private struct ChatGPTSSEAccumulator {
    private var completedResponse: [String: JSONValue]?
    private var outputItems: [Int: JSONValue] = [:]
    private var fallbackOutputTexts: [Int: [Int: String]] = [:]
    private var toolCallsByCallID: [String: ChatGPTFunctionCallState] = [:]
    private var toolCallOrder: [String] = []
    private var toolCallIDsByItemID: [String: String] = [:]
    private var toolArgumentDeltasByItemID: [String: String] = [:]
    private var callOrderByOutputIndex: [Int: [String]] = [:]

    mutating func consume(event: ChatGPTSSEEvent, status: Int) throws {
        switch event.name {
        case "response.output_item.added", "response.output_item.done":
            guard let payload = event.payload else { return }
            let outputIndex = Int(payload["output_index"]?.doubleValue ?? -1)
            let item = payload["item"] ?? payload
            guard outputIndex >= 0, item.objectValue != nil else { return }
            try storeOutputItem(item, outputIndex: outputIndex)

        case "response.output_text.delta":
            guard let payload = event.payload,
                  let delta = payload["delta"]?.stringValue,
                  !delta.isEmpty
            else {
                return
            }
            let outputIndex = Int(payload["output_index"]?.doubleValue ?? 0)
            let contentIndex = Int(payload["content_index"]?.doubleValue ?? 0)
            var content = fallbackOutputTexts[outputIndex] ?? [:]
            content[contentIndex, default: ""] += delta
            fallbackOutputTexts[outputIndex] = content

        case "response.output_text.done", "response.refusal.done":
            guard let payload = event.payload,
                  let text = payload["text"]?.stringValue
            else {
                return
            }
            let outputIndex = Int(payload["output_index"]?.doubleValue ?? 0)
            let contentIndex = Int(payload["content_index"]?.doubleValue ?? 0)
            var content = fallbackOutputTexts[outputIndex] ?? [:]
            content[contentIndex] = text
            fallbackOutputTexts[outputIndex] = content

        case "response.function_call_arguments.delta":
            guard let payload = event.payload,
                  let itemID = payload["item_id"]?.stringValue,
                  let delta = payload["delta"]?.stringValue,
                  !delta.isEmpty
            else {
                return
            }
            toolArgumentDeltasByItemID[itemID, default: ""] += delta
            try updateToolCall(from: payload, itemID: itemID)

        case "response.function_call_arguments.done":
            guard let payload = event.payload else { return }
            let itemID = payload["item_id"]?.stringValue
            if let itemID, let arguments = payload["arguments"]?.stringValue {
                toolArgumentDeltasByItemID[itemID] = arguments
                try updateToolCall(from: payload, itemID: itemID)
            }

        case "response.completed", "response.done":
            guard let payload = event.payload else {
                throw SoaError.responsesRequestFailed(
                    status: status,
                    "response.completed event was missing a JSON payload"
                )
            }
            completedResponse = payload["response"]?.objectValue ?? payload.objectValue

        case "response.failed", "response.error", "error":
            throw SoaError.responsesRequestFailed(
                status: status,
                safeJSONErrorMessage(event.data)
            )

        default:
            return
        }
    }

    mutating func finalizedResponse(status: Int) throws -> JSONValue {
        guard var response = completedResponse else {
            throw SoaError.responsesRequestFailed(
                status: status,
                "chatgpt backend response did not contain a response.completed event"
            )
        }

        let mergedOutput = mergeChatGPTOutput(
            completedOutput: response["output"]?.arrayValue ?? [],
            outputItems: outputItems,
            fallbackOutputTexts: fallbackOutputTexts,
            synthesizedToolItems: synthesizedToolItems()
        )
        response["output"] = .array(mergedOutput)
        return .object(response)
    }

    private mutating func storeOutputItem(_ item: JSONValue, outputIndex: Int) throws {
        if item["type"]?.stringValue == "function_call" {
            try registerToolCallItem(item: item, outputIndex: outputIndex)
            outputItems[outputIndex] = finalizedToolItem(from: item)
            return
        }

        outputItems[outputIndex] = item
        if let existingContent = item["content"]?.arrayValue,
           !existingContent.isEmpty {
            let fallbackText = existingContent.enumerated().reduce(into: [Int: String]()) { partial, entry in
                let (index, content) = entry
                guard let text = content["text"]?.stringValue else { return }
                partial[index] = text
            }
            if !fallbackText.isEmpty {
                fallbackOutputTexts[outputIndex] = fallbackText
            }
        }
    }

    private mutating func registerToolCallItem(item: JSONValue, outputIndex: Int) throws {
        guard let callID = item["call_id"]?.stringValue,
              let name = item["name"]?.stringValue
        else {
            throw SoaError.responsesRequestFailed(
                "chatgpt backend emitted a malformed function_call item"
            )
        }

        if toolCallsByCallID[callID] == nil {
            toolCallOrder.append(callID)
            callOrderByOutputIndex[outputIndex, default: []].append(callID)
        }

        let itemID = item["id"]?.stringValue
        if let itemID {
            toolCallIDsByItemID[itemID] = callID
        }
        let argumentsJSON = item["arguments"]?.stringValue
            ?? itemID.flatMap { toolArgumentDeltasByItemID[$0] }
            ?? ""
        toolCallsByCallID[callID] = ChatGPTFunctionCallState(
            id: itemID,
            itemID: itemID,
            callID: callID,
            name: name,
            argumentsJSON: argumentsJSON,
            outputIndex: outputIndex
        )
    }

    private mutating func updateToolCall(from payload: JSONValue, itemID: String) throws {
        let callID = payload["call_id"]?.stringValue ?? toolCallIDsByItemID[itemID]
        let name = payload["name"]?.stringValue
        let argumentsJSON = payload["arguments"]?.stringValue
            ?? toolArgumentDeltasByItemID[itemID]
            ?? payload["delta"]?.stringValue
            ?? ""

        guard let callID else { return }

        var state = toolCallsByCallID[callID] ?? ChatGPTFunctionCallState(
            id: payload["id"]?.stringValue ?? itemID,
            itemID: itemID,
            callID: callID,
            name: name ?? "unknown",
            argumentsJSON: argumentsJSON,
            outputIndex: nil
        )

        state.id = payload["id"]?.stringValue ?? state.id
        state.itemID = itemID
        if let name { state.name = name }
        state.argumentsJSON = argumentsJSON
        toolCallsByCallID[callID] = state
        toolCallIDsByItemID[itemID] = callID
        if let outputIndex = state.outputIndex {
            outputItems[outputIndex] = state.itemJSON
        }
    }

    private func finalizedToolItem(from item: JSONValue) -> JSONValue {
        guard let callID = item["call_id"]?.stringValue,
              let state = toolCallsByCallID[callID]
        else {
            return item
        }
        var object = item.objectValue ?? [:]
        object["arguments"] = .string(state.argumentsJSON)
        if object["id"] == nil, let id = state.id ?? state.itemID {
            object["id"] = .string(id)
        }
        return .object(object)
    }

    private func synthesizedToolItems() -> [Int: [JSONValue]] {
        var grouped: [Int: [String: JSONValue]] = [:]
        for state in toolCallsByCallID.values {
            guard let outputIndex = state.outputIndex else { continue }
            grouped[outputIndex, default: [:]][state.callID] = state.itemJSON
        }

        var result: [Int: [JSONValue]] = [:]
        for (outputIndex, byCallID) in grouped {
            let order = callOrderByOutputIndex[outputIndex] ?? []
            let ordered = order.compactMap { byCallID[$0] }
            result[outputIndex] = ordered.isEmpty ? Array(byCallID.values) : ordered
        }
        return result
    }
}

private func parseChatGPTSSEEvents(_ text: String) -> [ChatGPTSSEEvent] {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    var events: [ChatGPTSSEEvent] = []
    var eventName: String?
    var dataLines: [String] = []

    func flush() {
        guard eventName != nil || !dataLines.isEmpty else { return }
        events.append(ChatGPTSSEEvent(name: eventName, dataLines: dataLines))
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
    }

    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.isEmpty {
            flush()
            continue
        }
        if line.hasPrefix(":") {
            continue
        }
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            continue
        }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst("data:".count)).trimmingPrefixSpace())
        }
    }
    flush()
    return events
}

private func mergeChatGPTOutput(
    completedOutput: [JSONValue],
    outputItems: [Int: JSONValue],
    fallbackOutputTexts: [Int: [Int: String]],
    synthesizedToolItems: [Int: [JSONValue]]
) -> [JSONValue] {
    let completedByIndex = Dictionary(uniqueKeysWithValues: completedOutput.enumerated().map { ($0.offset, $0.element) })
    let allIndexes = Set(completedByIndex.keys)
        .union(outputItems.keys)
        .union(fallbackOutputTexts.keys)
        .union(synthesizedToolItems.keys)

    guard !allIndexes.isEmpty else {
        return completedOutput
    }

    return allIndexes.sorted().compactMap { outputIndex in
        if let explicitItem = outputItems[outputIndex] {
            return explicitItem
        }

        if let toolItems = synthesizedToolItems[outputIndex], let firstToolItem = toolItems.first {
            return firstToolItem
        }

        if let completed = completedByIndex[outputIndex] {
            return mergeFallbackText(into: completed, fallbackContent: fallbackOutputTexts[outputIndex])
        }

        if let fallbackContent = fallbackOutputTexts[outputIndex] {
            return makeFallbackAssistantMessage(from: fallbackContent)
        }

        return nil
    }
}

private func mergeFallbackText(into item: JSONValue, fallbackContent: [Int: String]?) -> JSONValue {
    guard let fallbackContent, !fallbackContent.isEmpty else { return item }
    guard var object = item.objectValue else { return item }

    let existingContent = object["content"]?.arrayValue ?? []
    if !existingContent.isEmpty {
        return item
    }

    object["content"] = makeFallbackAssistantContent(from: fallbackContent)
    return .object(object)
}

private func makeFallbackAssistantMessage(from fallbackContent: [Int: String]) -> JSONValue {
    .object([
        "type": .string("message"),
        "role": .string("assistant"),
        "status": .string("completed"),
        "content": makeFallbackAssistantContent(from: fallbackContent),
    ])
}

private func makeFallbackAssistantContent(from fallbackContent: [Int: String]) -> JSONValue {
    .array(
        fallbackContent
            .sorted(by: { $0.key < $1.key })
            .map { _, text in
                .object([
                    "type": .string("output_text"),
                    "text": .string(text),
                ])
            }
    )
}

private extension String {
    func trimmingPrefixSpace() -> String {
        hasPrefix(" ") ? String(dropFirst()) : self
    }
}

func parseChatGPTSSEBody(_ data: Data, status: Int) throws -> JSONValue {
    var accumulator = ChatGPTSSEAccumulator()
    for event in parseChatGPTSSEEvents(String(decoding: data, as: UTF8.self)) {
        try accumulator.consume(event: event, status: status)
    }
    return try accumulator.finalizedResponse(status: status)
}
