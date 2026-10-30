import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'env_parser.dart';

/// The prefix used for all tool output.
const toolName = 'filo-wayland';

/// A runtime failure that should be reported as a normal tool error.
class ToolError implements Exception {
  ToolError(this.message);

  final String message;
}

/// The app and Wayland runner directories used by every command.
class ToolPaths {
  ToolPaths({required this.appRoot, required this.waylandDir});

  final String appRoot;
  final String waylandDir;

  String get hostDir => '$waylandDir/zig-out/bin';
  String buildDir(String arch, String mode) => '$appRoot/build/wayland/$arch/$mode';
  String defaultBundleDir(String arch, String mode) => '${buildDir(arch, mode)}/bundle';
  String get launchBuildFile => '$waylandDir/.filo-build/launch.json';
  String get launchFile => '$waylandDir/.filo/launch.json';
  String get dotenvFile => '$waylandDir/.env.local';
  String get customDeviceFile => '$waylandDir/custom-device.json';

  static ToolPaths discover() {
    String? script;
    try {
      script = File.fromUri(Platform.script).resolveSymbolicLinksSync();
    } on FileSystemException {
      script = null;
    }
    if (script != null) {
      final wayland = File(script).parent.parent;
      if (File('${wayland.path}/build.zig').existsSync()) {
        return ToolPaths(
          appRoot: wayland.parent.path,
          waylandDir: wayland.path,
        );
      }
    }

    // Fallback for a copied script: walk up from the current directory to the
    // app root. This also handles being invoked from a subdirectory.
    var directory = Directory.current;
    while (true) {
      if (File('${directory.path}/wayland/build.zig').existsSync()) {
        return ToolPaths(
          appRoot: directory.path,
          waylandDir: '${directory.path}/wayland',
        );
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }

    throw ToolError(
      'cannot find the app root; run this from the Flutter app or keep '
      'wayland/tool/wayland.dart in place',
    );
  }
}

Map<String, Object?>? readManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw ToolError('$path: ${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw ToolError('$path: expected a JSON object');
  }
  return decoded;
}

void writeJson(String path, Map<String, Object?> value) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

extension MapExt on Map<String, Object?>? {
  T fieldRequire<T>(String key, String message) {
    if (this == null) throw ToolError(message);
    final value = this![key];
    if (value is! T) throw ToolError(message);
    return value;
  }

  String? fieldStr(String key) {
    final value = this?[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  bool fieldBool(String key) => this?[key] == true;

  List<String>? fieldStrList(String key) {
    final value = this?[key];
    if (value is! List) return null;
    return [
      for (final item in value)
        if (item is String) item,
    ];
  }
}

T require<T>(T? value, String message) => value == null ? throw ToolError(message) : value;

Future<void> runInherited(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required String missingMessage,
}) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
  } on ProcessException {
    throw ToolError(missingMessage);
  }
  final code = await process.exitCode;
  if (code != 0) {
    throw ToolError(
      '$executable ${arguments.join(' ')} failed with exit code $code',
    );
  }
}

void copyTree(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: true)) {
    final relative = entity.path.substring(source.path.length + 1);
    final target = '${destination.path}/$relative';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      final file = File(target);
      file.parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

void makeExecutable(String path) {
  final result = Process.runSync('chmod', ['755', path]);
  if (result.exitCode != 0) {
    throw ToolError('failed to mark $path executable');
  }
}

void writeLauncher(String path, String appName) {
  File(path).writeAsStringSync(
    '#!/bin/sh\n'
    'set -eu\n'
    'cd "\$(dirname "\$0")"\n'
    'exec "./bin/$appName" "\$@"\n',
  );
  makeExecutable(path);
}

/// Shared state for the commands: paths, `.env.local`, manifests and release
/// path resolution.
class Tool {
  Tool(this.paths);

  final ToolPaths paths;

  late final Map<String, String> _dotenv = readDotEnv(paths.dotenvFile);

  static Tool discover() => Tool(ToolPaths.discover());

  String? env(String key) => Platform.environment[key] ?? _dotenv[key];

  String? pathEnv(String key) {
    final value = env(key);
    if (value == null || value.isEmpty) return null;
    return p.join(paths.waylandDir, value);
  }

  bool flag(String key, {required bool fallback}) {
    final value = env(key);
    if (value == null) return fallback;
    return value.isNotEmpty;
  }

  List<String>? dartArgsSetting() {
    final value = env('FILO_DART_ENTRYPOINT_ARGS');
    if (value == null) return null;
    if (value.isEmpty) return <String>[];
    final lines = value.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return [
      for (final line in lines)
        if (line.endsWith('\r')) line.substring(0, line.length - 1) else line,
    ];
  }

  Map<String, Object?> resolveLaunch({
    required String appName,
    String? localPath,
    String? icuOverride,
    Map<String, Object?>? fallback,
  }) {
    final engine = require(
      pathEnv('FILO_ENGINE_LIB') ?? fallback.fieldStr('engine') ?? localEngine(),
      'FILO_ENGINE_LIB is not set; add it to wayland/.env.local',
    );
    final icu = require(
      pathEnv('FILO_ICU_DATA') ??
          (icuOverride != null ? p.join(paths.appRoot, icuOverride) : null) ??
          fallback.fieldStr('icu'),
      'no Flutter ICU data path; run post-build or set FILO_ICU_DATA',
    );
    final assets = require(
      pathEnv('FILO_ASSETS') ??
          (localPath != null ? p.join(paths.appRoot, localPath) : null) ??
          fallback.fieldStr('assets') ??
          defaultAssets(),
      'no flutter_assets directory; run install or set FILO_ASSETS',
    );
    final aot = pathEnv('FILO_AOT_LIB') ?? fallback.fieldStr('aot');

    return launchManifest(
      appName: appName,
      engine: engine,
      icu: icu,
      assets: assets,
      aot: aot,
      fallback: fallback,
    );
  }

  Map<String, Object?> launchManifest({
    required String appName,
    required String engine,
    required String icu,
    required String assets,
    String? aot,
    Map<String, Object?>? fallback,
  }) {
    return {
      'app_name': appName,
      'engine': engine,
      'icu': icu,
      'assets': assets,
      'aot': aot,
      'dart_args': dartArgsSetting() ?? fallback.fieldStrList('dart_args') ?? <String>[],
      'force_impeller': flag(
        'FORCE_IMPELLER',
        fallback: fallback.fieldBool('force_impeller'),
      ),
      'vulkan_validation': flag(
        'FILO_VULKAN_VALIDATION',
        fallback: fallback.fieldBool('vulkan_validation'),
      ),
      'trace': flag('FILO_TRACE', fallback: fallback.fieldBool('trace')),
      'layer_only': flag(
        'FILO_LAYER_ONLY',
        fallback: fallback.fieldBool('layer_only'),
      ),
      'windowing_spike': flag(
        'FILO_WINDOWING_SPIKE',
        fallback: fallback.fieldBool('windowing_spike'),
      ),
    };
  }

  String resolveHost(String appName) {
    for (final candidate in [appName, 'app']) {
      final file = File('${paths.hostDir}/$candidate');
      if (file.existsSync()) return file.path;
    }
    throw ToolError(
      'host executable not found in ${paths.hostDir}; run "zig build" in '
      'wayland/',
    );
  }

  String? localEngine() {
    final file = File('${paths.waylandDir}/engine/libflutter_engine.so');
    return file.existsSync() ? file.path : null;
  }

  String? defaultAssets() {
    final directory = Directory('${paths.appRoot}/build/flutter_assets');
    return directory.existsSync() ? directory.path : null;
  }

  String appName() {
    final pubspec = File('${paths.appRoot}/pubspec.yaml');
    if (!pubspec.existsSync()) return 'app';
    final name = RegExp(
      r'''^\s*name\s*:\s*['"]?([A-Za-z0-9_]+)['"]?\s*(?:#.*)?$''',
    );
    for (final line in pubspec.readAsLinesSync()) {
      final match = name.firstMatch(line);
      if (match != null) return match.group(1)!;
    }
    return 'app';
  }

  String hostTargetPlatform() {
    switch (Abi.current().toString()) {
      case 'linux_x64':
        return 'linux-x64';
      case 'linux_arm64':
        return 'linux-arm64';
      case 'linux_riscv64':
        return 'linux-riscv64';
      default:
        throw ToolError(
          'unsupported host architecture; pass --target-platform',
        );
    }
  }

  String releaseIcu(String targetPlatform) {
    final buildManifest = readManifest(paths.launchBuildFile);
    final installedManifest = readManifest(paths.launchFile);
    final candidates = <String?>[
      pathEnv('FILO_ICU_DATA'),
      buildManifest.fieldStr('icu'),
      installedManifest.fieldStr('icu'),
      '${paths.waylandDir}/engine/icudtl.dat',
      flutterIcu(targetPlatform),
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) continue;
      if (File(candidate).existsSync()) return candidate;
    }
    throw ToolError(
      'no Flutter ICU data; set FILO_ICU_DATA in wayland/.env.local or run a '
      "debug build once so post-build records Flutter's icuDataPath",
    );
  }

  String? flutterIcu(String targetPlatform) {
    final ProcessResult result;
    try {
      result = Process.runSync('flutter', ['--version', '--machine']);
    } on ProcessException {
      return null;
    }
    if (result.exitCode != 0 || result.stdout is! String) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final root = decoded['flutterRoot']! as String;
    for (final platform in [targetPlatform, 'linux-x64']) {
      final file = File(
        '$root/bin/cache/artifacts/engine/$platform/icudtl.dat',
      );
      if (file.existsSync()) return file.path;
    }
    return null;
  }
}

/// Base class for the tool's leaf commands. `tool` is discovered lazily, so
/// `--help` and argument errors do not require a Flutter app.
abstract class ToolCommand extends Command<void> {
  late final Tool tool = Tool.discover();

  void expectCount(List<String> args, int count) {
    if (args.length != count) {
      usageException('$name expects $count argument(s), got ${args.length}');
    }
  }
}
