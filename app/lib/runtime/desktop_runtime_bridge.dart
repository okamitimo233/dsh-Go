// Host-native DSH runtime for Linux desktop.
//
// DSH is a Node program. On Android the app starts it inside a bundled Ubuntu
// rootfs through PRoot; on desktop this implementation installs the official
// npm package into the application support directory and starts `dsh web`
// directly as a child process. No container, PRoot or Docker is involved.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart' show DshLaunchUrl;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/redact.dart';
import 'runtime_bridge.dart';

/// Linux x86_64 implementation of the `dsh/runtime` bridge contract.
///
/// The public status/event types are shared with the Android bridge so the
/// rest of the app (onboarding, logs, connection setup) needs no desktop
/// special cases. Only the storage and process lifecycle are platform
/// specific.
class DesktopRuntimeBridge extends RuntimeBridge {
  DesktopRuntimeBridge({Directory? supportDirectory}) : _fixedSupport = supportDirectory;

  /// The upstream package and version vetted by this repository. Keep this in
  /// step with runtime/build-runtime.sh's DSH_VERSION.
  static const dshPackage = '@deepseek-ai/dsh';
  static const dshVersion = String.fromEnvironment('DSH_DESKTOP_VERSION', defaultValue: '0.2.2-rc.1');
  static const _npmRegistry = 'https://registry.npmjs.org';
  static const _startupTimeout = Duration(seconds: 90);

  final _events = StreamController<RuntimeEvent>.broadcast();
  final _logEntries = <RuntimeLogEntry>[];
  int _nextLogSeq = 1;

  RuntimePhase _phase = RuntimePhase.notInstalled;
  String? _error;
  String? _installedVersion;
  String? _baseUrl;
  String? _token;
  String? _nodeVersion;
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final Directory? _fixedSupport;
  Future<Directory>? _supportDir;
  Future<void>? _initialized;

  bool _stopping = false;
  bool _ready = false;
  Timer? _startupTimer;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  Future<Directory> get _support async {
    if (_fixedSupport case final fixed?) return fixed;
    _supportDir ??= getApplicationSupportDirectory();
    return _supportDir!;
  }

  Future<Directory> get _engineDir async => Directory('${(await _support).path}/dsh-engine');

  Future<Directory> get _homeDir async => Directory('${(await _support).path}/dsh-home');

  Future<Directory> get _workspaceDir async {
    final dir = Directory('${(await _support).path}/workspace');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> get _pidFile async => File('${(await _engineDir).path}/dsh-web.pid');

  Future<void> _removePidFile() async {
    try {
      final file = await _pidFile;
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// A previous app run may have been killed before it stopped DSH. Reuse of
  /// the same DSH_HOME with a second server is not safe, so stop that exact
  /// CLI process before starting a new one. The cmdline check prevents a
  /// recycled PID from hitting an unrelated process.
  Future<void> _stopOrphan(File bin) async {
    try {
      final pidFile = await _pidFile;
      if (!await pidFile.exists()) return;
      final pid = int.tryParse((await pidFile.readAsString()).trim());
      await pidFile.delete();
      if (pid == null || pid <= 1) return;
      final cmdline = File('/proc/$pid/cmdline');
      if (!await cmdline.exists()) return;
      final command = utf8.decode(await cmdline.readAsBytes(), allowMalformed: true);
      if (!command.contains(bin.path)) return;
      Process.killPid(pid, ProcessSignal.sigterm);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!await cmdline.exists()) return;
      }
      Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {
      // Process inspection is best effort; starting still has a clear error if
      // the new server cannot come up.
    }
  }

  Future<void> _ensureInitialized() => _initialized ??= _readInstallState();

  Future<void> _readInstallState() async {
    final dir = await _engineDir;
    final manifest = File('${dir.path}/node_modules/$dshPackage/package.json');
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      final version = decoded is Map ? decoded['version'] : null;
      if (version is String && version.isNotEmpty) {
        _installedVersion = version;
        if (_process == null && _phase == RuntimePhase.notInstalled) {
          _phase = version == dshVersion ? RuntimePhase.installed : RuntimePhase.notInstalled;
        }
      }
    } catch (_) {
      _installedVersion = null;
      if (_process == null && _phase != RuntimePhase.error) {
        _phase = RuntimePhase.notInstalled;
      }
    }
    _nodeVersion = await _runVersion('node');
  }

  Future<String?> _runVersion(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      if (result.exitCode != 0) return null;
      final text = '${result.stdout}'.trim();
      if (text.isEmpty) return null;
      return text.startsWith('v') ? text.substring(1) : text;
    } catch (_) {
      return null;
    }
  }

  RuntimeStatus _status() => RuntimeStatus(
    phase: _phase,
    abi: 'linux-x64',
    bundledVersion: dshVersion,
    installedVersion: _installedVersion,
    dshVersion: _installedVersion,
    nodeVersion: _nodeVersion,
    baseUrl: _baseUrl,
    token: _token,
    error: _error,
    directEngineEnabled: false,
    directEngineAvailable: false,
    directEngineActive: false,
    currentExecutionMode: _process == null ? null : 'host-node',
    launchSelectedMode: _process == null ? null : 'host-node',
    launchSpawned: _process != null,
    launchFailureReason: _error,
  );

  void _emitStatus() {
    if (!_events.isClosed) _events.add(RuntimeStatusEvent(_status()));
  }

  void _emitLog(String line, [String stream = 'system']) {
    final clean = redactDiagnostics(line);
    final entry = RuntimeLogEntry(_nextLogSeq++, clean, stream);
    _logEntries.add(entry);
    if (_logEntries.length > 2000) _logEntries.removeAt(0);
    if (!_events.isClosed) _events.add(RuntimeLogsEvent([entry]));
  }

  void _emitProgress(String step, int done, int total) {
    if (!_events.isClosed) _events.add(RuntimeProgressEvent(step: step, done: done, total: total));
  }

  Future<void> _fail(String message, {bool log = true}) async {
    _startupTimer?.cancel();
    final process = _process;
    _process = null;
    final stdout = _stdoutSub;
    final stderr = _stderrSub;
    _stdoutSub = null;
    _stderrSub = null;
    if (process != null) process.kill(ProcessSignal.sigterm);
    await stdout?.cancel();
    await stderr?.cancel();
    _phase = RuntimePhase.error;
    _baseUrl = null;
    _token = null;
    _error = message;
    if (log) _emitLog(message, 'stderr');
    _emitStatus();
  }

  @override
  Future<RuntimeStatus> status() async {
    await _ensureInitialized();
    return _status();
  }

  @override
  Future<void> install({bool dropKept = false}) async {
    await _ensureInitialized();
    if (_process != null) throw StateError('stop the engine before installing');

    _phase = RuntimePhase.installing;
    _error = null;
    _emitProgress('resolve', 0, 4);
    _emitStatus();
    _emitLog('installing $dshPackage@$dshVersion from $_npmRegistry', 'system');

    try {
      final dir = await _engineDir;
      await dir.create(recursive: true);
      final packageJson = File('${dir.path}/package.json');
      if (!await packageJson.exists()) {
        await packageJson.writeAsString(
          const JsonEncoder.withIndent('  ')
              .convert({'name': 'dsh-go-desktop-runtime', 'private': true, 'version': '1.0.0'}),
        );
      }

      final npm = await _findExecutable('npm');
      final node = await _findExecutable('node');
      if (npm == null) throw const _DesktopRuntimeException('npm was not found on PATH');
      if (node == null) throw const _DesktopRuntimeException('node was not found on PATH');

      _emitProgress('download', 1, 4);
      final env = Map<String, String>.from(Platform.environment);
      final path = env['PATH'] ?? '';
      env['PATH'] = '${File(node).parent.path}:$path';
      final proc = await Process.start(
        npm,
        [
          'install',
          '--prefix',
          dir.path,
          '--save-exact',
          '$dshPackage@$dshVersion',
          '--registry=$_npmRegistry',
          '--no-audit',
          '--no-fund',
          '--loglevel=warn',
        ],
        environment: env,
        runInShell: false,
      );
      final out = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _emitLog(line, 'stdout'), onError: (Object _) {});
      final err = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _emitLog(line, 'stderr'), onError: (Object _) {});
      final code = await proc.exitCode;
      await out.cancel();
      await err.cancel();
      if (code != 0) throw _DesktopRuntimeException('npm install failed with exit code $code');

      _emitProgress('verify', 3, 4);
      await _readInstallState();
      if (_installedVersion != dshVersion) {
        throw _DesktopRuntimeException('installed ${_installedVersion ?? 'nothing'}, expected $dshVersion');
      }
      _phase = RuntimePhase.installed;
      _emitProgress('done', 4, 4);
      _emitLog('installed $dshPackage@$_installedVersion', 'system');
      _emitStatus();
    } catch (e) {
      await _fail('install failed: $e');
    }
  }

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {
    await _ensureInitialized();
    if (_process != null) return;
    if (_installedVersion != dshVersion) {
      await _fail('DSH $dshVersion is not installed');
      return;
    }

    final node = await _findExecutable('node');
    if (node == null) {
      await _fail('node was not found on PATH');
      return;
    }
    final dir = await _engineDir;
    final bin = File('${dir.path}/node_modules/$dshPackage/lib/bin.js');
    if (!await bin.exists()) {
      await _fail('DSH CLI is missing at ${bin.path}');
      return;
    }

    final home = await _homeDir;
    final workspace = await _workspaceDir;
    await home.create(recursive: true);
    await _stopOrphan(bin);

    _stopping = false;
    _ready = false;
    _error = null;
    _baseUrl = null;
    _token = null;
    _phase = RuntimePhase.starting;
    _emitLog('[dsh-go] starting host-native DSH $dshVersion', 'system');
    _emitStatus();

    try {
      final process = await Process.start(
        node,
        [bin.path, 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'],
        workingDirectory: workspace.path,
        environment: {...Platform.environment, ...env, 'DSH_HOME': home.path, 'NO_COLOR': '1'},
        runInShell: false,
      );
      _process = process;
      await (await _pidFile).writeAsString('${process.pid}\n', mode: FileMode.writeOnly);
      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _onOutput(line, 'stdout'), onError: (Object _) {});
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _onOutput(line, 'stderr'), onError: (Object _) {});
      _startupTimer = Timer(_startupTimeout, () {
        if (!_ready) unawaited(_fail('DSH did not print a launch token within ${_startupTimeout.inSeconds}s'));
      });

      unawaited(
        process.exitCode.then((code) async {
          _startupTimer?.cancel();
          await _stdoutSub?.cancel();
          await _stderrSub?.cancel();
          _stdoutSub = null;
          _stderrSub = null;
          _process = null;
          _baseUrl = null;
          _token = null;
          await _removePidFile();
          if (_stopping) {
            _phase = RuntimePhase.installed;
            _error = null;
          } else {
            _phase = RuntimePhase.error;
            _error = 'DSH exited with code $code';
          }
          _emitStatus();
        }),
      );
    } catch (e) {
      await _fail('start failed: $e');
    }
  }

  void _onOutput(String line, String stream) {
    _emitLog(line, stream);
    if (_ready) return;
    final launch = DshLaunchUrl.tryParse(line);
    if (launch == null) return;
    _ready = true;
    _startupTimer?.cancel();
    _baseUrl = launch.baseUri.toString();
    _token = launch.token;
    _phase = RuntimePhase.running;
    _emitLog('[dsh-go] DSH is ready at ${launch.baseUri.authority}', 'system');
    _emitStatus();
  }

  @override
  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      if (_phase == RuntimePhase.running) _phase = RuntimePhase.installed;
      _emitStatus();
      return;
    }
    _stopping = true;
    _phase = RuntimePhase.stopping;
    _emitStatus();
    process.kill(ProcessSignal.sigterm);
    final exited = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (_process != null) {
      _process = null;
      _phase = exited == -1 ? RuntimePhase.error : RuntimePhase.installed;
      if (exited == -1) _error = 'DSH did not stop within 10s';
      _emitStatus();
    }
    await _removePidFile();
  }

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) async {
    await stop();
    final support = await _support;
    final engine = Directory('${support.path}/dsh-engine');
    final home = Directory('${support.path}/dsh-home');
    if (await engine.exists()) await engine.delete(recursive: true);
    if (await home.exists()) await home.delete(recursive: true);
    _installedVersion = null;
    _phase = RuntimePhase.notInstalled;
    _error = null;
    _baseUrl = null;
    _token = null;
    _logEntries.clear();
    await _removePidFile();
    _emitStatus();
  }

  @override
  Future<List<String>> logs({int lines = 500}) async {
    final tail = _logEntries.length <= lines ? _logEntries : _logEntries.sublist(_logEntries.length - lines);
    return [for (final entry in tail) entry.line];
  }

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async {
    final tail = _logEntries.length <= lines
        ? List<RuntimeLogEntry>.from(_logEntries)
        : _logEntries.sublist(_logEntries.length - lines);
    return RuntimeLogSnapshot(tail, _nextLogSeq - 1);
  }

  Future<String?> _findExecutable(String name) async {
    // GUI launches often do not inherit a login shell's PATH, so nvm/fnm/volta
    // installs would otherwise be invisible. DSH_GO_NODE lets a user point at
    // a specific Node installation; npm is looked up from its own variable.
    final override = Platform.environment[name == 'node' ? 'DSH_GO_NODE' : 'DSH_GO_NPM'];
    if (override != null && override.trim().isNotEmpty) {
      final configured = File(override.trim());
      if (await configured.exists()) return configured.path;
    }

    final dirs = <String>{
      ...(Platform.environment['PATH'] ?? '').split(':'),
      '/usr/local/bin',
      '/usr/bin',
      '/snap/bin',
      if (Platform.environment['HOME'] case final home?) ...{'$home/.local/bin', '$home/.volta/bin', '$home/.bun/bin'},
    };
    Future<String?> fromDirs(Iterable<String> candidates) async {
      for (final dir in candidates) {
        if (dir.isEmpty) continue;
        final candidate = File('$dir/$name');
        if (await candidate.exists()) return candidate.path;
      }
      return null;
    }

    final direct = await fromDirs(dirs);
    if (direct != null) return direct;

    // Version-manager layouts: ~/.nvm/versions/node/*/bin and
    // ~/.local/share/fnm/node-versions/*/installation/bin.
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final roots = <String>{'$home/.nvm/versions/node', '$home/.local/share/fnm/node-versions'};
    for (final rootPath in roots) {
      final root = Directory(rootPath);
      if (!await root.exists()) continue;
      final children = await root.list().where((e) => e is Directory).toList();
      children.sort((a, b) => b.path.compareTo(a.path));
      final found = await fromDirs([
        for (final child in children)
          if (child.path.contains('node-versions')) '${child.path}/installation/bin' else '${child.path}/bin',
      ]);
      if (found != null) return found;
    }
    return null;
  }

  @override
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) async => const ManagedSkillInstallResponse(result: 'unsupported', current: false, reason: 'desktop');

  @override
  Future<void> cancelManagedSkill(String requestId) async {}

  @override
  Future<LastKnownGood> lastKnownGood() async => const LastKnownGood.none();

  @override
  Future<LastKnownGood> restoreLastKnownGood() async => const LastKnownGood.none();

  @override
  Future<List<SafeHazard>> safePreflight() async => const [];

  @override
  Future<List<String>> moveAside(List<String> paths) async => const [];

  @override
  Future<void> clearFailure() async {}

  @override
  Future<void> setAutoSafe(bool enabled) async {}

  @override
  Future<void> setWorkspaceRecovery(bool enabled) async {}

  @override
  Future<void> setDirectEngine(bool enabled) async {}

  @override
  Future<List<String>> failureLog() async => const [];

  @override
  Future<StorageAccess> storageStatus() async => const StorageAccess(granted: true, permission: true, legacy: true);

  @override
  Future<StorageAccess> requestStorage() async => storageStatus();

  @override
  Future<bool> openAllFilesAccess() async => true;

  @override
  Future<bool?> batteryExempt() async => null;

  @override
  Future<bool?> requestBatteryExempt() async => null;

  @override
  Future<BackgroundSettingsInfo?> backgroundSettings() async => null;

  @override
  Future<String?> openBackgroundSettings() async => null;

  @override
  Future<String?> openVendorSettings(String vendorSwitch) async => null;

  @override
  Future<bool?> networkMetered() async => null;
}

class _DesktopRuntimeException implements Exception {
  const _DesktopRuntimeException(this.message);
  final String message;

  @override
  String toString() => message;
}
