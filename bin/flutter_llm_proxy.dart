import 'dart:io';

import 'package:flutter_llm_proxy/src/cli.dart';

/// flutter_llm_proxy — serve | demo | check-config. See `--help`.
Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  await stdout.flush();
  exit(code);
}
