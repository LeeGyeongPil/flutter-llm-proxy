/// Test helpers: mint App Check-shaped tokens with your own RSA key so you
/// can test a proxy (or any App Check backend) without Firebase or network.
///
/// Never use these keys or tokens in production.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/export.dart' as pc;

import 'src/clock.dart';

export 'src/mock/mock_upstream.dart' show MockUpstream, MockRequestRecord;

/// Issues tokens shaped like Firebase App Check tokens:
/// header `{alg: RS256, typ: JWT, kid}`, claims `iss`, `aud` (2-element list),
/// `sub` (app ID), `iat`, `exp`.
class AppCheckTestIssuer {
  AppCheckTestIssuer({
    this.projectNumber = '123456789012',
    this.projectId = 'demo-project',
    this.appId = '1:123456789012:android:0a1b2c3d4e5f',
    this.kid = 'test-key-1',
    Clock? clock,
  }) : _clock = clock ?? systemClock {
    final pair = _generateRsa2048();
    _private = RSAPrivateKey.raw(pair.privateKey);
    _public = RSAPublicKey.raw(pair.publicKey);
  }

  final String projectNumber;
  final String projectId;
  final String appId;
  final String kid;
  final Clock _clock;
  late final RSAPrivateKey _private;
  late final RSAPublicKey _public;

  String get issuer => 'https://firebaseappcheck.googleapis.com/$projectNumber';

  /// The JWKS document a verifier would download (public key only).
  Map<String, dynamic> jwks() => {
        'keys': [publicJwk()],
      };

  Map<String, dynamic> publicJwk() {
    final jwk = _public.toJWK(keyID: kid);
    jwk['alg'] = 'RS256';
    jwk['use'] = 'sig';
    return jwk;
  }

  /// A valid token unless you override a field to make it invalid.
  String token({
    String? appId,
    List<String>? audience,
    String? issuer,
    Duration expiresIn = const Duration(hours: 1),
    String? kid,
  }) {
    final now = _clock();
    final claims = <String, dynamic>{
      'sub': appId ?? this.appId,
      'aud': audience ?? ['projects/$projectNumber', 'projects/$projectId'],
      'iss': issuer ?? this.issuer,
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(expiresIn).millisecondsSinceEpoch ~/ 1000,
    };
    final jwt = JWT(claims, header: {'kid': kid ?? this.kid, 'typ': 'JWT'});
    // iat·exp 는 위에서 우리 시계로 넣었으니 라이브러리가 덮어쓰지 않게 한다.
    return jwt.sign(_private, algorithm: JWTAlgorithm.RS256, noIssueAt: true);
  }

  /// The classic "algorithm confusion" forgery: an HS256 token whose HMAC
  /// secret is the public key modulus everyone can download.
  String forgeHs256() {
    final now = _clock();
    final claims = {
      'sub': appId,
      'aud': ['projects/$projectNumber', 'projects/$projectId'],
      'iss': issuer,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    };
    return JWT(claims, header: {'kid': kid, 'typ': 'JWT'}).sign(
        SecretKey(publicJwk()['n'] as String),
        algorithm: JWTAlgorithm.HS256,
        noIssueAt: true);
  }

  /// An unsigned token with `alg: none`.
  String algNone() {
    String b64(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final exp =
        _clock().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    return '${b64({'alg': 'none', 'typ': 'JWT', 'kid': kid})}.'
        '${b64({
          'sub': appId,
          'aud': ['projects/$projectNumber'],
          'iss': issuer,
          'exp': exp
        })}.';
  }

  /// Header and signature of a valid token, payload swapped for another
  /// app ID — the signature no longer matches.
  String tampered() {
    final a = token().split('.');
    final b = token(appId: '1:$projectNumber:android:attacker').split('.');
    return '${a[0]}.${b[1]}.${a[2]}';
  }
}

pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _generateRsa2048() {
  final seed = Random.secure();
  final rnd = pc.FortunaRandom()
    ..seed(pc.KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
  final gen = pc.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
  return gen.generateKeyPair();
}
