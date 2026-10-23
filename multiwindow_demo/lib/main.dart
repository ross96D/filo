import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cute_mascot.dart';

/// Window lifecycle requests to the embedder. The replies are acknowledgements
/// only; a new [FlutterView] shows up through `didChangeMetrics`.
const MethodChannel _windows = MethodChannel(
  'filo/windows',
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
      title: 'filo view $viewId',
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

  void _boop() {
    setState(() => _clicks++);
    print('[multiwindow] view ${widget.viewId} tap $_clicks');
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final bool isPrimary = widget.viewId == 0;
    final _WindowPalette palette = _WindowPalette.forView(widget.viewId);
    final Color muted = palette.ink.withValues(alpha: 0.55);

    return Scaffold(
      backgroundColor: palette.background.colors.first,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.background),
        child: Stack(
          children: <Widget>[
            Positioned(
              top: -120,
              right: -80,
              child: _Halo(
                size: 280,
                color: palette.halo.withValues(alpha: 0.4),
              ),
            ),
            Positioned(
              bottom: -150,
              left: -100,
              child: _Halo(
                size: 320,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _ViewBadge(
                          viewId: widget.viewId,
                          isPrimary: isPrimary,
                          palette: palette,
                        ),
                        Stack(
                          alignment: Alignment.center,
                          children: <Widget>[
                            Container(
                              width: 188,
                              height: 188,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: <Color>[
                                    Colors.white.withValues(alpha: 0.6),
                                    Colors.white.withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                            CuteMascot(
                              accent: palette.accent,
                              ink: palette.ink,
                              burst: _clicks,
                              onTap: _boop,
                            ),
                          ],
                        ),
                        Text(
                          'filo view ${widget.viewId}',
                          style: TextStyle(
                            color: palette.ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'size ${size.width.round()} × ${size.height.round()}'
                          '  ·  dpr ${dpr.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: muted,
                            fontSize: 11,
                            letterSpacing: 0.3,
                          ),
                        ),
                        if (isPrimary) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            'This is the implicit view. '
                            'Closing it exits the app.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: palette.ink.withValues(alpha: 0.42),
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        TextField(
                          controller: _controller,
                          cursorColor: palette.accentDeep,
                          style: TextStyle(color: palette.ink, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'say something nice...',
                            hintStyle: TextStyle(
                              color: palette.ink.withValues(alpha: 0.35),
                              fontSize: 13,
                            ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.75),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 13,
                            ),
                            prefixIcon: Icon(
                              Icons.favorite_outline_rounded,
                              size: 17,
                              color: palette.accent,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 42,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: palette.accent,
                                width: 1.6,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'clicks: $_clicks',
                          style: TextStyle(
                            color: muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: <Widget>[
                            FilledButton.icon(
                              onPressed: _boop,
                              icon: const Icon(
                                Icons.favorite_rounded,
                                size: 15,
                              ),
                              label: const Text('Click me'),
                              style: FilledButton.styleFrom(
                                backgroundColor: palette.accent,
                                foregroundColor: palette.accentDeep,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                shape: const StadiumBorder(),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _newWindow,
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: const Text('New window'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: palette.accentDeep,
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.6,
                                ),
                                side: BorderSide(
                                  color: palette.accent.withValues(alpha: 0.5),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                shape: const StadiumBorder(),
                                textStyle: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        TextButton.icon(
                          onPressed: _busy ? null : _closeWindow,
                          icon: Icon(
                            isPrimary
                                ? Icons.logout_rounded
                                : Icons.close_rounded,
                            size: 15,
                          ),
                          label: Text(isPrimary ? 'Exit app' : 'Close window'),
                          style: TextButton.styleFrom(
                            foregroundColor: muted,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'view id: ${View.of(context).viewId}',
                          style: TextStyle(
                            color: palette.ink.withValues(alpha: 0.36),
                            fontSize: 10,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pill that labels each window.
class _ViewBadge extends StatelessWidget {
  const _ViewBadge({
    required this.viewId,
    required this.isPrimary,
    required this.palette,
  });

  final int viewId;
  final bool isPrimary;
  final _WindowPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: palette.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            isPrimary ? 'view $viewId  ·  implicit' : 'view $viewId',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: palette.ink.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft, blurred-looking background circle. Purely decorative.
class _Halo extends StatelessWidget {
  const _Halo({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

/// Pastel palette for one window. Each view nudges the hue, so several windows
/// are easy to tell apart while all of them stay light and soft.
class _WindowPalette {
  const _WindowPalette({
    required this.accent,
    required this.accentDeep,
    required this.ink,
    required this.halo,
    required this.background,
  });

  factory _WindowPalette.forView(int viewId) {
    // A curated loop of soft hues: pink, peach, mint, lavender, sky, lemon.
    const List<double> hues = <double>[338, 22, 158, 268, 202, 46, 300];
    final double hue = hues[viewId % hues.length];
    return _WindowPalette(
      accent: HSLColor.fromAHSL(1, hue, 0.74, 0.74).toColor(),
      accentDeep: HSLColor.fromAHSL(1, hue, 0.58, 0.4).toColor(),
      ink: const Color(0xFF51445E),
      halo: HSLColor.fromAHSL(1, hue, 0.85, 0.86).toColor(),
      background: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          HSLColor.fromAHSL(1, (hue + 24) % 360, 0.85, 0.975).toColor(),
          HSLColor.fromAHSL(1, (hue + 310) % 360, 0.75, 0.93).toColor(),
        ],
      ),
    );
  }

  final Color accent;
  final Color accentDeep;
  final Color ink;
  final Color halo;
  final LinearGradient background;
}
