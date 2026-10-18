const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    wm_base: *xdg.WmBase,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    buffer: *wl.Buffer,
    pool: *wl.ShmPool,
    fd: posix.fd_t,
    data: []align(std.heap.page_size_min) u8,
    running: bool = true,
    configured: bool = false,

    pub fn create(allocator: std.mem.Allocator, width: u32, height: u32) !*Window {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();

        var globals = Globals{};
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoCompositor;
        const shm = globals.shm orelse return error.NoShm;
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;

        const buffer_and_fd = try createSolidBuffer(shm, width, height);
        const buffer = buffer_and_fd.buffer;
        errdefer buffer.destroy();
        const pool = buffer_and_fd.pool;
        errdefer pool.destroy();
        const fd = buffer_and_fd.fd;
        const data = buffer_and_fd.data;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setTitle("fembed");

        const self = try allocator.create(Window);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .shm = shm,
            .wm_base = wm_base,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .buffer = buffer,
            .pool = pool,
            .fd = fd,
            .data = data,
        };

        xdg_surface.setListener(*Window, xdgSurfaceListener, self);
        toplevel.setListener(*Window, toplevelListener, self);

        surface.commit();

        return self;
    }

    /// Blocking dispatch loop until the window is closed.
    pub fn run(self: *Window) !void {
        while (self.running) {
            if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
    }

    pub fn destroy(self: *Window) void {
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.buffer.destroy();
        self.pool.destroy();
        posix.munmap(self.data);
        _ = std.os.linux.close(self.fd);
        self.shm.destroy();
        self.compositor.destroy();
        self.wm_base.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    const BufferAndFd = struct {
        buffer: *wl.Buffer,
        pool: *wl.ShmPool,
        fd: posix.fd_t,
        data: []align(std.heap.page_size_min) u8,
    };

    fn createSolidBuffer(shm: *wl.Shm, width: u32, height: u32) !BufferAndFd {
        const stride = width * 4;
        const size: usize = @as(usize, stride) * height;

        const fd = try posix.memfd_create("fembed", 0);
        errdefer _ = std.os.linux.close(fd);
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;
        const data = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(data);

        fillBgra(data, width, height);

        const pool = try shm.createPool(fd, @intCast(size));
        errdefer pool.destroy();
        const buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);

        return .{
            .buffer = buffer,
            .pool = pool,
            .fd = fd,
            .data = data,
        };
    }

    fn fillBgra(data: []u8, width: u32, height: u32) void {
        const stride = width * 4;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const off = @as(usize, y) * stride + @as(usize, x) * 4;
                data[off + 0] = 0xFF; // B
                data[off + 1] = 0x33; // G
                data[off + 2] = 0x66; // R
                data[off + 3] = 0xFF; // A
            }
        }
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                    globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
                }
            },
            .global_remove => {},
        }
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.surface.attach(self.buffer, 0, 0);
                self.surface.commit();
                self.configured = true;
            },
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
        switch (event) {
            .configure => {},
            .close => self.running = false,
            else => {},
        }
    }
};
