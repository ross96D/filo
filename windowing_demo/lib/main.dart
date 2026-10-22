// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:filo_windowing/filo_windowing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

void main() {
  installFiloWindowing();
  runWidget(const WindowHost());
}

/// Owns one [RegularWindowController] per window and rebuilds the
/// [ViewCollection] when one is added or destroyed.
class WindowHost extends StatefulWidget {
  const WindowHost({super.key});

  @override
  State<WindowHost> createState() => _WindowHostState();
}

class _WindowHostState extends State<WindowHost> {
  final List<RegularWindowController> _windows = <RegularWindowController>[];

  @override
  void initState() {
    super.initState();
    _addWindow();
  }

  void _addWindow() {
    late final RegularWindowController controller;
    final delegate = _WindowDelegate(() => _removeWindow(controller));
    controller = RegularWindowController(
      size: const Size(720, 520),
      title: 'Filo window ${_windows.length + 1}',
      delegate: delegate,
    );
    setState(() => _windows.add(controller));
  }

  void _removeWindow(RegularWindowController controller) {
    if (!mounted) return;
    setState(() => _windows.remove(controller));
  }

  @override
  Widget build(BuildContext context) {
    return ViewCollection(
      views: <Widget>[
        for (final RegularWindowController controller in _windows)
          RegularWindow(
            controller: controller,
            child: WindowApp(
              index: _windows.indexOf(controller) + 1,
              onNewWindow: _addWindow,
              onClose: controller.destroy,
            ),
          ),
      ],
    );
  }
}

class _WindowDelegate with RegularWindowControllerDelegate {
  _WindowDelegate(this.onDestroyed);

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() => onDestroyed();
}

class WindowApp extends StatelessWidget {
  const WindowApp({
    super.key,
    required this.index,
    required this.onNewWindow,
    required this.onClose,
  });

  final int index;
  final VoidCallback onNewWindow;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Filo window $index',
      home: Scaffold(
        appBar: AppBar(title: Text('Filo window $index')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('view id: ${View.of(context).viewId}'),
              Text('size: ${size.width.round()} × ${size.height.round()}'),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onNewWindow,
                child: const Text('New window'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: onClose,
                child: const Text('Close window'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
