import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Window lifecycle requests to the embedder. The replies are acknowledgements
/// only; a new [FlutterView] shows up through `didChangeMetrics`.
const MethodChannel _windows = MethodChannel(
  'fembed/windows',
  JSONMethodCodec(),
);

void main() {
  print('[multiwindow] main() entrypoint reached');
  runWidget(const MultiWindowApp());
}

/// The root of the app is not rendered into a view itself. It owns one [View]
/// per [FlutterView] the engine has told the framework about.
class MultiWindowApp extends StatefulWidget {
  const MultiWindowApp({super.key});

  @override
  State<MultiWindowApp> createState() => _MultiWindowAppState();
}

class _MultiWindowAppState extends State<MultiWindowApp>
    with WidgetsBindingObserver {
  /// The set of view ids currently attached. Used to tell a window being added
  /// or removed (which needs a rebuild to attach/detach a [View]) from a window
  /// being resized (which the [View] handles itself and must not rebuild for).
  Set<int> _viewIds = <int>{};

  @override
  void initState() {
    super.initState();
    _viewIds = _currentViewIds();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Set<int> _currentViewIds() => <int>{
    for (final FlutterView view
        in WidgetsBinding.instance.platformDispatcher.views)
      view.viewId,
  };

  @override
  void didChangeMetrics() {
    // The engine adds and removes views through PlatformDispatcher._addView and
    // _removeView, both of which call onMetricsChanged, so this is the only
    // notification for them. Rebuild the collection then, so the [View] is
    // attached or detached. A resize also lands here, once per frame of a drag,
    // but it leaves the set of views unchanged and the [View] updates itself:
    // rebuilding the whole collection for it would only add jank.
    final Set<int> ids = _currentViewIds();
    if (ids.length == _viewIds.length && ids.containsAll(_viewIds)) return;
    _viewIds = ids;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return ViewCollection(
      views: <Widget>[
        for (final FlutterView view in views)
          View(
            key: ValueKey<int>(view.viewId),
            view: view,
            child: WindowApp(viewId: view.viewId),
          ),
      ],
    );
  }
}

class WindowApp extends StatelessWidget {
  const WindowApp({super.key, required this.viewId});

  final int viewId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'fembed view $viewId',
      home: WindowPage(viewId: viewId),
    );
  }
}

class WindowPage extends StatefulWidget {
  const WindowPage({super.key, required this.viewId});

  final int viewId;

  @override
  State<WindowPage> createState() => _WindowPageState();
}

class _WindowPageState extends State<WindowPage> {
  final TextEditingController _controller = TextEditingController();
  int _clicks = 0;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _newWindow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _windows.invokeMethod<void>('create', <String, Object>{
        'width': 800,
        'height': 600,
      });
      print('[multiwindow] asked for a new window from view ${widget.viewId}');
    } on PlatformException catch (error) {
      print('[multiwindow] create failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeWindow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _windows.invokeMethod<void>('close', <String, Object>{
        'viewId': widget.viewId,
      });
      print('[multiwindow] asked to close view ${widget.viewId}');
    } on PlatformException catch (error) {
      print('[multiwindow] close failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final bool isPrimary = widget.viewId == 0;
    return Scaffold(
      backgroundColor: isPrimary
          ? const Color(0xFF223355)
          : const Color(0xFF2F4A3A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: <Widget>[
              Text(
                'fembed view ${widget.viewId}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'size ${size.width.round()}x${size.height.round()} @ ${dpr.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              if (isPrimary)
                const Text(
                  'This is the implicit view. Closing it exits the app.',
                  style: TextStyle(color: Colors.white54, fontSize: 10),
                ),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'type here...',
                    hintStyle: TextStyle(color: Colors.white38),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                    ),
                  ),
                ),
              ),
              Text(
                'clicks: $_clicks',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: () {
                      setState(() => _clicks++);
                      print(
                        '[multiwindow] view ${widget.viewId} tap $_clicks',
                      );
                    },
                    child: const Text('Click me'),
                  ),
                  ElevatedButton(
                    onPressed: _busy ? null : _newWindow,
                    child: const Text('New window'),
                  ),
                  ElevatedButton(
                    onPressed: _busy ? null : _closeWindow,
                    child: Text(isPrimary ? 'Exit app' : 'Close window'),
                  ),
                ],
              ),
              Text(
                'view id: ${View.of(context).viewId}',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
