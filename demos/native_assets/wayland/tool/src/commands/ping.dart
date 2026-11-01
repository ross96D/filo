import 'dart:io';

import '../tool.dart';

class PingCommand extends ToolCommand {
  @override
  String get name => 'ping';

  @override
  String get description => 'Check that the app can run on this Wayland host.';

  @override
  String get invocation => 'dart wayland/tool/wayland.dart ping';

  @override
  bool get takesArguments => false;

  @override
  void run() {
    final problems = <String>[];
    if (!File('${tool.paths.waylandDir}/build.zig').existsSync()) {
      problems.add('wayland/build.zig not found');
    }
    if ((Platform.environment['WAYLAND_DISPLAY'] ?? '').isEmpty) {
      problems.add('WAYLAND_DISPLAY is not set');
    }
    if ((Platform.environment['XDG_RUNTIME_DIR'] ?? '').isEmpty) {
      problems.add('XDG_RUNTIME_DIR is not set');
    }

    try {
      _checkBuildGraph(tool.paths.waylandDir);
    } on ToolError catch(e) {
      problems.add(e.message);
    }

    if (problems.isEmpty) return;
    for (final problem in problems) {
      stderr.writeln('$toolName: $problem');
    }
    exitCode = 1;
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
