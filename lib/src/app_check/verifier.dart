import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../clock.dart';
import 'jwks.dart';

/// Why a token was rejected. [code] is what clients see in the 401 body.
enum AppCheckFailure {
  missingToken('missing_token'),
  malformed('malformed'),
  algNotRs256('alg_not_rs256'),
  unknownKid('unknown_kid'),
  badSignature('bad_signature'),
  expired('expired'),
  badIss('bad_iss'),
  badAud('bad_aud'),
  appNotAllowed('app_not_allowed'),

  /// The key set could not be loaded (answered with 503, not 401).
  jwksUnavailable('jwks_unavailable');

  const AppCheckFailure(this.code);
  final String code;
}

class AppCheckException implements Exception {
  AppCheckException(this.reason);
  final AppCheckFailure reason;
  @override
  String toString() => 'AppCheckException: ${reason.code}';
}

/// The parts of a verified token the proxy uses.
class AppCheckClaims {
  const AppCheckClaims(
      {required this.appId, required this.audience, required this.expiresAt});

  /// `sub` — the Firebase app ID. Same for every install of one app.
  final String appId;
  final List<String> audience;
  final DateTime expiresAt;
}

/// Verifies Firebase App Check tokens with public keys only (no service
/// account), following https://firebase.google.com/docs/app-check/custom-resource-backend
///
/// Order of checks: header (alg pinned to RS256, typ, kid) -> key lookup ->
/// signature -> exp -> iss -> aud contains `projects/<number>` -> app ID.
class AppCheckVerifier {
  AppCheckVerifier({
    required this.projectNumber,
    this.projectId,
    Set<String>? allowedAppIds,
    required this.jwks,
    Clock? clock,
  })  : allowedAppIds = allowedAppIds ?? const {},
        _clock = clock ?? systemClock;

  final String projectNumber;
  final String? projectId;

  /// Empty = any app of this project.
  final Set<String> allowedAppIds;
  final JwksSource jwks;
  final Clock _clock;

  String get expectedIssuer =>
      'https://firebaseappcheck.googleapis.com/$projectNumber';

  Future<AppCheckClaims> verify(String? token) async {
    if (token == null || token.trim().isEmpty)
      throw AppCheckException(AppCheckFailure.missingToken);
    final parts = token.trim().split('.');
    if (parts.length != 3) throw AppCheckException(AppCheckFailure.malformed);

    final header = _decodeJson(parts[0]);
    final payload = _decodeJson(parts[1]);
    if (header == null || payload == null)
      throw AppCheckException(AppCheckFailure.malformed);

    // 1) 알고리즘 고정: 라이브러리는 헤더의 alg 로 검증 방식을 고르므로,
    //    HS256(공개키를 비밀키처럼 쓰는 위조)·none 을 라이브러리에 넘기기 전에 막는다.
    if (header['alg'] != 'RS256')
      throw AppCheckException(AppCheckFailure.algNotRs256);
    if (header['typ'] != 'JWT')
      throw AppCheckException(AppCheckFailure.malformed);
    final kid = header['kid'];
    if (kid is! String || kid.isEmpty)
      throw AppCheckException(AppCheckFailure.malformed);

    // 2) kid 로 공개키 찾기(모르면 JWKS 를 한 번 다시 받아 본다).
    RSAPublicKey? key;
    try {
      key = await jwks.keyFor(kid);
    } on JwksUnavailableException {
      throw AppCheckException(AppCheckFailure.jwksUnavailable);
    }
    if (key == null) throw AppCheckException(AppCheckFailure.unknownKid);

    // 3) 서명 — 시간 검사는 아래에서 우리 시계로 직접 한다.
    try {
      JWT.verify(token.trim(), key,
          checkExpiresIn: false, checkNotBefore: false);
    } on JWTException {
      throw AppCheckException(AppCheckFailure.badSignature);
    } catch (_) {
      throw AppCheckException(AppCheckFailure.badSignature);
    }

    // 4) 만료
    final exp = payload['exp'];
    if (exp is! num) throw AppCheckException(AppCheckFailure.malformed);
    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt(), isUtc: true);
    if (!_clock().isBefore(expiresAt))
      throw AppCheckException(AppCheckFailure.expired);

    // 5) 발급자
    if (payload['iss'] != expectedIssuer)
      throw AppCheckException(AppCheckFailure.badIss);

    // 6) aud 는 ["projects/<번호>", "projects/<ID>"] 목록 — "같은 목록"이 아니라 "포함" 검사.
    final audRaw = payload['aud'];
    final audience = audRaw is List
        ? [for (final a in audRaw) '$a']
        : (audRaw is String ? [audRaw] : <String>[]);
    if (!audience.contains('projects/$projectNumber'))
      throw AppCheckException(AppCheckFailure.badAud);

    // 7) 앱 ID(sub) — 같은 프로젝트의 다른 앱(예: 테스트 앱)을 막고 싶을 때.
    final sub = payload['sub'];
    if (sub is! String || sub.isEmpty)
      throw AppCheckException(AppCheckFailure.malformed);
    if (allowedAppIds.isNotEmpty && !allowedAppIds.contains(sub)) {
      throw AppCheckException(AppCheckFailure.appNotAllowed);
    }
    return AppCheckClaims(appId: sub, audience: audience, expiresAt: expiresAt);
  }

  static Map<String, dynamic>? _decodeJson(String part) {
    try {
      final v =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part))));
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}
