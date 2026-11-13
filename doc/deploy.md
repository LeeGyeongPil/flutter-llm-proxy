# Deploying flutter_llm_proxy

The proxy is one process with no database. Keys come from environment
variables; the config file holds no secrets.

## 1. Check the config

```sh
dart run bin/flutter_llm_proxy.dart check-config proxy.yaml --strict
```

`--strict` exits 1 while any warning is left (missing allowlists, dev
tokens, `mode: off`, unset key variables).

## 2. Single executable

```sh
mkdir -p build
dart compile exe bin/flutter_llm_proxy.dart -o build/flutter-llm-proxy
OPENAI_API_KEY=... ./build/flutter-llm-proxy serve --config proxy.yaml
```

The executable contains everything (the mock samples too), so
`./build/flutter-llm-proxy demo` also works on a machine without the Dart SDK.

## 3. Docker

```sh
docker build -t flutter-llm-proxy .
docker run --rm -p 8080:8080 \
  -e OPENAI_API_KEY=... \
  -v "$PWD/proxy.yaml:/config/proxy.yaml:ro" \
  flutter-llm-proxy
```

The image runs `serve --config /config/proxy.yaml --host 0.0.0.0` and listens
on `$PORT` (default 8080).

## 4. Cloud Run (or any container platform)

- Put the provider keys in the platform's secret store and expose them as
  environment variables (`OPENAI_API_KEY`, ...). Do not bake them into the image.
- The platform sets `PORT`; the proxy follows it.
- Mount or bake in `proxy.yaml` (it has no secrets).
- Behind the platform's load balancer every request comes from the balancer's
  address. If you limit per IP, set `trust_forwarded_for: true` **only** when
  the platform overwrites `X-Forwarded-For`; otherwise clients can pick their
  own "IP".
- Limits are in memory per instance. With N instances a subject can use up to
  N times the configured limit. Keep the maximum instance count small, or wait
  for the shared-store milestone.

## 5. Reverse proxies and streaming

The proxy sends every SSE chunk as soon as it arrives
(`shelf.io.buffer_output: false`) and adds `Cache-Control: no-cache` and
`X-Accel-Buffering: no` to event streams. A reverse proxy in front can still
buffer. For nginx:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_buffering off;          # pass SSE chunks through immediately
    proxy_read_timeout 300s;      # long model answers
}
```

Check it end to end: the first `data:` line should appear long before the
answer is finished. `demo --only buffering` shows what buffering looks like.

## 6. Checklist

- [ ] `app_check.mode: firebase`, correct `project_number` (a number, not the ID)
- [ ] `allowed_app_ids` lists only your apps
- [ ] `allowed_models` set for every provider
- [ ] `requests_per_minute` and `tokens_per_day` set
- [ ] no `dev_tokens` (serve refuses them on a public host anyway)
- [ ] `cors.allow_origins` lists only your web origins
- [ ] keys in the platform's secret store, not in the image or the repo
