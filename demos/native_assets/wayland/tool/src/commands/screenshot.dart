import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tool.dart';

/// Capture the running app through the engine's VM service.
///
/// Flutter's custom-device screenshot hook expects base64-encoded PNG bytes on
/// stdout. The engine renders the last layer tree into an offscreen surface for
/// `_flutter.screenshot`, so this command does not depend on the compositor or
/// an external screenshot tool.
class ScreenshotCommand extends ToolCommand {
  @override
  String get name => 'screenshot';

  @override
  String get description =>
      'Capture the running app as a base64 PNG for flutter screenshot.';

  @override
  String get invocation => 'dart wayland/tool/wayland.dart screenshot';

  @override
  bool get takesArguments => false;

  @override
  Future<void> run() async {
    final uri = await _findServiceUri();
    final screenshot = await _capture(uri);
    stdout.write(screenshot);
    await stdout.flush();
  }

  /// The embedder publishes one JSON file per running app under
  /// `$XDG_RUNTIME_DIR/filo`. Prefer this app's file, but accept any of them:
  /// the development runner is called `filo`, not the app name, and the user
  /// may run several filo apps at once.
  Future<String> _findServiceUri() async {
    final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtimeDir == null || runtimeDir.isEmpty) {
      throw ToolError(
        'XDG_RUNTIME_DIR is not set; cannot find the running app',
      );
    }
    final directory = Directory('$runtimeDir/filo');
    final appPrefix = '${tool.appName()}-';

    // The file exists before the engine has finished starting, so allow a
    // short grace period. The WebSocket call itself retries for the first
    // frame.
    for (var attempt = 0; attempt < 25; attempt++) {
      for (final file in _serviceFiles(directory, appPrefix)) {
        try {
          final decoded = jsonDecode(file.readAsStringSync());
          if (decoded is Map && decoded['uri'] is String) {
            return decoded['uri'] as String;
          }
        } on FileSystemException {
          // The app removed the file between listing and reading it.
        } on FormatException {
          // Not one of ours; try the next file.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    throw ToolError(
      'no running filo app found in ${directory.path}; start it with '
      '"flutter run -d filo_wayland" first',
    );
  }

  List<File> _serviceFiles(Directory directory, String appPrefix) {
    if (!directory.existsSync()) return const <File>[];

    final files = <File>[];
    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      if (_isStale(file)) {
        // A host that was killed without running its deinit leaves its URI
        // behind. Do not let it hide a live app.
        try {
          file.deleteSync();
        } on FileSystemException {
          // Another process removed it first.
        }
        continue;
      }
      files.add(file);
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    final preferred = files
        .where((file) => _basename(file.path).startsWith(appPrefix))
        .toList();
    return preferred.isEmpty ? files : preferred;
  }

  bool _isStale(File file) {
    if (!Platform.isLinux) return false;
    final match = RegExp(r'-(\d+)\.json$').firstMatch(_basename(file.path));
    final pid = int.tryParse(match?.group(1) ?? '');
    if (pid == null) return false;
    return !Directory('/proc/$pid').existsSync();
  }

  String _basename(String path) => path.split(Platform.pathSeparator).last;

  /// The embedder publishes the URI before it starts the engine, so the socket
  /// can still refuse the first few connections.
  Future<WebSocket> _connect(Uri socketUri) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await WebSocket.connect(
          socketUri.toString(),
        ).timeout(const Duration(seconds: 2));
      } on IOException {
        if (attempt >= 24) rethrow;
      } on TimeoutException {
        if (attempt >= 24) rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<String> _capture(String serviceUri) async {
    final base = Uri.parse(serviceUri);
    final socketUri = base.replace(scheme: 'ws', path: '${base.path}ws');
    final socket = await _connect(socketUri);

    final pending = <String, Completer<Map<String, dynamic>>>{};
    final subscription = socket.listen((data) {
      if (data is! String) return;
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      final id = decoded['id'];
      if (id is! String) return;
      pending.remove(id)?.complete(decoded);
    });

    var nextId = 0;
    Future<Map<String, dynamic>> call(
      String method, [
      Map<String, Object?>? params,
    ]) {
      final id = '${++nextId}';
      final completer = Completer<Map<String, dynamic>>();
      pending[id] = completer;
      socket.add(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params ?? const <String, Object?>{},
        }),
      );
      return completer.future.timeout(const Duration(seconds: 15));
    }

    try {
      final vm = await call('getVM');
      final vmResult = vm['result'];
      if (vmResult is! Map) {
        throw ToolError('the VM service did not return a VM');
      }
      final isolates = vmResult['isolates'];
      if (isolates is! List || isolates.isEmpty) {
        throw ToolError('the VM service has no isolates');
      }
      final isolate = isolates.firstWhere(
        (value) => value is Map && value['name'] == 'main',
        orElse: () => isolates.first,
      );
      final isolateId = (isolate as Map)['id'];
      if (isolateId is! String) {
        throw ToolError('the VM service returned no isolate id');
      }

      for (var attempt = 0; attempt < 20; attempt++) {
        final response = await call('_flutter.screenshot', <String, Object?>{
          'isolateId': isolateId,
        });

        final error = response['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String && message.contains('Could not capture')) {
            // The engine has not rendered a frame yet.
            await Future<void>.delayed(const Duration(milliseconds: 100));
            continue;
          }
          throw ToolError(
            message is String ? message : 'screenshot failed: $error',
          );
        }

        final result = response['result'];
        if (result is Map && result['screenshot'] is String) {
          return (result['screenshot'] as String).replaceAll(RegExp(r'\s'), '');
        }
        throw ToolError('the VM service returned no screenshot');
      }
      throw ToolError('the engine has not rendered a frame yet');
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  }
}
