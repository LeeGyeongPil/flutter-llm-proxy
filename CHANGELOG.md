# Changelog

## 0.1.0

First release.

- `serve`: key-hiding proxy for OpenAI, Anthropic and Gemini from one YAML file.
- Firebase App Check verification with the public JWKS (no service account):
  RS256 pinned before the JWT library runs, `aud` list "contains" check,
  `iss`, `exp`, optional app ID allowlist, JWKS cache (max 6 h) with
  rate-limited refetch on unknown `kid`.
- Unbuffered SSE pass-through (`shelf.io.buffer_output: false`,
  `X-Accel-Buffering: no`), bytes unchanged; client disconnect cancels the
  upstream request.
- Usage counting from OpenAI (final usage chunk, `include_usage` injected),
  Anthropic (cumulative `message_delta`) and Gemini (`usageMetadata`).
- Limits: requests per minute and tokens per day per subject (`app`, `ip`,
  `app+ip`), global tokens per day, `429` with `Retry-After`.
- CORS for Flutter web, `/healthz`, request log with secrets redacted.
- `demo` and `serve --mock`: practice mock upstream, no key or network needed.
- `check-config` with line numbers and key paths for errors.
- English and Korean CLI output (`--lang en|ko`, `FLUTTER_LLM_PROXY_LANG`).
- Library API: `ProxyApp`, `appCheckMiddleware`, `rateLimitMiddleware`,
  `llmProxyHandler`, `UsageTap`; test helpers in `testing.dart`.

### Known issues

- `dart analyze` reports info-level `curly_braces_in_flow_control_structures` lints.
- Closing the output pipe early (for example `| head`) prints a broken-pipe stack trace.
