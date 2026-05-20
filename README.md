# soa

Swift 6 package and CLI for explicit provider paths.

## Supports

- `soa codex ...` using Codex/ChatGPT auth cache and Responses transports
- `soa gemini ...` using a local Gemini Core Adapter process
- file-backed `auth.json` from explicit `authPath`, explicit `authHome`, `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`
- Codex CLI auth through the resolved `auth.json` credential
- typed request shaping, tool calls, streaming Responses sends, and structured output helpers
- request diagnostics through response `request_id` metadata and optional org/project/client request headers
- ChatGPT preflight refresh for file-backed credentials
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

let gemini = GeminiClient()
let generated = try gemini.generate(.init("Reply with exactly OK", model: "flash"))
print(generated.text)
```

## CLI

```bash
swift build
cd gemini-core-adapter
npm install
npm run build
cd ..

.build/debug/soa --help

# Codex/ChatGPT transport (default)
.build/debug/soa codex auth status
.build/debug/soa codex models list
.build/debug/soa codex send "Reply with exactly OK" --effort high
.build/debug/soa codex send "Count from 1 to 3" --stream --model gpt-5.5
printf 'Reply with exactly OK\n' | .build/debug/soa codex send --stdin --model gpt-5.5

# Browser re-login refreshes or writes auth.json for later resolved auth use
.build/debug/soa codex relogin --no-browser --callback-port 0

# ChatGPT transport with an explicit issuer override for macOS refresh testing
.build/debug/soa codex --issuer https://auth.openai.com relogin --no-browser

# Override the ChatGPT backend client_version query/header if Codex changes it
.build/debug/soa codex --client-version 0.130.0 models list

# Gemini through the local adapter
.build/debug/soa gemini models
.build/debug/soa gemini generate "Reply with exactly OK" --model flash

# Optional request diagnostics headers
.build/debug/soa codex --organization org_... --project proj_... --client-request-id "$(uuidgen)" \
  send "Reply with exactly OK" --model gpt-5.5
```

## Verify

```bash
swift build
swift test
cd gemini-core-adapter && npm install && npm run build && npm audit --omit=dev && cd ..
.build/debug/soa --help
```

This is the local release gate for the package. GitHub CI is not required for this gate. Live Codex and Gemini endpoint checks require local credentials and should be run manually before publishing when the release changes provider behavior.

`client_version` is required by the ChatGPT `/models` endpoint. By default soaKit resolves it from `CODEX_CLIENT_VERSION`, then macOS `~/.codex/version.json` `latest_version`, then the built-in fallback `0.130.0`.

Gemini commands require this package's `gemini-core-adapter/dist/main.js`. Build it with `npm install && npm run build` inside `gemini-core-adapter`.

## Docs

- `docs/README.md`: current package notes, boundaries, change policy, and verification commands
