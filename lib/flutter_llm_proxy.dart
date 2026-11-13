/// Keep LLM API keys off Flutter and web clients: a shelf proxy with
/// Firebase App Check verification, per-subject limits and unbuffered SSE
/// pass-through with usage counting.
///
/// Use [ProxyApp] for the whole pipeline, or pick the pieces
/// ([appCheckMiddleware], [rateLimitMiddleware], [llmProxyHandler]) for an
/// existing shelf server. Test helpers live in `package:flutter_llm_proxy/testing.dart`.
library;

export 'src/app_check/jwks.dart'
    show
        JwksSource,
        HttpJwksSource,
        StaticJwksSource,
        JwksUnavailableException,
        parseJwks;
export 'src/app_check/verifier.dart'
    show AppCheckVerifier, AppCheckClaims, AppCheckException, AppCheckFailure;
export 'src/clock.dart' show Clock, systemClock;
export 'src/config.dart';
export 'src/log.dart' show RequestLogger, RequestStats;
export 'src/middleware/app_check_middleware.dart'
    show appCheckMiddleware, appCheckHeader;
export 'src/middleware/cors.dart' show corsMiddleware;
export 'src/middleware/rate_limit.dart'
    show RateLimiter, LimitDecision, LimitKind, rateLimitMiddleware, subjectFor;
export 'src/mock/mock_upstream.dart' show MockUpstream, MockRequestRecord;
export 'src/proxy/errors.dart'
    show appCheckContextKey, subjectContextKey, statsContextKey, proxyError;
export 'src/proxy/forwarder.dart' show UpstreamClientFactory, UsageSink;
export 'src/proxy/router.dart'
    show llmProxyHandler, pathAllowed, serverKeysFromEnvironment;
export 'src/server.dart' show ProxyApp, jwksSourceFor, isLoopbackHost;
export 'src/usage/usage_tap.dart' show Usage, UsageResult, UsageTap;
export 'src/version.dart' show packageVersion;
