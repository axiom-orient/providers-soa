# Changelog

## [v0.2.0] - 2026-05-20

### Changed
- Public CLI uses explicit provider paths: `soa codex ...` and `soa gemini ...`.
- Codex CLI LLM calls use ChatGPT/Codex credentials from the resolved `auth.json`.
- Removed public API-key CLI guidance.
- Gemini support uses the package-local Gemini Core Adapter with pinned upstream dependency.

### Verified
- `swift build`
- `swift test`
- `cd gemini-core-adapter && npm install && npm run build && npm audit --omit=dev`
- Live Codex and Gemini credential smoke checks.
