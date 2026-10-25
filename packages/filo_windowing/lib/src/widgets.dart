// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

import 'controllers.dart';

/// A widget that renders [child] into a wlr-layer-shell window.
///
/// Layer windows are a Filo extension to Flutter's windowing API, so this
/// widget complements [RegularWindow], [DialogWindow], [TooltipWindow] and
/// [PopupWindow]. It mirrors their contract: creating the controller creates
/// the native surface, and the caller destroys it when it is no longer needed.
///
/// Descendants can reach the controller through
/// `WindowScope.of(context) as FiloLayerWindowController`.
class FiloLayerWindow extends StatelessWidget {
  const FiloLayerWindow({
    super.key,
    required this.controller,
    required this.child,
  });

  /// The controller that owns the native layer surface.
  final FiloLayerWindowController controller;

  /// The content rendered into this window.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? widget) => WindowScope(
        controller: controller,
        child: View(view: controller.rootView, child: child),
      ),
    );
  }
}
