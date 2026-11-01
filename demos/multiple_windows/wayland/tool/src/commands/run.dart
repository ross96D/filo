import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../tool.dart';

class RunCommand extends ToolCommand {
  // The host forwards everything after `run` to Dart's main(List<String> args),
  // so the command must not try to interpret those arguments as its own.
  final _passthrough = ArgParser.allowAnything();

  @override
  String get name => 'run';

  @override
  String get description => 'Stage the debug bundle and run the host.';

  @override
  String get invocation => 'dart wayland/tool/wayland.dart run [dart arguments...]';

  @override
  ArgParser get argParser => _passthrough;

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    final appName = tool.appName();
    final bundle = tool.stageDebugBundle(appName: appName);
    await startAndWait(
      p.join(bundle, appName),
      args,
      workingDirectory: tool.paths.appRoot,
    );
  }
}

Future<void> startAndWait(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
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
    throw ToolError('failed to run $executable');
  }

  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  void forward(ProcessSignal signal) {
    try {
      subscriptions.add(
        signal.watch().listen((_) {
          process.kill(signal);
        }),
      );
    } on SignalException {
      // Signal is not supported on this platform; ignore it.
    }
  }

  forward(ProcessSignal.sigterm);
  forward(ProcessSignal.sigint);
  forward(ProcessSignal.sighup);

  final code = await process.exitCode;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  if (code != 0) {
    exitCode = code < 0 ? 128 - code : code;
  }
}
