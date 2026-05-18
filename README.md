# soaKit

Swift 6 package that exposes one Apple-native provider surface for iPhone/iPad and macOS.

## Supports

- OpenAI and ChatGPT transports
- `auth.json`, Keychain, injected API-key, and env-key auth paths
- typed request shaping and tool calls
- streaming Responses sends
- structured output helpers for `text.format` JSON schema / JSON object modes
- request diagnostics through response `request_id` metadata and optional org/project/client request headers
- ChatGPT preflight refresh on macOS
- browser OAuth re-login via SDK and CLI
- exclusive per-client sends with shared refresh coordination
- library and CLI use from the same package

## Library example

```swift
import soaKit

let client = try SoaClient(
    configuration: .init(
        preferredTransportKind: .chatGPTBackend
    )
)

let state = try await client.authState()
let models = try await client.listModels()
let response = try await client.createResponse(
    ResponsesRequest("Reply with exactly OK")
)
let stream = try await client.streamResponse(
    ResponsesRequest("Count from 1 to 3")
)

print(state.transportKind as Any)
print(models.count)
print(stream.meta.requestID as Any)
print(try response.body.prettyPrinted())
```

## CLI

```bash
swift build
.build/debug/soa --help

# ChatGPT transport (default)
.build/debug/soa auth status
.build/debug/soa auth refresh
.build/debug/soa send "Reply with exactly OK" --effort high
.build/debug/soa send "Count from 1 to 3" --stream --model gpt-5.5
.build/debug/soa models list

# Browser re-login writes auth.json and activates OpenAI API transport
.build/debug/soa relogin --no-browser --callback-port 0

# ChatGPT transport with an explicit issuer override for macOS refresh testing
.build/debug/soa --issuer https://auth.openai.com auth refresh

# Override the ChatGPT backend client_version query/header if Codex changes it
.build/debug/soa --client-version 0.130.0 models list

# OpenAI transport using env fallback
OPENAI_API_KEY=sk-proj-... .build/debug/soa --api-key send "Reply with exactly OK" --model gpt-5.5

# OpenAI transport using an injected key
.build/debug/soa --api-key-value sk-proj-... send "Reply with exactly OK" --model gpt-5.5

# Optional request diagnostics headers
.build/debug/soa --organization org_... --project proj_... --client-request-id "$(uuidgen)" \
  send "Reply with exactly OK" --model gpt-5.5
```

## Verify

```bash
swift test
```

`client_version` is required by the ChatGPT `/models` endpoint. By default soaKit resolves it from `CODEX_CLIENT_VERSION`, then macOS `~/.codex/version.json` `latest_version`, then the built-in fallback `0.130.0`.

## Docs

- `docs/README.md`: current package notes, boundaries, change policy, and verification commands
