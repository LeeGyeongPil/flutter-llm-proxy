// English messages. Every key here must also exist in messages_ko.dart
// (test/i18n_test.dart checks both tables have the same keys).

const Map<String, String> messagesEn = {
  // ---- help ----
  'help.global':
      '''flutter_llm_proxy {version} - keep LLM API keys off your Flutter / web app.
Pure Dart server, no Flutter SDK needed.

Usage: flutter_llm_proxy <command> [options]

Commands:
  serve          Run the proxy: App Check check, limits, unbuffered streaming
  demo           Show the whole flow offline with a practice mock (no API key)
  check-config   Validate a config file and summarize what it allows

Global options:
  --lang en|ko   Output language (else FLUTTER_LLM_PROXY_LANG, then LC_ALL / LC_MESSAGES / LANG)
  --version      Print the version
  -h, --help     Show this help

Run "flutter_llm_proxy <command> --help" for the options of one command.''',
  'help.serve': '''Usage: flutter_llm_proxy serve --config <file> [options]

Runs the proxy. Provider keys come from server environment variables
(names set in the config, e.g. OPENAI_API_KEY) and never reach the app.

Options:
  -c, --config <file>   YAML config (see example/proxy.yaml)
  --mock                Practice mock upstream: replies are recorded samples,
                        no key and no network needed
  --host <address>      Listen address (default 127.0.0.1; use 0.0.0.0 in a container)
  --port <number>       Listen port (default: PORT environment variable, else 8080)
  --lang en|ko          Output and log language

Dev tokens or "app_check.mode: off" are refused on a non-loopback host (exit 2).
Stop with Ctrl+C.''',
  'help.demo': '''Usage: flutter_llm_proxy demo [options]

Runs the real proxy in this process against a local JWKS (self-made RSA key)
and a practice mock upstream, then shows what an app would see.
No API key, no Firebase project, no network.

Options:
  --only all|security|limits|buffering   Run one part only (default all)
  --delay-ms <ms>                        Delay between mock stream events (default 250)
  --lang en|ko                           Output language

Exit code 0 when every outcome matched, 1 otherwise.''',
  'help.check-config':
      '''Usage: flutter_llm_proxy check-config <file> [--strict]

Validates the config and prints which providers, paths, models and limits it
opens. Key environment variables are shown as set / not set, never their values.

Options:
  --strict       Exit 1 when there are warnings
  --lang en|ko   Output language

Exit codes: 0 valid, 1 warnings with --strict, 2 invalid config (with line and key path).''',

  // ---- cli ----
  'cli.usage_error': 'Usage error: {detail}',
  'cli.see_help': 'Run "flutter_llm_proxy --help" for usage.',
  'cli.bad_lang': 'Unknown language "{value}". Use en or ko.',
  'cli.bad_delay': 'Invalid --delay-ms "{value}" (10 to 5000).',
  'cli.bad_port': 'Invalid port "{value}".',
  'cli.config_error':
      'Config error in {file}, line {line}, key {path}: {message}',
  'cli.check_needs_file':
      'check-config needs exactly one config file. Example: flutter_llm_proxy check-config example/proxy.yaml',
  'cli.serve_needs_config':
      'serve needs --config <file>. Example: flutter_llm_proxy serve --config example/proxy.yaml --mock',

  'cli.config_not_found':
      'Config file not found: {path} (copy example/proxy.yaml to start)',

  // ---- config errors ----
  'config.file_not_found': 'file not found: {path}',
  'config.yaml_syntax': 'YAML syntax error: {detail}',
  'config.expected_map': 'expected a mapping (key: value)',
  'config.unknown_key': 'unknown key "{key}" (allowed: {allowed})',
  'config.expected_string': 'expected a text value',
  'config.expected_bool': 'expected true or false',
  'config.expected_int': 'expected a whole number',
  'config.negative': 'must not be negative (got {value})',
  'config.expected_list': 'expected a list',
  'config.missing': 'required setting is missing',
  'config.no_providers': 'at least one provider is required',
  'config.duplicate_prefix': 'prefix {prefix} is used by two providers',
  'config.bad_choice': '"{value}" is not one of: {choices}',
  'config.bad_prefix':
      'prefix must start with "/" and not end with "/" (got "{value}")',
  'config.bad_url': 'not an http(s) URL: {value}',
  'config.bad_path': 'allowed path must start with "/" (got "{value}")',
  'config.bad_project_number':
      'project_number must be digits (the Firebase project NUMBER, not the ID): {value}',
  'config.local_needs_jwks': 'mode local needs jwks_file or jwks_url',

  // ---- config warnings ----
  'warn.app_check_off':
      'app_check.mode is off: anyone who can reach the proxy can spend your key. Local development only.',
  'warn.dev_tokens':
      '{count} dev token(s) configured: fixed strings that bypass App Check. Local development only.',
  'warn.no_allowed_app_ids':
      'allowed_app_ids is empty: every app in the Firebase project is accepted.',
  'warn.any_model':
      'provider {provider}: allowed_models is empty, so clients may pick any (expensive) model.',
  'warn.no_request_limit':
      'limits.requests_per_minute is not set: no per-subject request limit.',
  'warn.cors_any':
      'cors.allow_origins contains "*": any website may call the proxy from a browser.',
  'warn.trust_forwarded_for':
      'trust_forwarded_for is on: only safe behind a reverse proxy that overwrites X-Forwarded-For.',
  'warn.key_not_set':
      'provider {provider}: environment variable {env} is not set (serve refuses to start without it unless --mock).',

  // ---- check-config ----
  'cc.header': 'Config: {file}',
  'cc.app_check':
      'App Check: mode {mode}, project number {number} (id {id}), allowed apps: {apps}',
  'cc.jwks': '  JWKS: {source}',
  'cc.providers': 'Providers:',
  'cc.provider':
      '  {id} ({type})  {prefix}/... -> {upstream}  key: {env} via {header} [{state}]',
  'cc.key_set': 'set',
  'cc.key_not_set': 'not set',
  'cc.paths': '    paths:  {paths}',
  'cc.models': '    models: {models}',
  'cc.include_usage': '    inject stream_options.include_usage: {value}',
  'cc.limits':
      'Limits: subject {subject}, {rpm} requests/min, {tpd} tokens/day per subject, {global} tokens/day total',
  'cc.cors': 'CORS origins: {origins}',
  'cc.misc': 'Max request body: {bytes} bytes, trust X-Forwarded-For: {xff}',
  'cc.any': 'any',
  'cc.none': 'none',
  'cc.on': 'on',
  'cc.off': 'off',
  'cc.unlimited': 'unlimited',
  'cc.no_warnings': 'Warnings: none',
  'cc.warnings': 'Warnings ({count}):',
  'cc.strict_fail': '--strict: {count} warning(s), exit code 1.',
  'cc.ok': 'Config is valid.',

  // ---- serve ----
  'serve.refuse_public':
      'Refusing to listen on {host}: dev tokens or app_check.mode off would let anyone use your key. Use 127.0.0.1, or remove them.',
  'serve.missing_keys':
      'Missing server key environment variable(s): {envs}. Set them, or try --mock first.',
  'serve.bind_failed': 'Could not listen on {host}:{port}: {detail}',
  'serve.mock_banner':
      'MOCK MODE (practice): upstream replies are recorded samples, not a real model. No key leaves this machine.',
  'serve.warning': 'warning: {text}',
  'serve.listening':
      'flutter_llm_proxy {version} listening on {url} (Ctrl+C to stop)',
  'serve.route': '  {prefix}/... -> {upstream}',
  'serve.stopping': 'Stopping.',

  // ---- request log ----
  'log.request':
      '{time} {method} {path} {status} subject={subject} tokens={tokens} {ms}ms{notes}',
  'log.usage_missing': '(usage missing)',
  'log.client_disconnected': '(client disconnected)',

  // ---- demo ----
  'demo.banner':
      'flutter_llm_proxy demo - PRACTICE MOCK MODE: the upstream is a local mock replaying recorded samples, not a real model.\nNo API key, no Firebase project, no network. The proxy code itself is the real one.',
  'demo.setup':
      'Setup: local JWKS {jwks} (self-made RSA-2048 key "{kid}"), mock upstream {mock}',
  'demo.section_security': '[1/3] App Check - only your app may use the proxy',
  'demo.section_limits': '[2/3] Limits - 3 requests per minute per app+IP',
  'demo.section_buffering':
      '[3/3] Streaming - shelf buffering off vs on (mock events {delay} ms apart)',
  'demo.row': '  {mark}  {scenario}  expected {expected}, got {got}',
  'demo.mark_ok': 'ok  ',
  'demo.mark_fail': 'FAIL',
  'demo.s_valid': 'valid token (aud is a 2-item list), stream',
  'demo.got_stream': '{status} stream ({events} events)',
  'demo.s_missing': 'no token',
  'demo.s_bad_aud': 'aud without this project number',
  'demo.s_hs256': 'HS256 forged with the public key',
  'demo.s_expired': 'expired token',
  'demo.s_tampered': 'payload swapped (signature mismatch)',
  'demo.lib_accepted': 'accepted',
  'demo.lib_rejected': 'rejected',
  'demo.aud_note':
      '  note: the same valid token under a library "aud equals" check: {result}. App Check aud is a list, so the proxy checks "contains".',
  'demo.upstream_key': '  upstream saw server key: {value}',
  'demo.upstream_appcheck': '  upstream saw the App Check token: {value}',
  'demo.client_key': 'client saw key: {value}',
  'demo.s_request': 'request {n}',
  'demo.limits_note':
      '  Limits are counted in memory per server instance; rejected tokens never reach this step.',
  'demo.s_buffer_off': 'buffer_output=false (this proxy)',
  'demo.s_buffer_on': 'shelf default (buffer_output=true)',
  'demo.expect_early': 'first chunk before 50% of total',
  'demo.expect_late': 'first chunk at 50%+ of total',
  'demo.got_timing': 'first chunk {first} ms / total {total} ms',
  'demo.buffer_note':
      '  With the default, the app sees nothing until the whole answer is done - streaming silently stops working.',
  'demo.yes': 'yes',
  'demo.no': 'no',
  'demo.log_header':
      'Proxy log (one line per request; keys and tokens are never printed):',
  'demo.summary_ok': 'All {n} checks matched (practice mock). Exit code 0.',
  'demo.summary_fail': '{n} of {total} checks did not match. Exit code 1.',
};
