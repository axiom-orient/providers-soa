# soa docs

`soa` is the Swift provider package. It contains the `soaKit` SDK, `soaCLIKit`, and the `soa` SwiftPM executable for Apple platforms.

## Package Map

- `Package.swift`: SwiftPM package definition for `soaKit`, `soaCLIKit`, and `soa`.
- `Sources/soaKit/SoaClient.swift`: public actor and runtime state owner.
- `Sources/soaKit/SoaClient+Responses.swift`: model listing, Responses create/send, streaming, and transport routing.
- `Sources/soaKit/SoaClient+AuthRefresh.swift`: explicit refresh flow.
- `Sources/soaKit/SoaClient+BrowserRelogin.swift`: explicit browser relogin public API.
- `Sources/soaKit/Internal/*`: auth runtime, persistence, network, and ChatGPT SSE internals.
- `Sources/soaCLIKit/*`: CLI parser, application runner, and text rendering.
- `Sources/soaCLI/main.swift`: executable entrypoint.
- `Tests/`: SDK and CLI tests for auth, request shaping, refresh, SSE streaming, safety, structured output, parser, renderer, and public contract.

## Boundaries

- `SoaClient` is the public SDK center and owns runtime credential/send state.
- CLI code must call the SDK instead of duplicating auth or HTTP transport.
- `auth.json` rewrite must stay in internal persistence helpers.
- ChatGPT mutation `POST /responses` must not be automatically resent after a 401.
- Browser relogin is explicit behavior, not a hidden send side effect.
- Public DTO names and JSON fields require a deliberate compatibility decision before changing.

## Verification

```bash
swift build
swift test
.build/debug/soa --help
```

## GitHub Release

SwiftPM package URL:

```text
https://github.com/axiom-orient/providers-soa.git
```

Release from the split GitHub repository after the release tag exists:

```bash
swift build
swift test
.build/debug/soa --help
```

Live endpoint checks require local credentials and are intentionally manual. iOS/macOS Keychain behavior needs platform-specific smoke coverage when that storage path becomes a release target.
