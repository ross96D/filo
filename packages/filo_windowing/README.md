# filo_windowing

A Flutter `WindowingOwner` implementation for the **Filo** custom embedder.

This package adapts Flutter's experimental windowing API (Flutter 3.47,
`RegularWindowController` and friends) to an embedder that can create native
windows and Flutter views **synchronously**. It ships a native backend for the
Filo embedder's `filo_window_*` C ABI and owns the framework-side controllers,
state, delegates, and observer callbacks. A different embedder can inject its own
`FiloWindowingBackend`.

> **Experimental.** Flutter's windowing API is marked `@internal`, lives in
> `package:flutter/src/widgets/_window.dart`, and can change in any Flutter
> release. This package is pinned to the Flutter 3.47 API generation.

## Requirements

- Flutter `>=3.47.0 <3.48.0`
- An embedder backend that implements `FiloWindowingBackend`
- `FiloWindowingBackend.createWindow` must return only after the corresponding
  `FlutterView` is registered in `PlatformDispatcher.views`

## Enabling windowing

Flutter 3.47 ships the windowing code but its stable tool does not expose
`--enable-windowing`. `installFiloWindowing` sets the framework runtime flag
directly, which is appropriate for a custom embedder that owns the platform.

```dart
import 'package:filo_windowing/filo_windowing.dart';

void main() {
  installFiloWindowing(); // defaults to the native filo_window_* backend
  runWidget(/* ... */);
}
```

If you build with a Flutter tool where windowing is available, enabling the
feature in the normal way is still fine; installing the owner is idempotent.

## Using the windowing API

Flutter's windowing widgets and controllers are not exported by
`package:flutter/widgets.dart`. Import them explicitly:

```dart
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/widgets/_window.dart';
import 'package:filo_windowing/filo_windowing.dart';

void main() {
  installFiloWindowing();

  runWidget(
    RegularWindow(
      controller: RegularWindowController(
        size: const Size(800, 600),
        title: 'Filo',
      ),
      child: const MyApp(),
    ),
  );
}
```

The first regular controller adopts the implicit view (id 0) when
`reuseImplicitView` is `true` (the default) and the backend honors
`preferredViewId`. Set `reuseImplicitView: false` when the application already
renders into the implicit view separately.

## Window types

The regular, dialog, tooltip, and popup controller types are implemented:

- `RegularWindowController`
- `DialogWindowController`
- `TooltipWindowController`
- `PopupWindowController`

Satellite windows are rejected with `UnimplementedError`: core xdg-shell gives
a client no way to position or move an `xdg_toplevel`, so the satellite contract
(initial positioner, relative offset tracking, reparenting without moving)
cannot be honoured on Wayland.

### Size to content

`RegularWindowController.sizedToContent` and
`DialogWindowController.sizedToContent` are supported. The window is initially
sized from the frame Flutter renders, subject to the given constraints. A
non-resizable window keeps following later content changes; a resizable window
only uses its content for the initial size, after which the user controls the
size. Calling `setSize` leaves content-sizing mode and applies the requested
size.

### Layer windows

A layer window is a `zwlr_layer_shell_v1` surface: a bar, wallpaper, overlay, or
notification panel that the compositor places on an output according to its
layer, anchors, margins, and exclusive zone. Flutter's windowing API has no
layer type, so this package adds `FiloLayerWindowController` (a
`RegularWindowController` subtype) and the `FiloLayerWindow` widget. Construct
the controller through `FiloWindowingOwner.createLayerWindowController`; it does
not adopt the implicit view.

```dart
final owner = installFiloWindowing();

final panel = owner.createLayerWindowController(
  delegate: MyDelegate(),
  layerSurface: FiloLayerSurface(
    layer: FiloLayer.top,
    anchors:
        FiloLayerAnchors.top |
        FiloLayerAnchors.left |
        FiloLayerAnchors.right,
    exclusiveZone: 32,
    keyboardInteractivity: FiloLayerKeyboardInteractivity.onDemand,
    margin: const FiloInsets(top: 4, left: 8, right: 8),
    namespace: 'my-panel',
  ),
  // Zero width lets the compositor stretch the panel between the anchors;
  // a fixed height keeps it a bar.
  size: const Size(0, 32),
);

runWidget(
  ViewCollection(
    views: [
      FiloLayerWindow(controller: panel, child: const PanelApp()),
    ],
  ),
);
```

Sizes follow the protocol: a zero dimension is only valid when the surface is
anchored to both opposite edges, in which case the compositor chooses it. A
null `size` sizes the surface to its content by default (`sizedToContent`).
`FiloLayerSurface.output` selects an output by registry index, or -1 to let the
compositor choose. `FiloLayerSurface.acceptsInput` defaults to true; set it to
false for a wallpaper or overlay that should let pointer input reach the
desktop. The output and namespace are fixed at creation; the other properties
can be updated through the controller (`setLayer`, `setAnchors`, `setMargins`,
`setExclusiveZone`, `setKeyboardInteractivity`, `setAcceptsInput`, or
`updateLayerSurface`).

Keyboard interactivity `onDemand` requires wlr-layer-shell version 4; older
compositors report the update as an invalid argument. A compositor without
`zwlr_layer_shell_v1` reports create as unsupported. Layer surfaces are
presented with premultiplied alpha when the compositor supports it.

`Config.bootstrap_layer` chooses the role of the implicit view (id 0) before the
engine starts. It only affects view 0; it does not restrict the windows the app
may create. Choose it to match the app's first window: the current engine
integration reliably presents that bootstrap view, while a window of the other
kind created afterwards is allowed by the API but may not receive its first
frame yet.

For a layer-only app, set `Config.bootstrap_layer = true`
(`FILO_LAYER_ONLY=1` with the development runner sets it). Before starting the
engine, the embedder creates the layer surface described by
`Config.bootstrap_layer_surface` and adopts it as the implicit view. The first
layer controller should use the same layer, anchors, margins, size, and keyboard
interactivity; it then adopts that surface without reconfiguring it. Pass
`reuseImplicitView: false` to the owner (or set it on the controller) if the
first layer must get a fresh view instead.

The bootstrap defaults match the `windowing_demo` panel (top layer, anchored
top-right, 8px top/right margin, 300×300). Hosts with a different panel should
set `Config.bootstrap_layer_surface` so the first controller does not have to
reconfigure the surface.

Without `bootstrap_layer`, the embedder bootstraps a toplevel and the first
regular window adopts it. This is the engine's startup frame path.

The backend is responsible for the native archetypes: top-level windows,
dialogs, popups, tooltips, and layer surfaces. Sizes, constraint adjustments,
and anchor rectangles are passed through as package-owned values, so a backend
does not need to import Flutter's private windowing types.

## Backend contract

See [doc/backend.md](doc/backend.md) for the full contract. In short:

- `createWindow` is synchronous.
- The returned view id must already resolve to a `FlutterView`.
- The backend invokes `FiloWindowObserver` callbacks synchronously on the UI
  isolate, and `onDestroy` is the last callback for a window.
- Compositor close requests are not automatic destroys; the controller's
  delegate decides.
- The backend must call `onDestroy` for requested and external destruction.

A fake backend lives under `test/support/` and can be used as a reference for
implementing another bridge.

## Callbacks

There is no event stream. The native callbacks go straight to the controller:

```
onClose   -> controller -> delegate.onWindowCloseRequested(this)
onDestroy -> controller -> delegate.onWindowDestroyed()
```

`onConfigure`/`onStateChanged`/`onCapabilitiesChanged`/`onMoved`/`onTitleChanged`
update the controller's cached state and call `notifyListeners()`. Creating a
window from inside a callback calls back into the engine synchronously; defer it
with `scheduleMicrotask` or a post-frame callback.

## Native backend

`FiloNativeBackend` binds the `filo_window_*` symbols the Filo embedder exports
from its process image. The embedder must link with its dynamic symbols exported
(`rdynamic` in the Zig build). `installFiloWindowing()` uses it by default; pass
`backend:` to install a different implementation.

The repository's `windowing_demo/` is a small app that runs the package against
the embedder.

## API

| Type | Purpose |
| --- | --- |
| `FiloWindowingOwner` | The `WindowingOwner` implementation |
| `installFiloWindowing` | Creates, enables, and installs the owner |
| `FiloWindowingBackend` | Synchronous native bridge |
| `FiloWindowRequest` / `FiloWindowHandle` | Create request and initial state |
| `FiloWindowObserver` | Synchronous per-window callbacks |
| `FiloPositioner` and related types | Backend-facing positioner values |
| `FiloLayerSurface` | Layer, anchors, margins, exclusive zone, keyboard mode |
| `FiloLayerWindowController` | Controller for a wlr-layer-shell window |
| `FiloLayerWindow` | Widget that renders a layer window |
| `FiloWindowingException` | Backend operation failure |

## Development

```sh
cd packages/filo_windowing
flutter pub get
flutter analyze
flutter test
```
