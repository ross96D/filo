import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

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

void clearDirectory(Directory directory) {
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
    return;
  }
  for (final entity in directory.listSync(followLinks: false)) {
    File(entity.path).deleteSync(recursive: true);
  }
}

void replaceLink(String linkPath, String target) {
  try {
    File(linkPath).deleteSync(recursive: true);
  } catch (_) {}
  Link(linkPath).createSync(target);
}

void makeExecutable(String path) {
  final result = Process.runSync('chmod', ['755', path]);
  if (result.exitCode != 0) {
    throw ToolError('failed to mark $path executable');
  }
}

/// Shared state for the commands: paths, environment and bundle staging.
class Tool {
  Tool(this.paths);

  final ToolPaths paths;

  static Tool discover() => Tool(ToolPaths.discover());

  String? env(String key) {
    final value = Platform.environment[key];
    return value == null || value.isEmpty ? null : value;
  }

  String? pathEnv(String key) {
    final value = env(key);
    if (value == null) return null;
    return p.isAbsolute(value) ? p.normalize(value) : p.join(paths.waylandDir, value);
  }

  String _resolveAppPath(String value) {
    return p.isAbsolute(value) ? p.normalize(value) : p.join(paths.appRoot, value);
  }

  String localEngine(String mode) {
    return p.join(paths.waylandDir, 'engine', mode, 'libflutter_engine.so');
  }

  String get localIcu => p.join(paths.waylandDir, 'engine', 'common', 'icudtl.dat');

  String get defaultAssets => p.join(paths.appRoot, 'build', 'flutter_assets');

  String debugEngineSource() => pathEnv('FILO_ENGINE_LIB') ?? localEngine('debug');

  String releaseEngineSource() => pathEnv('FILO_ENGINE_LIB_RELEASE') ?? localEngine('release');

  String assetsSource({String? hookPath}) {
    final override = pathEnv('FILO_ASSETS');
    if (override != null) return override;
    if (hookPath != null && hookPath.isNotEmpty) return _resolveAppPath(hookPath);
    return defaultAssets;
  }

  String icuSource({String? hookPath}) {
    final override = pathEnv('FILO_ICU_DATA');
    if (override != null) return override;
    if (hookPath != null && hookPath.isNotEmpty) return _resolveAppPath(hookPath);
    return localIcu;
  }

  /// Copy the host and stage the engine, ICU data and assets next to it:
  ///
  /// `build/wayland/<arch>/debug/bundle/<appName>`
  /// `build/wayland/<arch>/debug/bundle/lib/libflutter_engine.so`
  /// `build/wayland/<arch>/debug/bundle/data/icudtl.dat`
  /// `build/wayland/<arch>/debug/bundle/data/flutter_assets`
  ///
  /// The executable is copied, not symlinked, because the host derives the
  /// bundle root from its own path.
  String stageDebugBundle({
    required String appName,
    String? assets,
    String? icu,
  }) {
    final root = paths.defaultBundleDir(hostArch(), 'debug');
    final libDir = Directory(p.join(root, 'lib'))..createSync(recursive: true);
    final dataDir = Directory(p.join(root, 'data'))..createSync(recursive: true);
    clearDirectory(libDir);
    clearDirectory(dataDir);

    final host = File(p.join(paths.hostDir, appName));
    if (!host.existsSync()) {
      throw ToolError(
        'host executable not found at ${host.path}; run "zig build" in wayland/',
      );
    }
    final stagedHost = p.join(root, appName);
    host.copySync(stagedHost);
    makeExecutable(stagedHost);

    final engine = File(debugEngineSource());
    if (!engine.existsSync()) {
      throw ToolError(
        'debug engine not found at ${engine.path}; set FILO_ENGINE_LIB or '
        'place the engine at ${localEngine('debug')}',
      );
    }
    replaceLink(
      p.join(libDir.path, 'libflutter_engine.so'),
      p.absolute(engine.resolveSymbolicLinksSync()),
    );

    final assetsDir = Directory(assetsSource(hookPath: assets));
    if (!assetsDir.existsSync()) {
      throw ToolError(
        'flutter_assets not found at ${assetsDir.path}; set FILO_ASSETS or '
        'build the app first',
      );
    }
    final resolvedAssets = assetsDir.resolveSymbolicLinksSync();

    final nativeDir = nativeAssetsDir(resolvedAssets);
    if (nativeDir != null) {
      for (final entity in nativeDir.listSync(followLinks: true)) {
        if (entity is File && entity.path.endsWith('.so')) {
          entity.copySync(p.join(libDir.path, p.basename(entity.path)));
        }
      }
    }

    final icuFile = File(icuSource(hookPath: icu));
    if (!icuFile.existsSync()) {
      throw ToolError(
        'ICU data not found at ${icuFile.path}; set FILO_ICU_DATA or place '
        'icudtl.dat at ${localIcu}',
      );
    }
    replaceLink(
      p.join(dataDir.path, 'icudtl.dat'),
      p.absolute(icuFile.resolveSymbolicLinksSync()),
    );
    replaceLink(p.join(dataDir.path, 'flutter_assets'), p.absolute(resolvedAssets));

    return root;
  }

  Directory? nativeAssetsDir(String assets) {
    for (final candidate in [
      p.join(assets, 'native_assets', 'linux'),
      p.join(assets, '..', 'native_assets', 'linux'),
    ]) {
      final directory = Directory(candidate);
      if (directory.existsSync()) return directory;
    }
    return null;
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

  String hostArch() {
    switch (Abi.current().toString()) {
      case 'linux_x64':
        return 'x64';
      case 'linux_arm64':
        return 'arm64';
      case 'linux_riscv64':
        return 'riscv64';
      default:
        throw ToolError('unsupported host architecture');
    }
  }

  String archForTargetPlatform(String targetPlatform) {
    switch (targetPlatform) {
      case 'linux-x64':
        return 'x64';
      case 'linux-arm64':
        return 'arm64';
      case 'linux-riscv64':
        return 'riscv64';
      default:
        throw ToolError('unsupported target platform $targetPlatform');
    }
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
