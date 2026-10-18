//! Aggregates unit tests that live under `src/` and `src/flutter/`.
//!
//! This file is the root of `zig build test`, so its directory (`src/`) is the
//! module root. That keeps `@import("../engine.zig")` from `src/flutter/*`
//! inside the module path.

test {
    _ = @import("clipboard.zig");
    _ = @import("flutter/codec.zig");
    _ = @import("flutter/platform_handler.zig");
    _ = @import("flutter/text_input.zig");
}
