//! Conversion between logical and physical pixels.
//!
//! Wayland surface-local coordinates, xdg-shell geometry, layer-shell margins
//! and the Dart windowing API all use logical pixels. The Flutter embedder ABI
//! (`FlutterWindowMetricsEvent`, `FlutterPointerEvent`, `FlutterEngineDisplay`)
//! uses physical pixels. This module is the only place that converts between
//! the two.
//!
//! The embedder implements HiDPI by picking an integer buffer scale (`1` or
//! `ceil(preferred_scale)`) and attaching a buffer of `logical * ratio` pixels.
//! Wayland maps that buffer back onto the same surface-local rectangle, so a
//! window's logical size never changes when the scale does.

const std = @import("std");

/// The denominator of the `wp_fractional_scale_v1` preferred scale. Kept here
/// so a future fractional implementation shares the same rounding rules.
pub const preferred_scale_denominator: f64 = 120.0;

/// Decode a `wp_fractional_scale_v1` preferred scale (`180` means 1.5).
pub fn ratioFromPreferred(preferred: u32) f64 {
    return @as(f64, @floatFromInt(preferred)) / preferred_scale_denominator;
}

/// The smallest integer buffer scale that can represent `ratio`, never below 1.
///
/// `wl_surface.set_buffer_scale` is integral. A compositor asking for 1.5 gets
/// a 2x buffer, which the compositor downsamples when compositing; `wl_output`
/// already rounds its own `scale` event up the same way.
pub fn integral(ratio: f64) u32 {
    if (!(ratio > 0)) return 1;
    const rounded: u32 = @intFromFloat(@ceil(ratio));
    return @max(1, rounded);
}

/// A logical length in physical pixels. Zero is preserved (it means "no
/// size"/"unbounded" in the constraint encoding); everything else rounds up so
/// the attached buffer is never smaller than the logical content.
pub fn physical(logical_length: u32, ratio: f64) u32 {
    if (logical_length == 0 or !(ratio > 0)) return 0;
    const scaled = @as(f64, @floatFromInt(logical_length)) * ratio;
    return @max(1, @as(u32, @intFromFloat(@ceil(scaled))));
}

/// A physical length in logical pixels. Zero is preserved; everything else
/// rounds to the nearest logical pixel and is never zero.
pub fn logical(physical_length: u32, ratio: f64) u32 {
    if (physical_length == 0 or !(ratio > 0)) return 0;
    const scaled = @as(f64, @floatFromInt(physical_length)) / ratio;
    return @max(1, @as(u32, @intFromFloat(@round(scaled))));
}

/// A logical pointer coordinate in physical pixels.
pub fn physicalCoord(logical_coord: f64, ratio: f64) f64 {
    if (!(ratio > 0)) return logical_coord;
    return logical_coord * ratio;
}

test "preferred scale is a fraction over 120" {
    try std.testing.expectEqual(@as(f64, 1.0), ratioFromPreferred(120));
    try std.testing.expectEqual(@as(f64, 1.5), ratioFromPreferred(180));
    try std.testing.expectEqual(@as(f64, 2.0), ratioFromPreferred(240));
}

test "integer buffer scale rounds fractional scales up" {
    try std.testing.expectEqual(@as(u32, 1), integral(0));
    try std.testing.expectEqual(@as(u32, 1), integral(1.0));
    try std.testing.expectEqual(@as(u32, 2), integral(1.25));
    try std.testing.expectEqual(@as(u32, 2), integral(1.5));
    try std.testing.expectEqual(@as(u32, 2), integral(2.0));
    try std.testing.expectEqual(@as(u32, 3), integral(2.25));
}

test "logical and physical sizes convert in both directions" {
    try std.testing.expectEqual(@as(u32, 800), physical(800, 1.0));
    try std.testing.expectEqual(@as(u32, 1200), physical(800, 1.5));
    try std.testing.expectEqual(@as(u32, 1600), physical(800, 2.0));

    // A buffer is never smaller than the logical content.
    try std.testing.expectEqual(@as(u32, 1202), physical(801, 1.5));
    try std.testing.expectEqual(@as(u32, 801), logical(1202, 1.5));
    try std.testing.expectEqual(@as(u32, 800), logical(1200, 1.5));
    try std.testing.expectEqual(@as(u32, 800), logical(1600, 2.0));

    // Zero means "no size" and survives the round trip.
    try std.testing.expectEqual(@as(u32, 0), physical(0, 2.0));
    try std.testing.expectEqual(@as(u32, 0), logical(0, 2.0));

    // Rounding never produces zero for a valid physical length.
    try std.testing.expectEqual(@as(u32, 1), logical(1, 2.0));
}

test "pointer coordinates scale by the buffer ratio" {
    try std.testing.expectEqual(@as(f64, 450.0), physicalCoord(450.0, 1.0));
    try std.testing.expectEqual(@as(f64, 675.0), physicalCoord(450.0, 1.5));
    try std.testing.expectEqual(@as(f64, 900.0), physicalCoord(450.0, 2.0));
    try std.testing.expectEqual(@as(f64, 12.5), physicalCoord(12.5, 1.0));
}
