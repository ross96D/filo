const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate Zig bindings for the core Wayland protocol, xdg-shell, the
    // cursor shapes the mouse cursor platform channel sets, wlr-layer-shell
    // for layer windows, and xdg-activation for requesting window activation.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("vendor/protocols/wayland.xml"),
        .wayland_protocols = b.path("vendor/protocols"),
    });
    scanner.addCustomProtocol(b.path("vendor/protocols/xdg-shell.xml"));
    scanner.addCustomProtocol(b.path("vendor/protocols/cursor-shape-v1.xml"));
    scanner.addCustomProtocol(b.path("vendor/protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("vendor/protocols/xdg-activation-v1.xml"));
    scanner.generate("wl_compositor", 6);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("wl_output", 4);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("xdg_activation_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const flutter_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/flutter/flutter_embedder.h"),
        .target = target,
        .optimize = optimize,
    });
    const flutter = flutter_c.createModule();

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.path("vendor/protocols/vk.xml"),
    }).module("vulkan-zig");

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/xkb/xkb.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.addIncludePath(b.path("vendor/xkb"));
    const xkb = xkb_c.createModule();

    // The package's public module. Consumers fetch the package and import this
    // module; they statically compile it into their own executable. libc and
    // the system libraries are set here so importing the module is enough.
    const filo_mod = b.addModule("filo", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    filo_mod.addImport("wayland", wayland);
    filo_mod.addImport("flutter", flutter);
    filo_mod.addImport("vulkan", vulkan);
    filo_mod.addImport("xkb", xkb);
    filo_mod.addImport("zio", zio.module("zio"));
    filo_mod.linkSystemLibrary("wayland-client", .{});
    filo_mod.linkSystemLibrary("xkbcommon", .{});

    // The development runner, checks, formatting and tests belong to the
    // package when it is the root. As a fetched dependency, filo only provides
    // `module("filo")`.
    if (!b.isRoot()) return;

    const exe = b.addExecutable(.{
        .name = "filo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("filo", filo_mod);

    // `src/windowing.zig` exports the `filo_window_*` C ABI. Dart reaches it
    // through `DynamicLibrary.executable()`, which needs the symbols in the
    // executable's dynamic symbol table. A consumer's host exe needs the same
    // setting.
    exe.rdynamic = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run filo");
    run_step.dependOn(&run_cmd.step);

    // `zig build check`: verify the build and that source is formatted.
    const check_step = b.step("check", "Check formatting and that the project compiles");
    check_step.dependOn(&exe.step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src") },
        .check = true,
    });
    check_step.dependOn(&fmt_check.step);

    // `zig build fmt`: format source in place.
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src") },
    });
    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);

    // `zig build test`: run unit tests.
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("flutter", flutter);
    unit_tests.root_module.addImport("xkb", xkb);
    unit_tests.root_module.addImport("vulkan", vulkan);
    unit_tests.root_module.addImport("wayland", wayland);
    unit_tests.root_module.addImport("zio", zio.module("zio"));
    unit_tests.root_module.linkSystemLibrary("wayland-client", .{});
    unit_tests.root_module.linkSystemLibrary("xkbcommon", .{});
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
    check_step.dependOn(&unit_tests.step);
}
