//! filo: a Flutter embedder for Wayland, consumed as a Zig module.
//!
//! A host adds this package with `zig fetch`, imports the `filo` module and
//! calls `Runtime.init` / `Runtime.run` / `Runtime.deinit`. The embedder is
//! compiled into the host executable; there is no separate library artifact.
//!
//! The host executable must be built with `exe.rdynamic = true` (or link with
//! `--export-dynamic`) so the `filo_window_*` symbols stay in its dynamic
//! symbol table for the Dart windowing package.
//!
//! One process has one embedder: `Runtime.init` returns
//! `error.AlreadyInitialized` while another runtime is alive.

const std = @import("std");

const manifest = @import("manifest.zig");
const runtime = @import("runtime.zig");
pub const engine = @import("engine.zig");
pub const wl = @import("wayland").client.wl;

/// Runtime configuration: engine library, ICU data, Flutter assets and the
/// embedder's optional renderer/debug switches.
pub const Config = manifest.Config;

/// The embedder instance. Create it with `Runtime.init`, then call `run`.
pub const Runtime = runtime.Runtime;

test {
    _ = @import("manifest.zig");
    _ = @import("runtime.zig");
}
