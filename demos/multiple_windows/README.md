# multiple_windows

A reference application demonstrating multi-window support for Flutter using a
rich semantics windowing API.

## Running

The app has two native runners:

- `linux/` — the stock GTK runner, used by `flutter run -d linux` and by
  `flutter build linux`.
- `wayland/` — the filo runner, used by the project-aware `filo_wayland`
  custom device.

For the Wayland embedder, follow [`wayland/README.md`](wayland/README.md), then:

```sh
flutter run -d filo_wayland
```

If your Flutter branch still gates windowing behind a flag, add
`--enable-windowing`.
