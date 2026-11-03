import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../tool.dart';

const filoUrl = "git+https://github.com/ross96d/filo#master";

class SetupFiloCommand extends ToolCommand {
  final _argParser = ArgParser()
    ..addFlag(
      'check',
      negatable: false,
      help: 'Run a fast build-graph check after fetching.',
    )
    ..addFlag('with-engine', help: 'Download the engines', defaultsTo: false);

  @override
  String get name => 'setup-filo';

  @override
  String get description => 'Fetch filo, pin its hash, and initialize the package identity.';

  @override
  String get invocation => 'dart wayland/tool/wayland.dart setup-filo [--check] <filo-package-url>';

  @override
  ArgParser get argParser => _argParser;

  @override
  Future<void> run() async {
    final check = argResults!.flag('check');
    final withEngine = argResults!.flag('with-engine');

    final manifest = File('${tool.paths.waylandDir}/build.zig.zon');
    if (!manifest.existsSync()) {
      throw ToolError('${manifest.path} not found');
    }

    final before = _ensureIdentity(manifest, tool.appName());
    if (before.changed) {
      stdout.writeln(
        '$toolName: package ${before.name}, fingerprint 0x${before.fingerprint}',
      );
    }

    final zigPkgDir = Directory(p.join(tool.paths.waylandDir, "zig-pkg"));
    // This is my really bad attempt to not download filo if already downloaded..
    if (!zigPkgDir.existsSync() ||
        zigPkgDir.listSync().where((e) => p.basename(e.path).contains("filo")).isEmpty) {
      await runInherited(
        'zig',
        ['fetch', '--save=filo', filoUrl],
        workingDirectory: tool.paths.waylandDir,
        missingMessage: 'zig is not on PATH',
      );

      final after = _ensureIdentity(manifest, tool.appName());
      stdout.writeln(
        '$toolName: package ${after.name}, fingerprint 0x${after.fingerprint}',
      );
      final fetched = manifest.readAsStringSync();
      final hash = RegExp(
        r'\.hash\s*=\s*"([^"]+)"',
      ).firstMatch(fetched)?.group(1);
      if (hash != null) {
        stdout.writeln('$toolName: hash $hash');
      }
      stdout.writeln('$toolName: fetched filo from $filoUrl');
    }

    if (check) {
      await _checkBuildGraph(tool.paths.waylandDir);
      stdout.writeln('$toolName: build graph OK');
    }

    if (withEngine) {
      var progress = _DownloadProgress('Downloading debug engine');
      final debugEngine = File('${tool.paths.waylandDir}/engine/debug/engine.debug.tar.xz');
      debugEngine.createSync(recursive: true);
      await downloadAndUntar(
        Uri.parse(
          "https://github.com/ross96D/flutter-ci/releases/download/engine%2Fdeb287481e3ce9468f3434937ced4240a70539ca/engine.debug.tar.xz",
        ),
        debugEngine,
        progress.call,
      );
      progress.done();
      debugEngine.deleteSync();

      progress = _DownloadProgress('Downloading release-small engine');
      final releaseSmallEngine =
          File('${tool.paths.waylandDir}/engine/release/engine.release-small.tar.xz');
      releaseSmallEngine.createSync(recursive: true);
      await downloadAndUntar(
        Uri.parse(
          "https://github.com/ross96D/flutter-ci/releases/download/engine%2Fdeb287481e3ce9468f3434937ced4240a70539ca/engine.release-small.tar.xz",
        ),
        releaseSmallEngine,
        progress.call,
      );
      progress.done();
      releaseSmallEngine.deleteSync();

      progress = _DownloadProgress('Downloading common files');
      final common = File('${tool.paths.waylandDir}/engine/common/common.tar.xz');
      common.createSync(recursive: true);
      await downloadAndUntar(
        Uri.parse(
          "https://github.com/ross96D/flutter-ci/releases/download/engine%2Fdeb287481e3ce9468f3434937ced4240a70539ca/common.tar.xz",
        ),
        common,
        progress.call,
      );
      progress.done();
      common.deleteSync();
    }
  }
}

Future<void> _checkBuildGraph(String waylandDir) async {
  final ProcessResult result;
  try {
    result = await Process.run(
      'zig',
      ['build', '--help'],
      workingDirectory: waylandDir,
    );
  } on ProcessException {
    throw ToolError('zig is not on PATH');
  }
  if (result.exitCode != 0) {
    final output = '${result.stdout}${result.stderr}'.trim();
    if (output.isNotEmpty) stderr.writeln(output);
    throw ToolError(
      'zig build --help failed with exit code ${result.exitCode}',
    );
  }
}

class _Identity {
  _Identity(this.name, this.fingerprint, this.changed);

  final String name;
  final String fingerprint;
  final bool changed;
}

_Identity _ensureIdentity(File manifest, String appName) {
  var text = manifest.readAsStringSync();
  var changed = false;

  final namePattern = RegExp(r'\.name\s*=\s*\.([A-Za-z0-9_]+)');
  var nameMatch = namePattern.firstMatch(text);
  var name = nameMatch?.group(1);
  if (name == null || name == 'filo_wayland_host') {
    name = _packageName(appName);
    if (nameMatch == null) {
      text = _insertAfterVersion(text, '.name = .$name,');
    } else {
      text = text.replaceRange(nameMatch.start, nameMatch.end, '.name = .$name');
    }
    changed = true;
  }

  final fingerprintPattern = RegExp(r'\.fingerprint\s*=\s*0x([0-9a-fA-F]+)');
  final fingerprintMatch = fingerprintPattern.firstMatch(text);
  var fingerprint = fingerprintMatch?.group(1);
  if (fingerprint == null || !_validFingerprint(name, fingerprint)) {
    fingerprint = _generateFingerprint(name);
    if (fingerprintMatch == null) {
      text = _insertAfterVersion(text, '.fingerprint = 0x$fingerprint,');
    } else {
      text = text.replaceRange(
        fingerprintMatch.start,
        fingerprintMatch.end,
        '.fingerprint = 0x$fingerprint',
      );
    }
    changed = true;
  }

  // The template used to ship a placeholder filo dependency. zig fetch
  // parses the manifest before adding the real URL/hash, so clear the
  // placeholder first.
  if (text.contains('<hash>') || text.contains('#<commit>')) {
    final placeholder = RegExp(
      r'\.dependencies\s*=\s*\.\{\s*\.filo\s*=\s*\.\{.*?\}\s*,?\s*\}\s*,',
      dotAll: true,
    );
    final replaced = text.replaceFirst(placeholder, '.dependencies = .{},');
    if (replaced == text) {
      throw ToolError(
        'could not clear the placeholder filo dependency from build.zig.zon',
      );
    }
    text = replaced;
    changed = true;
  }

  if (changed) manifest.writeAsStringSync(text);
  return _Identity(name, fingerprint, changed);
}

String _insertAfterVersion(String text, String field) {
  final versionLine = RegExp(
    r'^(\s*)\.version\s*=.*$',
    multiLine: true,
  ).firstMatch(text);
  if (versionLine == null) {
    throw ToolError('build.zig.zon has no .version field');
  }
  final indent = versionLine.group(1) ?? '    ';
  return text.replaceRange(
    versionLine.end,
    versionLine.end,
    '\n$indent$field',
  );
}

String _packageName(String appName) {
  var base = appName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  if (base.isEmpty || !RegExp(r'^[a-z_]').hasMatch(base)) {
    base = 'app_$base';
  }
  const suffix = '_wayland';
  if (base.length + suffix.length > 32) {
    base = base.substring(0, 32 - suffix.length);
  }
  return '$base$suffix';
}

bool _validFingerprint(String name, String hex) {
  final value = BigInt.tryParse(hex, radix: 16);
  if (value == null || value.isNegative || value.bitLength > 64) {
    return false;
  }
  final id = (value & BigInt.from(0xffffffff)).toInt();
  final checksum = (value >> 32).toInt() & 0xffffffff;
  return id != 0 && id != 0xffffffff && checksum == _crc32(name);
}

String _generateFingerprint(String name) {
  final checksum = _crc32(name);
  final id = Random.secure().nextInt(0xfffffffe) + 1;
  final value = (BigInt.from(checksum) << 32) | BigInt.from(id);
  return value.toRadixString(16).padLeft(16, '0');
}

int _crc32(String text) {
  var crc = 0xffffffff;
  for (final byte in utf8.encode(text)) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Future<void> downloadAndUntar(
  Uri url,
  File file,
  void Function(int received, int? total) onProgress,
) async {
  final client = HttpClient();
  final request = await client.getUrl(url);
  request.followRedirects = true;
  final response = await request.close();

  final total = response.contentLength > 0 ? response.contentLength : null;
  var received = 0;

  final sink = file.openWrite();
  try {
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      onProgress.call(received, total);
    }
  } finally {
    await sink.close();
    client.close();
  }

  final result = Process.runSync(
    "tar",
    [
      "-C",
      file.parent.path,
      "-xf",
      file.path,
    ],
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw ToolError("Fail to untar ${file.path}\n${result.stderr}");
  }
}

class _DownloadProgress {
  final String label;
  int _lastPercent = -1;
  int _lastLen = 0;

  _DownloadProgress(this.label);

  void call(int received, int? total) {
    final String line;
    if (total != null) {
      final percent = (received * 100 / total).floor();
      if (percent == _lastPercent) return; // don't repaint for every chunk
      _lastPercent = percent;

      const width = 30;
      final filled = (percent * width / 100).round();
      final bar = '${'█' * filled}${'░' * (width - filled)}';
      line = '$label [$bar] $percent%  ${_bytes(received)}/${_bytes(total)}';
    } else {
      line = '$label ${_bytes(received)}';
    }

    // Overwrite the previous line; pad with spaces to erase leftovers.
    final pad = max(0, _lastLen - line.length);
    stdout.write('\r$line${' ' * pad}');
    _lastLen = line.length;
  }

  void done() => stdout.writeln();

  static String _bytes(int n) {
    const units = ['B', 'KiB', 'MiB', 'GiB'];
    var v = n.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}
