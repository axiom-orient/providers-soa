# soa docs

`soa` is the Swift provider package. It contains the `soaKit` SDK, `soaCLIKit`, and the `soa` SwiftPM executable for explicit Codex and Gemini provider paths.

## Package Map

- `Package.swift`: SwiftPM package definition for `soaKit`, `soaCLIKit`, and `soa`.
- `Sources/soaKit/SoaClient.swift`: public actor and runtime state owner.
- `Sources/soaKit/SoaClient+Responses.swift`: model listing, Responses create/send, streaming, and transport routing.
- `Sources/soaKit/SoaClient+AuthRefresh.swift`: explicit refresh flow.
- `Sources/soaKit/SoaClient+BrowserRelogin.swift`: explicit browser relogin public API.
- `Sources/soaKit/Gemini.swift`: Gemini Core Adapter process client and DTOs.
- `gemini-core-adapter/`: TypeScript JSON-RPC adapter around upstream `@google/gemini-cli-core`.
- `Sources/soaKit/Internal/*`: auth runtime, persistence, network, and ChatGPT SSE internals.
- `Sources/soaCLIKit/*`: CLI parser, application runner, and text rendering.
- `Sources/soaCLI/main.swift`: executable entrypoint.
- `Tests/`: SDK and CLI tests for auth, request shaping, refresh, SSE streaming, safety, structured output, parser, renderer, and public contract.

## Boundaries

- `SoaClient` is the Codex SDK center and owns runtime credential/send state.
- `GeminiClient` is a separate process-backed SDK path and does not share Codex auth or transport code.
- CLI code must call the SDK instead of duplicating auth or HTTP transport.
- `auth.json` rewrite must stay in internal persistence helpers.
- Auth resolution is file-backed only: explicit `authPath`, explicit `authHome`, `$CODEX_HOME/auth.json`, then `~/.codex/auth.json`.
- Codex CLI LLM calls use ChatGPT/Codex credentials from the resolved `auth.json`.
- Gemini uses the package-local adapter and Google login handled by `@google/gemini-cli-core`; it does not use Codex `auth.json`.
- ChatGPT mutation `POST /responses` must not be automatically resent after a 401.
- Browser relogin is explicit behavior, not a hidden send side effect.
- Public DTO names and JSON fields require a deliberate compatibility decision before changing.

## Release Readiness

Release slice: this SwiftPM package, the `soa` CLI, `soaKit`, `soaCLIKit`, and the package-local `gemini-core-adapter`.

Rollout gate:

```bash
swift build
swift test
cd gemini-core-adapter && npm install && npm run build && npm audit --omit=dev && cd ..
.build/debug/soa --help
```

GitHub CI is not used for this package gate. Live endpoint checks are manual because they require local Codex and Gemini credentials. Gemini live checks use the package-local built `gemini-core-adapter/dist/main.js`.

Rollback path: before publication, restore the previous source/docs package state. After publication, move consumers back to the previous package tag or commit. This release slice introduces no schema migration, remote state migration, or generated credential migration.

## GitHub Release

SwiftPM package URL:

```text
https://github.com/axiom-orient/providers-soa.git
```

Release from the split GitHub repository after the release tag exists:

Run the Release Readiness gate above before publishing the tag.
