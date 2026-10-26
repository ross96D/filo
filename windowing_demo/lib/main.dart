// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:io';

import 'package:filo_windowing/filo_windowing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

void main() {
  final owner = installFiloWindowing();
  runWidget(WindowHost(owner: owner));
}

/// Owns one [RegularWindowController] per window and rebuilds the
/// [ViewCollection] when one is added or destroyed.
class WindowHost extends StatefulWidget {
  const WindowHost({super.key, required this.owner});

  final FiloWindowingOwner owner;

  @override
  State<WindowHost> createState() => _WindowHostState();
}

class _WindowHostState extends State<WindowHost> {
  final List<RegularWindowController> _windows = <RegularWindowController>[];
  FiloLayerWindowController? _layer;

  @override
  void initState() {
    super.initState();
    if (Platform.environment['FILO_LAYER_ONLY'] == '1') {
      _toggleLayer();
    } else {
      _addWindow();
    }
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

  void _toggleLayer() {
    final current = _layer;
    if (current != null) {
      setState(() => _layer = null);
      current.destroy();
      return;
    }

    final controller = widget.owner.createLayerWindowController(
      delegate: _LayerDelegate(() {
        if (!mounted) return;
        setState(() => _layer = null);
      }),
      layerSurface: FiloLayerSurface(
        // Keep this in sync with filo's Config.layer_bootstrap defaults: the
        // embedder creates this surface before Dart starts, and the controller
        // adopts it without reconfiguring it.
        layer: FiloLayer.top,
        anchors: FiloLayerAnchors.top | FiloLayerAnchors.right,
        keyboardInteractivity: FiloLayerKeyboardInteractivity.onDemand,
        margin: const FiloInsets(top: 8, right: 8),
        namespace: 'filo',
      ),
      size: const Size(300, 300),
    );
    setState(() => _layer = controller);
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
              onToggleLayer: _toggleLayer,
              onClose: controller.destroy,
            ),
          ),
        if (_layer case final layer?)
          FiloLayerWindow(
            controller: layer,
            child: LayerPanel(onClose: _toggleLayer),
          ),
      ],
    );
  }
}

class _LayerDelegate with RegularWindowControllerDelegate {
  _LayerDelegate(this.onDestroyed);

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() => onDestroyed();
}

class LayerPanel extends StatelessWidget {
  const LayerPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      debugShowMaterialGrid: false,
      theme: ThemeData.light(useMaterial3: true),
      home: Material(
        color: const Color(0xff202124),
        child: Padding(
          padding: const EdgeInsets.all(0),
          child: Column(
            spacing: 10,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Text(
                'Layer surface',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              const Text(
                'top layer, anchored top-right',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              FilledButton(
                style: ButtonStyle(visualDensity: VisualDensity(horizontal: 0, vertical: 0)),
                onPressed: onClose,
                child: const Text('Close panel'),
              ),
            ],
          ),
        ),
      ),
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
    required this.onToggleLayer,
    required this.onClose,
  });

  final int index;
  final VoidCallback onNewWindow;
  final VoidCallback onToggleLayer;
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
                onPressed: onToggleLayer,
                child: const Text('Toggle layer panel'),
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
