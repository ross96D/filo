# multiwindow_demo

A second fembed demo that uses Flutter's public low-level multi-view API:

- `runWidget` + `ViewCollection` + one `View` per `FlutterView`
- `WidgetsBindingObserver.didChangeMetrics` to pick up view add/remove
- `MethodChannel('fembed/windows', JSONMethodCodec())` for window create/close

The initial window is the implicit Flutter view (id 0). "New window" asks the
embedder to open another Wayland window and add a Flutter view for it.

## Build

From this directory, using the `fembed` Flutter environment:

```sh
flutter pub get
flutter build bundle                 # JIT assets for ./run-multiwindow.sh debug
flutter build linux --release        # AOT libapp.so for ./run-multiwindow.sh release
```

## Run

From the repository root:

```sh
./run-multiwindow.sh debug
```

To open an extra window at startup without clicking:

```sh
FEMBED_EXTRA_WINDOWS=1 ./run-multiwindow.sh debug
```

Closing a secondary window removes its view. Closing the initial window (view 0)
exits, because the implicit view cannot be removed.
