import 'dart:io';

import 'package:yaml/yaml.dart';

import 'i18n/messages.dart';

/// How the server-side key is attached to the upstream request.
enum KeyHeaderStyle {
  /// `Authorization: Bearer <key>` (OpenAI and OpenAI-compatible APIs).
  bearer('bearer'),

  /// `x-api-key: <key>` (Anthropic).
  xApiKey('x-api-key'),

  /// `x-goog-api-key: <key>` (Gemini).
  xGoogApiKey('x-goog-api-key');

  const KeyHeaderStyle(this.yamlName);
  final String yamlName;
}

/// Which wire format the provider speaks (decides how usage is parsed
/// and where the model name lives).
enum ProviderType { openai, anthropic, gemini }

/// `firebase`: verify real App Check tokens against Google's JWKS.
/// `local`: verify against a JWKS file or URL you control (tests, demos).
/// `off`: no client attestation at all (only for local development).
enum AppCheckMode { firebase, local, off }

/// What a rate limit is counted per.
enum SubjectKey {
  /// App Check app ID (`sub`). Every install of the same app shares it.
  app('app'),

  /// Client IP address.
  ip('ip'),

  /// App ID and IP together (default).
  appAndIp('app+ip');

  const SubjectKey(this.yamlName);
  final String yamlName;
}

/// Thrown when the YAML config is invalid. [line] is 1-based (0 if unknown),
/// [keyPath] is a dotted path such as `providers.openai.key_header`.
class ConfigException implements Exception {
  ConfigException(this.messageKey, this.args,
      {this.line = 0, this.keyPath = '', this.sourceName = ''});

  final String messageKey;
  final Map<String, Object?> args;
  final int line;
  final String keyPath;
  final String sourceName;

  /// English message (the CLI shows a translated one via [messageKey]).
  String get message => Messages(Lang.en).t(messageKey, args);

  @override
  String toString() => 'ConfigException: $sourceName:$line $keyPath: $message';
}

/// A non-fatal finding shown by `check-config` (and fatal with `--strict`).
class ConfigWarning {
  const ConfigWarning(this.messageKey, [this.args = const {}]);
  final String messageKey;
  final Map<String, Object?> args;
}

class ProviderConfig {
  ProviderConfig({
    required this.id,
    required this.type,
    required this.prefix,
    required this.upstream,
    required this.keyEnv,
    required this.keyHeader,
    required this.allowedPaths,
    this.allowedModels = const [],
    this.injectIncludeUsage = true,
  });

  /// Defaults for the three supported providers, so a config can be short.
  factory ProviderConfig.defaults(ProviderType type, {String? id}) {
    switch (type) {
      case ProviderType.openai:
        return ProviderConfig(
          id: id ?? 'openai',
          type: type,
          prefix: '/openai',
          upstream: Uri.parse('https://api.openai.com'),
          keyEnv: 'OPENAI_API_KEY',
          keyHeader: KeyHeaderStyle.bearer,
          allowedPaths: const ['/v1/chat/completions'],
        );
      case ProviderType.anthropic:
        return ProviderConfig(
          id: id ?? 'anthropic',
          type: type,
          prefix: '/anthropic',
          upstream: Uri.parse('https://api.anthropic.com'),
          keyEnv: 'ANTHROPIC_API_KEY',
          keyHeader: KeyHeaderStyle.xApiKey,
          allowedPaths: const ['/v1/messages'],
        );
      case ProviderType.gemini:
        return ProviderConfig(
          id: id ?? 'gemini',
          type: type,
          prefix: '/gemini',
          upstream: Uri.parse('https://generativelanguage.googleapis.com'),
          keyEnv: 'GEMINI_API_KEY',
          keyHeader: KeyHeaderStyle.xGoogApiKey,
          allowedPaths: const [
            '/v1beta/models/*:streamGenerateContent',
            '/v1beta/models/*:generateContent',
          ],
        );
    }
  }

  final String id;
  final ProviderType type;

  /// Public path prefix on the proxy, e.g. `/openai`.
  final String prefix;

  /// Upstream base URL, e.g. `https://api.openai.com`.
  final Uri upstream;

  /// Name of the server environment variable that holds the key.
  final String keyEnv;
  final KeyHeaderStyle keyHeader;

  /// Upstream paths clients may call. `*` matches within one path segment.
  final List<String> allowedPaths;

  /// Models clients may use. Empty = any model (check-config warns).
  final List<String> allowedModels;

  /// OpenAI only: add `stream_options.include_usage=true` to streaming
  /// requests so the final chunk carries token usage.
  final bool injectIncludeUsage;

  ProviderConfig copyWith({Uri? upstream}) => ProviderConfig(
        id: id,
        type: type,
        prefix: prefix,
        upstream: upstream ?? this.upstream,
        keyEnv: keyEnv,
        keyHeader: keyHeader,
        allowedPaths: allowedPaths,
        allowedModels: allowedModels,
        injectIncludeUsage: injectIncludeUsage,
      );
}

class AppCheckConfig {
  AppCheckConfig({
    this.mode = AppCheckMode.firebase,
    this.projectNumber = '',
    this.projectId,
    this.allowedAppIds = const {},
    Uri? jwksUrl,
    this.jwksFile,
    this.devTokens = const [],
  }) : jwksUrl = jwksUrl ?? Uri.parse(defaultJwksUrl);

  static const defaultJwksUrl =
      'https://firebaseappcheck.googleapis.com/v1/jwks';

  final AppCheckMode mode;
  final String projectNumber;
  final String? projectId;
  final Set<String> allowedAppIds;
  final Uri jwksUrl;
  final String? jwksFile;

  /// Static tokens accepted instead of App Check (local development only —
  /// `serve` refuses them on a non-loopback host).
  final List<String> devTokens;
}

class LimitsConfig {
  const LimitsConfig({
    this.subject = SubjectKey.appAndIp,
    this.requestsPerMinute,
    this.tokensPerDay,
    this.globalTokensPerDay,
  });

  final SubjectKey subject;
  final int? requestsPerMinute;
  final int? tokensPerDay;
  final int? globalTokensPerDay;
}

class ProxyConfig {
  ProxyConfig({
    required this.providers,
    required this.appCheck,
    this.limits = const LimitsConfig(),
    this.corsAllowOrigins = const [],
    this.maxBodyBytes = 1024 * 1024,
    this.trustForwardedFor = false,
    this.sourceName = '<memory>',
  });

  final List<ProviderConfig> providers;
  final AppCheckConfig appCheck;
  final LimitsConfig limits;
  final List<String> corsAllowOrigins;
  final int maxBodyBytes;

  /// Use the first `X-Forwarded-For` address as the client IP. Only turn on
  /// behind a reverse proxy you control (Cloud Run, nginx), or clients can
  /// pick their own IP.
  final bool trustForwardedFor;
  final String sourceName;

  /// Reads and validates a YAML file.
  static ProxyConfig load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException('config.file_not_found', {'path': path},
          sourceName: path);
    }
    return parse(file.readAsStringSync(), sourceName: path);
  }

  /// Parses and validates YAML text.
  static ProxyConfig parse(String yaml, {String? sourceName}) {
    final name = sourceName ?? '<string>';
    YamlNode root;
    try {
      root = loadYamlNode(yaml, sourceUrl: Uri.file(name));
    } on YamlException catch (e) {
      throw ConfigException('config.yaml_syntax', {'detail': e.message},
          line: (e.span?.start.line ?? -1) + 1, sourceName: name);
    }
    return _Parser(name).parseRoot(root);
  }

  /// Non-fatal findings (security-relevant defaults, missing allowlists).
  List<ConfigWarning> warnings() {
    final w = <ConfigWarning>[];
    if (appCheck.mode == AppCheckMode.off) {
      w.add(const ConfigWarning('warn.app_check_off'));
    }
    if (appCheck.devTokens.isNotEmpty) {
      w.add(ConfigWarning(
          'warn.dev_tokens', {'count': appCheck.devTokens.length}));
    }
    if (appCheck.mode != AppCheckMode.off && appCheck.allowedAppIds.isEmpty) {
      w.add(const ConfigWarning('warn.no_allowed_app_ids'));
    }
    for (final p in providers) {
      if (p.allowedModels.isEmpty) {
        w.add(ConfigWarning('warn.any_model', {'provider': p.id}));
      }
    }
    if (limits.requestsPerMinute == null) {
      w.add(const ConfigWarning('warn.no_request_limit'));
    }
    if (corsAllowOrigins.contains('*')) {
      w.add(const ConfigWarning('warn.cors_any'));
    }
    if (trustForwardedFor) {
      w.add(const ConfigWarning('warn.trust_forwarded_for'));
    }
    return w;
  }
}

/// Walks the YAML tree, remembering key paths and line numbers for errors.
class _Parser {
  _Parser(this.sourceName);
  final String sourceName;

  Never _fail(
      String key, Map<String, Object?> args, YamlNode? node, String path) {
    final line = node == null ? 0 : node.span.start.line + 1;
    throw ConfigException(key, args,
        line: line, keyPath: path, sourceName: sourceName);
  }

  YamlMap _map(YamlNode node, String path) {
    if (node is YamlMap) return node;
    if (node is YamlScalar && node.value == null) return YamlMap();
    _fail('config.expected_map', {}, node, path);
  }

  void _onlyKeys(YamlMap map, Set<String> allowed, String path) {
    for (final k in map.nodes.keys) {
      final key = (k as YamlNode).value.toString();
      if (!allowed.contains(key)) {
        _fail(
            'config.unknown_key',
            {'key': key, 'allowed': (allowed.toList()..sort()).join(', ')},
            k,
            path.isEmpty ? key : '$path.$key');
      }
    }
  }

  YamlNode? _node(YamlMap map, String key) => map.nodes[key];

  String? _string(YamlMap map, String key, String path) {
    final n = _node(map, key);
    if (n == null || (n is YamlScalar && n.value == null)) return null;
    if (n is! YamlScalar || n.value is Map || n.value is List) {
      _fail('config.expected_string', {}, n, '$path.$key');
    }
    return n.value.toString();
  }

  bool? _bool(YamlMap map, String key, String path) {
    final n = _node(map, key);
    if (n == null) return null;
    if (n is YamlScalar && n.value is bool) return n.value as bool;
    _fail('config.expected_bool', {}, n, '$path.$key');
  }

  int? _nonNegativeInt(YamlMap map, String key, String path) {
    final n = _node(map, key);
    if (n == null || (n is YamlScalar && n.value == null)) return null;
    final full = path.isEmpty ? key : '$path.$key';
    if (n is! YamlScalar || n.value is! int) {
      _fail('config.expected_int', {}, n, full);
    }
    final v = n.value as int;
    if (v < 0) _fail('config.negative', {'value': v}, n, full);
    return v;
  }

  List<String> _stringList(YamlMap map, String key, String path) {
    final n = _node(map, key);
    if (n == null || (n is YamlScalar && n.value == null)) return const [];
    if (n is! YamlList) _fail('config.expected_list', {}, n, '$path.$key');
    return [for (final item in n.nodes) item.value.toString()];
  }

  ProxyConfig parseRoot(YamlNode root) {
    final map = _map(root, '');
    _onlyKeys(
        map,
        {
          'providers',
          'app_check',
          'limits',
          'cors',
          'max_body_bytes',
          'trust_forwarded_for'
        },
        '');

    // --- providers ---
    final providersNode = _node(map, 'providers');
    if (providersNode == null) _fail('config.missing', {}, root, 'providers');
    final providersMap = _map(providersNode, 'providers');
    if (providersMap.isEmpty)
      _fail('config.no_providers', {}, providersNode, 'providers');
    final providers = <ProviderConfig>[];
    for (final entry in providersMap.nodes.entries) {
      final id = (entry.key as YamlNode).value.toString();
      providers.add(_provider(id, entry.value, entry.key as YamlNode));
    }
    final prefixes = <String>{};
    for (final p in providers) {
      if (!prefixes.add(p.prefix)) {
        _fail('config.duplicate_prefix', {'prefix': p.prefix}, providersNode,
            'providers.${p.id}.prefix');
      }
    }

    // --- app_check ---
    final acNode = _node(map, 'app_check');
    if (acNode == null) _fail('config.missing', {}, root, 'app_check');
    final appCheck = _appCheck(_map(acNode, 'app_check'), acNode);

    // --- limits ---
    final limitsNode = _node(map, 'limits');
    var limits = const LimitsConfig();
    if (limitsNode != null) {
      final lm = _map(limitsNode, 'limits');
      _onlyKeys(
          lm,
          {
            'subject',
            'requests_per_minute',
            'tokens_per_day',
            'global_tokens_per_day'
          },
          'limits');
      final subjectName =
          _string(lm, 'subject', 'limits') ?? SubjectKey.appAndIp.yamlName;
      final subject =
          SubjectKey.values.where((s) => s.yamlName == subjectName).firstOrNull;
      if (subject == null) {
        _fail(
            'config.bad_choice',
            {'value': subjectName, 'choices': 'app, ip, app+ip'},
            _node(lm, 'subject'),
            'limits.subject');
      }
      limits = LimitsConfig(
        subject: subject,
        requestsPerMinute: _nonNegativeInt(lm, 'requests_per_minute', 'limits'),
        tokensPerDay: _nonNegativeInt(lm, 'tokens_per_day', 'limits'),
        globalTokensPerDay:
            _nonNegativeInt(lm, 'global_tokens_per_day', 'limits'),
      );
    }

    // --- cors ---
    var origins = const <String>[];
    final corsNode = _node(map, 'cors');
    if (corsNode != null) {
      final cm = _map(corsNode, 'cors');
      _onlyKeys(cm, {'allow_origins'}, 'cors');
      origins = _stringList(cm, 'allow_origins', 'cors');
    }

    return ProxyConfig(
      providers: providers,
      appCheck: appCheck,
      limits: limits,
      corsAllowOrigins: origins,
      maxBodyBytes: _nonNegativeInt(map, 'max_body_bytes', '') ?? 1024 * 1024,
      trustForwardedFor: _bool(map, 'trust_forwarded_for', '') ?? false,
      sourceName: sourceName,
    );
  }

  ProviderConfig _provider(String id, YamlNode node, YamlNode keyNode) {
    final path = 'providers.$id';
    final m = _map(node, path);
    _onlyKeys(
        m,
        {
          'type',
          'prefix',
          'upstream',
          'key_env',
          'key_header',
          'allowed_paths',
          'allowed_models',
          'inject_include_usage',
        },
        path);
    // type 이 없으면 이름(openai·anthropic·gemini)에서 정한다.
    final typeName = _string(m, 'type', path) ?? id;
    final type =
        ProviderType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      _fail(
          'config.bad_choice',
          {'value': typeName, 'choices': 'openai, anthropic, gemini'},
          _node(m, 'type') ?? keyNode,
          '$path.type');
    }
    final d = ProviderConfig.defaults(type, id: id);

    final prefix = _string(m, 'prefix', path) ?? d.prefix;
    if (!prefix.startsWith('/') || prefix.endsWith('/') || prefix.length < 2) {
      _fail('config.bad_prefix', {'value': prefix}, _node(m, 'prefix'),
          '$path.prefix');
    }

    final upstreamText = _string(m, 'upstream', path);
    final upstream =
        upstreamText == null ? d.upstream : Uri.tryParse(upstreamText);
    if (upstream == null ||
        !(upstream.scheme == 'https' || upstream.scheme == 'http') ||
        upstream.host.isEmpty) {
      _fail('config.bad_url', {'value': upstreamText}, _node(m, 'upstream'),
          '$path.upstream');
    }

    final headerName = _string(m, 'key_header', path) ?? d.keyHeader.yamlName;
    final keyHeader = KeyHeaderStyle.values
        .where((k) => k.yamlName == headerName)
        .firstOrNull;
    if (keyHeader == null) {
      _fail(
          'config.bad_choice',
          {'value': headerName, 'choices': 'bearer, x-api-key, x-goog-api-key'},
          _node(m, 'key_header'),
          '$path.key_header');
    }

    final allowedPaths = _node(m, 'allowed_paths') == null
        ? d.allowedPaths
        : _stringList(m, 'allowed_paths', path);
    for (final p in allowedPaths) {
      if (!p.startsWith('/')) {
        _fail('config.bad_path', {'value': p}, _node(m, 'allowed_paths'),
            '$path.allowed_paths');
      }
    }

    return ProviderConfig(
      id: id,
      type: type,
      prefix: prefix,
      upstream: upstream,
      keyEnv: _string(m, 'key_env', path) ?? d.keyEnv,
      keyHeader: keyHeader,
      allowedPaths: allowedPaths,
      allowedModels: _stringList(m, 'allowed_models', path),
      injectIncludeUsage: _bool(m, 'inject_include_usage', path) ?? true,
    );
  }

  AppCheckConfig _appCheck(YamlMap m, YamlNode node) {
    const path = 'app_check';
    _onlyKeys(
        m,
        {
          'mode',
          'project_number',
          'project_id',
          'allowed_app_ids',
          'jwks_url',
          'jwks_file',
          'dev_tokens'
        },
        path);
    final modeName = _string(m, 'mode', path) ?? 'firebase';
    final mode =
        AppCheckMode.values.where((x) => x.name == modeName).firstOrNull;
    if (mode == null) {
      _fail(
          'config.bad_choice',
          {'value': modeName, 'choices': 'firebase, local, off'},
          _node(m, 'mode'),
          '$path.mode');
    }
    final number = _string(m, 'project_number', path);
    if (mode != AppCheckMode.off) {
      if (number == null || number.isEmpty) {
        _fail('config.missing', {}, node, '$path.project_number');
      }
      if (!RegExp(r'^\d+$').hasMatch(number)) {
        _fail('config.bad_project_number', {'value': number},
            _node(m, 'project_number'), '$path.project_number');
      }
    }
    final jwksUrlText = _string(m, 'jwks_url', path);
    final jwksFile = _string(m, 'jwks_file', path);
    Uri? jwksUrl;
    if (jwksUrlText != null) {
      jwksUrl = Uri.tryParse(jwksUrlText);
      if (jwksUrl == null ||
          !(jwksUrl.scheme == 'https' || jwksUrl.scheme == 'http')) {
        _fail('config.bad_url', {'value': jwksUrlText}, _node(m, 'jwks_url'),
            '$path.jwks_url');
      }
    }
    if (mode == AppCheckMode.local && jwksUrlText == null && jwksFile == null) {
      _fail('config.local_needs_jwks', {}, node, '$path.jwks_file');
    }
    return AppCheckConfig(
      mode: mode,
      projectNumber: number ?? '',
      projectId: _string(m, 'project_id', path),
      allowedAppIds: _stringList(m, 'allowed_app_ids', path).toSet(),
      jwksUrl: jwksUrl,
      jwksFile: jwksFile,
      devTokens: _stringList(m, 'dev_tokens', path),
    );
  }
}
