import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'config.dart';
import 'demo/demo_runner.dart';
import 'i18n/messages.dart';
import 'log.dart';
import 'mock/mock_upstream.dart';
import 'proxy/router.dart';
import 'server.dart';
import 'version.dart';

/// Exit codes: 0 ok, 1 an expectation did not hold (demo) or a warning
/// under `--strict`, 2 usage or config error.
const exitOk = 0;
const exitMismatch = 1;
const exitUsage = 2;

/// The whole CLI, callable in-process (tests) or from bin/.
///
/// [stopSignal] ends `serve`; by default it is Ctrl+C / SIGTERM.
Future<int> runCli(
  List<String> arguments, {
  Map<String, String>? environment,
  void Function(String line)? out,
  void Function(String line)? err,
  Future<void>? stopSignal,
}) async {
  final env = environment ?? Platform.environment;
  final void Function(String) print_ = out ?? (String s) => stdout.writeln(s);
  final void Function(String) printErr = err ?? (String s) => stderr.writeln(s);
  final lang = resolveLang(flag: _preScanLang(arguments), env: env);
  final m = Messages(lang);

  final parser = _buildParser();
  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    printErr(m.t('cli.usage_error', {'detail': e.message}));
    printErr(m.t('cli.see_help'));
    return exitUsage;
  }
  final langFlag = args['lang'] as String?;
  if (langFlag != null && langFlag != 'en' && langFlag != 'ko') {
    printErr(m.t('cli.bad_lang', {'value': langFlag}));
    return exitUsage;
  }

  if (args['version'] == true) {
    print_('flutter_llm_proxy $packageVersion');
    return exitOk;
  }
  final command = args.command;
  if (args['help'] == true) {
    print_(_globalHelp(m));
    return exitOk;
  }
  if (command == null) {
    printErr(_globalHelp(m));
    return exitUsage;
  }
  if (command['help'] == true) {
    print_(m.t('help.${command.name}'));
    return exitOk;
  }

  switch (command.name) {
    case 'demo':
      return _demo(command, m, print_, printErr);
    case 'check-config':
      return _checkConfig(command, m, env, print_, printErr);
    case 'serve':
      return _serve(command, m, env, print_, printErr, stopSignal);
  }
  return exitUsage;
}

/// `--lang` must be known before parsing so parse errors are translated too.
String? _preScanLang(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--lang=')) return a.substring(7);
    if (a == '--lang' && i + 1 < args.length) return args[i + 1];
  }
  return null;
}

ArgParser _buildParser() {
  // 도움말 문구는 메시지 표(en/ko)에서 직접 만든다 — ArgParser.usage 는 영어 고정이라 쓰지 않는다.
  ArgParser withHelp(ArgParser p) =>
      p..addFlag('help', abbr: 'h', negatable: false);
  final parser = ArgParser()
    ..addOption('lang')
    ..addFlag('version', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  parser.addCommand(
      'serve',
      withHelp(ArgParser()
        ..addOption('config', abbr: 'c')
        ..addFlag('mock', negatable: false)
        ..addOption('host', defaultsTo: '127.0.0.1')
        ..addOption('port')
        ..addOption('lang')));
  parser.addCommand(
      'demo',
      withHelp(ArgParser()
        ..addOption('only',
            allowed: ['all', 'security', 'limits', 'buffering'],
            defaultsTo: 'all')
        ..addOption('delay-ms', defaultsTo: '250')
        ..addOption('lang')));
  parser.addCommand(
      'check-config',
      withHelp(ArgParser()
        ..addFlag('strict', negatable: false)
        ..addOption('lang')));
  return parser;
}

String _globalHelp(Messages m) =>
    m.t('help.global', {'version': packageVersion});

// ------------------------------------------------------------------ demo
Future<int> _demo(ArgResults a, Messages m, void Function(String) out,
    void Function(String) err) async {
  final delay = int.tryParse(a['delay-ms'] as String);
  if (delay == null || delay < 10 || delay > 5000) {
    err(m.t('cli.bad_delay', {'value': a['delay-ms']}));
    return exitUsage;
  }
  final ok = await DemoRunner(m.lang,
          out: out, chunkDelay: Duration(milliseconds: delay))
      .run(only: a['only'] as String);
  return ok ? exitOk : exitMismatch;
}

// ------------------------------------------------------------------ check-config
ProxyConfig? _loadConfig(String path, Messages m, void Function(String) err) {
  try {
    return ProxyConfig.load(path);
  } on ConfigException catch (e) {
    if (e.messageKey == 'config.file_not_found') {
      err(m.t('cli.config_not_found', {'path': path}));
      return null;
    }
    err(m.t('cli.config_error', {
      'file': e.sourceName.isEmpty ? path : e.sourceName,
      'line': e.line,
      'path': e.keyPath.isEmpty ? '-' : e.keyPath,
      'message': m.t(e.messageKey, e.args),
    }));
    return null;
  }
}

int _checkConfig(ArgResults a, Messages m, Map<String, String> env,
    void Function(String) out, void Function(String) err) {
  if (a.rest.length != 1) {
    err(m.t('cli.check_needs_file'));
    return exitUsage;
  }
  final config = _loadConfig(a.rest.single, m, err);
  if (config == null) return exitUsage;

  final ac = config.appCheck;
  out(m.t('cc.header', {'file': a.rest.single}));
  out(m.t('cc.app_check', {
    'mode': ac.mode.name,
    'number': ac.projectNumber.isEmpty ? '-' : ac.projectNumber,
    'id': ac.projectId ?? '-',
    'apps':
        ac.allowedAppIds.isEmpty ? m.t('cc.any') : ac.allowedAppIds.join(', '),
  }));
  if (ac.mode != AppCheckMode.off) {
    out(m.t('cc.jwks', {
      'source': ac.mode == AppCheckMode.local && ac.jwksFile != null
          ? ac.jwksFile
          : ac.jwksUrl
    }));
  }
  out(m.t('cc.providers'));
  final warnings = config.warnings();
  for (final p in config.providers) {
    final keySet = (env[p.keyEnv] ?? '').isNotEmpty;
    // 키 값은 절대 출력하지 않는다 — 설정 여부만.
    out(m.t('cc.provider', {
      'id': p.id,
      'type': p.type.name,
      'prefix': p.prefix,
      'upstream': p.upstream,
      'env': p.keyEnv,
      'header': p.keyHeader.yamlName,
      'state': keySet ? m.t('cc.key_set') : m.t('cc.key_not_set'),
    }));
    out(m.t('cc.paths', {'paths': p.allowedPaths.join(', ')}));
    out(m.t('cc.models', {
      'models':
          p.allowedModels.isEmpty ? m.t('cc.any') : p.allowedModels.join(', ')
    }));
    if (p.type == ProviderType.openai) {
      out(m.t('cc.include_usage',
          {'value': p.injectIncludeUsage ? m.t('cc.on') : m.t('cc.off')}));
    }
    if (!keySet)
      warnings.add(ConfigWarning(
          'warn.key_not_set', {'env': p.keyEnv, 'provider': p.id}));
  }
  final l = config.limits;
  String n(int? v) => v == null ? m.t('cc.unlimited') : '$v';
  out(m.t('cc.limits', {
    'subject': l.subject.yamlName,
    'rpm': n(l.requestsPerMinute),
    'tpd': n(l.tokensPerDay),
    'global': n(l.globalTokensPerDay),
  }));
  out(m.t('cc.cors', {
    'origins': config.corsAllowOrigins.isEmpty
        ? m.t('cc.none')
        : config.corsAllowOrigins.join(', ')
  }));
  out(m.t('cc.misc', {
    'bytes': config.maxBodyBytes,
    'xff': config.trustForwardedFor ? m.t('cc.on') : m.t('cc.off'),
  }));
  if (warnings.isEmpty) {
    out(m.t('cc.no_warnings'));
  } else {
    out(m.t('cc.warnings', {'count': warnings.length}));
    for (final w in warnings) {
      out('  - ${m.t(w.messageKey, w.args)}');
    }
  }
  if (a['strict'] == true && warnings.isNotEmpty) {
    err(m.t('cc.strict_fail', {'count': warnings.length}));
    return exitMismatch;
  }
  out(m.t('cc.ok'));
  return exitOk;
}

// ------------------------------------------------------------------ serve
Future<int> _serve(
    ArgResults a,
    Messages m,
    Map<String, String> env,
    void Function(String) out,
    void Function(String) err,
    Future<void>? stopSignal) async {
  final path = a['config'] as String?;
  if (path == null) {
    err(m.t('cli.serve_needs_config'));
    return exitUsage;
  }
  var config = _loadConfig(path, m, err);
  if (config == null) return exitUsage;

  final host = a['host'] as String;
  final portText = (a['port'] as String?) ?? env['PORT'] ?? '8080';
  final port = int.tryParse(portText);
  if (port == null || port < 0 || port > 65535) {
    err(m.t('cli.bad_port', {'value': portText}));
    return exitUsage;
  }

  // 개발용 토큰이나 App Check 끔은 내 컴퓨터(루프백)에서만 허용한다.
  final insecure = config.appCheck.devTokens.isNotEmpty ||
      config.appCheck.mode == AppCheckMode.off;
  if (insecure && !isLoopbackHost(host)) {
    err(m.t('serve.refuse_public', {'host': host}));
    return exitUsage;
  }

  final mockMode = a['mock'] == true;
  MockUpstream? mock;
  Map<String, String> keys;
  if (mockMode) {
    // 연습용 목: 업스트림 주소를 로컬 목으로 바꾸고, 진짜 키 대신 가짜 키를 붙인다.
    mock = await MockUpstream.start();
    final mockUrl = mock.url;
    config = ProxyConfig(
      providers: [
        for (final p in config.providers) p.copyWith(upstream: mockUrl)
      ],
      appCheck: config.appCheck,
      limits: config.limits,
      corsAllowOrigins: config.corsAllowOrigins,
      maxBodyBytes: config.maxBodyBytes,
      trustForwardedFor: config.trustForwardedFor,
      sourceName: config.sourceName,
    );
    keys = {for (final p in config.providers) p.id: 'mock-server-key-${p.id}'};
  } else {
    keys = serverKeysFromEnvironment(config, env);
    final missing = [
      for (final p in config.providers)
        if (!keys.containsKey(p.id)) p.keyEnv
    ];
    if (missing.isNotEmpty) {
      err(m.t('serve.missing_keys', {'envs': missing.join(', ')}));
      return exitUsage;
    }
  }

  final logger = RequestLogger(sink: out, lang: m.lang);
  final app = ProxyApp(config, serverKeys: keys, logger: logger);
  HttpServer server;
  try {
    server = await app.serve(host: host, port: port);
  } on SocketException catch (e) {
    await mock?.close();
    err(m.t('serve.bind_failed',
        {'host': host, 'port': port, 'detail': e.message}));
    return exitUsage;
  }

  if (mockMode) logger.info('serve.mock_banner');
  for (final w in config.warnings()) {
    logger.info('serve.warning', {'text': m.t(w.messageKey, w.args)});
  }
  final shownHost = server.address.type == InternetAddressType.IPv6
      ? '[${server.address.host}]'
      : host;
  logger.info('serve.listening',
      {'url': 'http://$shownHost:${server.port}', 'version': packageVersion});
  for (final p in config.providers) {
    logger.info('serve.route', {'prefix': p.prefix, 'upstream': p.upstream});
  }

  await (stopSignal ?? _waitForSignal());
  logger.info('serve.stopping');
  await server.close(force: true);
  await mock?.close();
  return exitOk;
}

Future<void> _waitForSignal() {
  final done = Completer<void>();
  final subs = <StreamSubscription<ProcessSignal>>[];
  void stop(ProcessSignal _) {
    if (!done.isCompleted) done.complete();
  }

  subs.add(ProcessSignal.sigint.watch().listen(stop));
  if (!Platform.isWindows) subs.add(ProcessSignal.sigterm.watch().listen(stop));
  return done.future.whenComplete(() async {
    for (final s in subs) {
      await s.cancel();
    }
  });
}
