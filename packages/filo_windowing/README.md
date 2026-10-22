# filo_windowing

A Flutter `WindowingOwner` implementation for the **Filo** custom embedder.

This package adapts Flutter's experimental windowing API (Flutter 3.47,
`RegularWindowController` and friends) to an embedder that can create native
windows and Flutter views **synchronously**. The embedder supplies a
`FiloWindowingBackend`; this package owns the framework-side controllers,
state, delegates, and events.

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
  final owner = installFiloWindowing(backend: myBackend);
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
  installFiloWindowing(backend: myBackend);

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

All five framework controller types are implemented:

- `RegularWindowController`
- `DialogWindowController`
- `TooltipWindowController`
- `PopupWindowController`
- `SatelliteWindowController`

The backend is responsible for the native archetypes: top-level windows,
dialogs, popups, tooltips, and satellites. Sizes, constraint adjustments, and
anchor rectangles are passed through as package-owned values, so a backend does
not need to import Flutter's private windowing types.

## Backend contract

See [doc/backend.md](doc/backend.md) for the full contract. In short:

- `createWindow` is synchronous.
- The returned view id must already resolve to a `FlutterView`.
- Events are delivered on the UI isolate.
- Compositor close requests are not automatic destroys; the controller's
  delegate decides.
- The backend must emit `FiloWindowDestroyed` for requested and external
  destruction.

A fake backend and fake views live under `test/support/` and can be used as a
reference for implementing the real bridge.

## API

| Type | Purpose |
| --- | --- |
| `FiloWindowingOwner` | The `WindowingOwner` implementation |
| `installFiloWindowing` | Creates, enables, and installs the owner |
| `FiloWindowingBackend` | Synchronous native bridge |
| `FiloWindowRequest` / `FiloWindowHandle` | Create request and result |
| `FiloWindowEvent` and subclasses | Close, destroy, and state events |
| `FiloWindowPositioner` and related types | Backend-facing positioner values |
| `FiloWindowingException` | Backend operation failure |

## Development

```sh
cd packages/filo_windowing
flutter pub get
flutter analyze
flutter test
```
