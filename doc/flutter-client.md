# Calling the proxy from a Flutter app

The app never holds a provider key. It sends an App Check token, and the
proxy adds the real key on the server.

## 1. Turn on App Check

Follow the Firebase setup for `firebase_app_check` (Play Integrity on
Android, DeviceCheck / App Attest on Apple, reCAPTCHA on web), then activate
it at startup:

```dart
await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
await FirebaseAppCheck.instance.activate(/* providers for your platforms */);
```

## 2. Send the token with every call

Only two things change compared with calling the provider directly:
the base URL points to the proxy, and the `X-Firebase-AppCheck` header
replaces the API key.

```dart
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:http/http.dart' as http;

const proxyBase = 'https://your-proxy.example.com';

Stream<String> chat(http.Client client, String prompt) async* {
  final token = await FirebaseAppCheck.instance.getToken();
  final request = http.Request('POST', Uri.parse('$proxyBase/openai/v1/chat/completions'))
    ..headers['content-type'] = 'application/json'
    ..headers['X-Firebase-AppCheck'] = token ?? ''
    ..body = jsonEncode({
      'model': 'gpt-4o-mini', // must be in allowed_models
      'stream': true,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
    });

  final response = await client.send(request);
  if (response.statusCode != 200) {
    // {"error":{"type":"proxy_error","code":"...","reason":"..."}}
    throw Exception('proxy: ${response.statusCode} ${await response.stream.bytesToString()}');
  }
  final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data: ') || line == 'data: [DONE]') continue;
    final chunk = jsonDecode(line.substring(6)) as Map<String, dynamic>;
    final choices = chunk['choices'] as List;
    if (choices.isEmpty) continue; // last chunk: usage only
    final text = (choices.first['delta'] as Map)['content'];
    if (text is String) yield text;
  }
}
```

Anthropic and Gemini work the same way with their own paths:
`/anthropic/v1/messages` and
`/gemini/v1beta/models/<model>:streamGenerateContent?alt=sse`.

## 3. Handle proxy errors

| Status | `code` | What to do in the app |
|---|---|---|
| 401 | `app_check_failed` (`reason`: `missing_token`, `expired`, ...) | Get a fresh token and retry once |
| 429 | `rate_limited` (`reason`: `requests_per_minute`, `tokens_per_day`, ...) | Wait `Retry-After` seconds |
| 403 | `model_not_allowed` | Use a model listed in the proxy config |
| 404 | `path_not_allowed` / `unknown_route` | Check the path prefix |
| 405 | `method_not_allowed` (`Allow: POST`) | Call the path with `POST`; the proxy forwards only `POST` |
| 413 | `body_too_large` | Shorten the conversation |
| 503 | `app_check_unavailable` | The proxy could not load Google's keys; retry later |

Codes are fixed English strings so the app can match on them.

## 4. Flutter web

- Add your web origin (for example `https://my-app.web.app`) to
  `cors.allow_origins`. The proxy answers the browser's preflight and allows
  the `X-Firebase-AppCheck` header.
- If the answer arrives all at once only on web, check that the HTTP client
  you use streams responses in the browser, and that nothing in front of the
  proxy buffers (see `doc/deploy.md`).

## 5. Trying it before you have a Firebase project

```sh
dart run bin/flutter_llm_proxy.dart serve --config dev.yaml --mock
```

with a local-only config:

```yaml
providers:
  openai: {}
app_check:
  mode: local
  project_number: "123456789012"
  jwks_url: http://127.0.0.1:9/unused
  dev_tokens: ["my-local-dev-token"]
```

Then call it with `X-Firebase-AppCheck: my-local-dev-token`. Dev tokens are
refused on any non-loopback address, and check-config warns about them.

## 6. Checking with a real App Check token

Use the App Check debug provider in a debug build, print one token with
`getToken()`, and call the proxy with curl:

```sh
curl -N https://your-proxy.example.com/openai/v1/chat/completions \
  -H "X-Firebase-AppCheck: <token>" -H "content-type: application/json" \
  -d '{"model":"gpt-4o-mini","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

A 401 body names the failed check (`bad_aud` usually means the
`project_number` in the config is wrong).

## Limits to know

- App Check `sub` is the **app ID**, the same for every install of your app.
  Per-user limits need a per-user identity (planned: Firebase Auth ID tokens).
- Without the Admin SDK the proxy cannot mark a token as used, so a token can
  be replayed until it expires. Keep App Check token lifetimes short.
