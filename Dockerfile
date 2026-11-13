# Multi-stage build: compile a native executable, ship it on a minimal image.
#   docker build -t flutter-llm-proxy .
#   docker run --rm -p 8080:8080 -e OPENAI_API_KEY=... \
#     -v "$PWD/proxy.yaml:/config/proxy.yaml:ro" flutter-llm-proxy
FROM dart:3.8 AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart pub get --offline \
 && mkdir -p build \
 && dart compile exe bin/flutter_llm_proxy.dart -o build/flutter-llm-proxy

# /runtime/ in the official dart image holds the minimal files an AOT
# executable needs, so the final image can start from scratch.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/build/flutter-llm-proxy /app/flutter-llm-proxy
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/flutter-llm-proxy"]
# Inside a container the proxy must listen on all interfaces.
CMD ["serve", "--config", "/config/proxy.yaml", "--host", "0.0.0.0"]
