import 'dart:async';
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;

import '../clock.dart';

/// Thrown when no key set could be loaded at all (first fetch failed).
class JwksUnavailableException implements Exception {
  JwksUnavailableException(this.detail);
  final String detail;
  @override
  String toString() => 'JwksUnavailableException: $detail';
}

/// Where public keys for token signatures come from.
abstract class JwksSource {
  /// The RSA public key for [kid], or null when the key set has no such key.
  Future<RSAPublicKey?> keyFor(String kid);
}

/// Turns a JWKS JSON document into kid -> RSA public key. Non-RSA keys are
/// skipped (App Check only signs with RS256).
Map<String, RSAPublicKey> parseJwks(Map<String, dynamic> jwks) {
  final out = <String, RSAPublicKey>{};
  final keys = jwks['keys'];
  if (keys is! List) return out;
  for (final k in keys) {
    if (k is! Map) continue;
    final jwk = Map<String, dynamic>.from(k);
    final kid = jwk['kid'];
    if (kid is! String || jwk['kty'] != 'RSA') continue;
    // 개인키 필드가 섞여 있어도 공개키 부분(n, e)만 쓴다.
    final key = JWTKey.fromJWK({'kty': 'RSA', 'n': jwk['n'], 'e': jwk['e']});
    if (key is RSAPublicKey) out[kid] = key;
  }
  return out;
}

/// A fixed key set (tests, `app_check.mode: local` with `jwks_file`).
class StaticJwksSource implements JwksSource {
  StaticJwksSource(Map<String, dynamic> jwks) : _keys = parseJwks(jwks);
  final Map<String, RSAPublicKey> _keys;

  @override
  Future<RSAPublicKey?> keyFor(String kid) async => _keys[kid];
}

/// Fetches a JWKS over HTTP and caches it.
///
/// - Cache lifetime: the smaller of the response's `Cache-Control: max-age`
///   and [maxAge] (Firebase docs: cache for at most 6 hours).
/// - Unknown kid (key rotation): refetch right away, but at most once per
///   [minRefetchInterval] so a stream of junk kids cannot hammer Google.
/// - Fetch failure: keep serving the old keys.
class HttpJwksSource implements JwksSource {
  HttpJwksSource(
    this.url, {
    this.maxAge = const Duration(hours: 6),
    this.minRefetchInterval = const Duration(seconds: 60),
    http.Client Function()? clientFactory,
    Clock? clock,
    this.timeout = const Duration(seconds: 10),
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _clock = clock ?? systemClock;

  final Uri url;
  final Duration maxAge;
  final Duration minRefetchInterval;
  final Duration timeout;
  final http.Client Function() _clientFactory;
  final Clock _clock;

  Map<String, RSAPublicKey> _keys = const {};
  DateTime? _expiresAt;
  DateTime? _lastAttempt;
  Future<void>? _inflight;

  /// How many HTTP fetches were made (tests check the refetch rules).
  int fetchCount = 0;

  @override
  Future<RSAPublicKey?> keyFor(String kid) async {
    // 다른 요청이 이미 받는 중이면 그 결과를 기다린다.
    final pending = _inflight;
    if (pending != null) await pending;
    final now = _clock();
    final stale = _expiresAt == null || !now.isBefore(_expiresAt!);
    // 캐시가 오래됐거나, 모르는 kid(키 교체일 수 있음)면 다시 받는다.
    // 단 마지막 시도 후 minRefetchInterval 안에는 다시 받지 않는다(실패·가짜 kid 폭주 방지).
    if ((stale || !_keys.containsKey(kid)) && _mayRefetch(now)) {
      await _refresh();
    }
    if (_expiresAt == null) {
      throw JwksUnavailableException('could not load $url');
    }
    return _keys[kid];
  }

  bool _mayRefetch(DateTime now) =>
      _lastAttempt == null ||
      now.difference(_lastAttempt!) >= minRefetchInterval;

  Future<void> _refresh() {
    // 동시에 여러 요청이 와도 조회는 한 번만 한다.
    return _inflight ??= _fetch().whenComplete(() => _inflight = null);
  }

  Future<void> _fetch() async {
    _lastAttempt = _clock();
    fetchCount++;
    final client = _clientFactory();
    try {
      final res = await client.get(url).timeout(timeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return;
      final keys = parseJwks(body);
      if (keys.isEmpty) return;
      _keys = keys;
      _expiresAt = _clock().add(_ttl(res.headers['cache-control']));
    } catch (_) {
      // 실패하면 기존 캐시를 그대로 쓴다(없으면 keyFor 가 JwksUnavailable 을 던진다).
    } finally {
      client.close();
    }
  }

  Duration _ttl(String? cacheControl) {
    final m = RegExp(r'max-age=(\d+)').firstMatch(cacheControl ?? '');
    if (m == null) return maxAge;
    final fromHeader = Duration(seconds: int.parse(m.group(1)!));
    return fromHeader < maxAge ? fromHeader : maxAge;
  }
}
