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
| `kind` | `toplevel` or `popup` |
| `size` | Preferred logical content size; null means size to content |
| `constraints` | Logical min/max size constraints |
| `resizable` | Whether the user may resize after creation |
| `sizedToContent` | Hint that the window should track its content |
| `modal` | Whether a dialog is modal to `parentViewId` |
| `decorated` | Whether the window has decorations |
| `title` | Initial title |
| `parentViewId` | Parent window view id, or -1 |
| `preferredViewId` | Suggested view id to adopt (usually 0), or -1 |
| `positioner` | Popup/tooltip placement, including its anchor rect |

All `Size`, `Rect`, and `Offset` values are **logical pixels**. Convert to
physical or native coordinates in the backend using the view's device pixel
ratio.

## Handle fields

`FiloWindowHandle` carries the initial state so the controller can be fully
initialized before any callback is delivered:

- `viewId`
- `contentSize`
- `title`
- `toplevelState` (the `xdg_toplevel.state` bitmask)
- `wmCapabilities` (the `xdg_toplevel.wm_capabilities` bitmask)
- `offsetFromParent` (popups)

Do not invoke observer callbacks for a new window during `createWindow`; return
the initial state in the handle instead. Callbacks may be invoked once
`observe` has returned.

## Observing a window

```dart
void observe(int viewId, FiloWindowObserver observer);
```

`observe` registers the callbacks for a window returned by `createWindow`. The
controller calls it immediately after construction, before the current UI task
returns.

The callbacks are invoked **synchronously on the UI isolate**, on the thread
that owns the windowing loop. `FiloWindowObserver` carries the values:

| Callback | Meaning |
| --- | --- |
| `onConfigure(Size)` | The compositor configured a new logical content size |
| `onStateChanged(int)` | The `xdg_toplevel.state` bitmask changed |
| `onCapabilitiesChanged(int)` | The `xdg_toplevel.wm_capabilities` bitmask changed |
| `onTitleChanged(String)` | The title changed |
| `onMoved(Offset)` | A popup moved, relative to its parent |
| `onClose()` | A close was requested; the window is still alive |
| `onDestroy()` | The native window and its Flutter view are gone |

`onDestroy` is the last callback for a window; after it returns the backend may
release the native callables.

Creating a window from inside a callback calls back into the engine
synchronously. Defer it with `scheduleMicrotask` or a post-frame callback.
`destroyWindow`, `setTitle`, `setSize`, and `notifyListeners` are safe.

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
minimized, fullscreen, actual content size), report the real state through the
observer.

`destroyWindow` must be idempotent.

## Close and destroy

### `onClose`

The user or compositor asked the window to close. The package forwards this to
the controller's delegate. The backend must keep the window alive until Dart
calls `destroyWindow`.

The default delegates destroy immediately; an application can override them to
save state or cancel the close.

### `onDestroy`

The native window and its Flutter view are gone. Invoke this for:

- destruction requested through `destroyWindow`
- external destruction
- parent-child cascade destruction

The controller marks itself destroyed and calls its delegate's
`onWindowDestroyed` exactly once.

## Parent and child windows

The backend owns the native parent relationship:

- dialogs receive `parentViewId`
- tooltips and popups receive `parentViewId`
- satellites receive `parentViewId` and may later receive `setParent`

When a parent is destroyed, the backend must destroy its dependent children and
invoke `onDestroy` for each of them. The package does not duplicate that cascade
in Dart.

## Threading

All backend methods and observer callbacks run on the UI isolate. If the native
bridge receives callbacks on another thread, marshal them to the UI isolate
before invoking the observer.

## Error handling

Throw `FiloWindowingException` (or another exception) when a create operation
cannot complete. Controller factories propagate the exception to the caller.

If the backend creates a window but the package cannot resolve its view or
finish constructing the controller, the package calls `destroyWindow` for that
view before rethrowing.
