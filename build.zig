const std = @import("std");

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate Zig bindings for the core Wayland protocol and xdg-shell.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("vendor/protocols/wayland.xml"),
        .wayland_protocols = b.path("vendor/protocols"),
    });
    scanner.addCustomProtocol(b.path("vendor/protocols/xdg-shell.xml"));
    scanner.generate("wl_compositor", 5);
    scanner.generate("xdg_wm_base", 6);
    scanner.generate("wl_seat", 8);
    scanner.generate("wl_data_device_manager", 3);

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

    const xkb_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/xkb/xkb.h"),
        .target = target,
        .optimize = optimize,
    });
    xkb_c.addIncludePath(b.path("vendor/xkb"));
    const xkb = xkb_c.createModule();

    const exe = b.addExecutable(.{
        .name = "fembed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("flutter", flutter);
    exe.root_module.addImport("vulkan", vulkan);
    exe.root_module.addImport("xkb", xkb);
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run fembed");
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
    unit_tests.root_module.addImport("wayland", wayland);
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
