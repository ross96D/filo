# Backend contract

`FiloWindowingBackend` is the synchronous boundary between Flutter's windowing
controllers and the Filo embedder. The package never talks to Wayland, Vulkan,
or FFI directly.

## Synchronous creation

```dart
FiloWindowHandle createWindow(FiloWindowRequest request);
```

This method is called from the UI isolate. It must create the native window and
its Flutter view before returning.

The returned `viewId` must already be present in `PlatformDispatcher.views`:

```dart
final view = WidgetsBinding.instance.platformDispatcher.views
    .firstWhere((view) => view.viewId == handle.viewId);
```

If it is not, the controller factory throws a `StateError`. The package does not
use a placeholder view; a controller must have a real root view immediately.

The backend may return the implicit view (`viewId == 0`) from the first create
request when `request.preferredViewId == 0`. If it cannot adopt that view, it
may create a new view and return another id.

## Request fields

| Field | Meaning |
| --- | --- |
| `kind` | Regular, dialog, tooltip, popup, or satellite |
| `size` | Preferred logical content size; null means size to content |
| `constraints` | Logical min/max size constraints |
| `resizable` | Whether the user may resize after creation |
| `title` | Initial title |
| `parentViewId` | Parent window view id, if any |
| `preferredViewId` | Suggested view id to adopt (usually 0) |
| `anchorRect` | Tooltip/popup anchor in parent logical coordinates |
| `positioner` | Tooltip/popup placement |
| `initialAnchorRect` | Satellite initial anchor |
| `initialPositioner` | Satellite initial placement |

All `Size`, `Rect`, and `Offset` values are **logical pixels**. Convert to
physical or native coordinates in the backend using the view's device pixel
ratio.

## Handle fields

`FiloWindowHandle` carries the initial state so the controller can be fully
initialized before any event is delivered:

- `viewId`
- `kind`
- `contentSize`
- `title`
- `isActivated`
- `isMaximized`
- `isMinimized`
- `isFullscreen`
- `offsetFromParent` (popups)

Do not emit events for a new window during `createWindow`; return the initial
state in the handle instead. Events may be emitted after `createWindow` returns,
but not synchronously from inside it: the owner registers the controller only
after the call returns.

## Synchronous operations

The remaining methods are also synchronous:

- `destroyWindow`
- `setTitle`
- `setSize`
- `setConstraints`
- `activate`
- `setMaximized`
- `setMinimized`
- `setFullscreen`
- `updatePosition`
- `setParent`

They may enqueue native work, but they must not return a controller or a view id
that is not yet usable. For state that the compositor controls (maximized,
minimized, fullscreen, actual content size), report the real state through
events.

`destroyWindow` must be idempotent.

## Events

Events are emitted on `FiloWindowingBackend.events` and must be delivered on the
UI isolate.

### `FiloWindowCloseRequested`

The user or compositor asked the window to close. The package forwards this to
the controller's delegate. The backend must keep the window alive until Dart
calls `destroyWindow`.

The default delegates destroy immediately; an application can override them to
save state or cancel the close.

### `FiloWindowDestroyed`

The native window and its Flutter view are gone. Emit this for:

- destruction requested through `destroyWindow`
- external destruction
- parent-child cascade destruction

The controller marks itself destroyed and calls its delegate's
`onWindowDestroyed` exactly once.

### `FiloWindowStateChanged`

Fields that are null did not change. Emit this for title changes, activation
changes, maximized/minimized/fullscreen changes, content-size changes, and popup
offset changes.

For a popup, `offsetFromParent` is the popup's top-left corner relative to the
parent window's client area, in logical coordinates.

## Parent and child windows

The backend owns the native parent relationship:

- dialogs receive `parentViewId`
- tooltips and popups receive `parentViewId`
- satellites receive `parentViewId` and may later receive `setParent`

When a parent is destroyed, the backend must destroy its dependent children and
emit `FiloWindowDestroyed` for each of them. The package does not duplicate that
cascade in Dart.

## Threading

All backend methods are called on the UI isolate. Events must be added to the
stream on the UI isolate. If the native bridge receives callbacks on another
thread, marshal them to the UI isolate before adding an event.

## Error handling

Throw `FiloWindowingException` (or another exception) when a create operation
cannot complete. Controller factories propagate the exception to the caller.

If the backend creates a window but the package cannot resolve its view or
finish constructing the controller, the package calls `destroyWindow` for that
view before rethrowing.
