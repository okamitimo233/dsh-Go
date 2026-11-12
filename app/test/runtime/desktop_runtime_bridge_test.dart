import 'dart:io';

import 'package:dsh_app/runtime/desktop_runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory support;
  late DesktopRuntimeBridge bridge;

  setUp(() {
    support = Directory.systemTemp.createTempSync('dsh-desktop-runtime-test-');
    bridge = DesktopRuntimeBridge(supportDirectory: support);
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  test('an empty support directory reports the bundled DSH as not installed', () async {
    final status = await bridge.status();
    expect(status.phase, RuntimePhase.notInstalled);
    expect(status.abi, 'linux-x64');
    expect(status.bundledVersion, DesktopRuntimeBridge.dshVersion);
    expect(status.installedVersion, isNull);
  });

  test('a matching npm package is reported as installed', () async {
    final pkg = Directory('${support.path}/dsh-engine/node_modules/@deepseek-ai/dsh')..createSync(recursive: true);
    File('${pkg.path}/package.json').writeAsStringSync('{"version":"${DesktopRuntimeBridge.dshVersion}"}');

    final status = await bridge.status();
    expect(status.phase, RuntimePhase.installed);
    expect(status.installedVersion, DesktopRuntimeBridge.dshVersion);
    expect(status.dshVersion, DesktopRuntimeBridge.dshVersion);
  });
}
