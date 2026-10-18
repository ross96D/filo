const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;

/// Text MIME types this clipboard advertises as a source, in the order we
/// prefer them when reading someone else's selection.
///
/// `text/plain;charset=utf-8` is what Wayland-native toolkits (GTK, Qt) offer;
/// `UTF8_STRING`, `STRING` and `TEXT` keep X11 clients (through XWayland)
/// working. X11 `STRING`/`TEXT` are nominally Latin-1 rather than UTF-8, so
/// received text is repaired before it is handed on.
const mimes = [_][*:0]const u8{
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

/// Called on the main thread when a pending `receive` finishes. `text` is null
/// when the transfer failed, and is only valid for the duration of the call.
pub const ReceiveCallback = *const fn (ctx: ?*anyopaque, text: ?[]const u8) void;

/// Whether `mime` is one of the text flavours this clipboard understands.
pub fn isTextMime(mime: []const u8) bool {
    for (mimes) |m| {
        if (std.mem.eql(u8, mime, std.mem.span(m))) return true;
    }
    return false;
}

fn bestMimeFromMask(mask: u32) ?[*:0]const u8 {
    for (mimes, 0..) |mime, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) return mime;
    }
    return null;
}

/// The seat's Wayland clipboard (the selection).
///
/// Copying is asynchronous: after `setText` we keep the `wl_data_source` alive
/// and serve `send` requests whenever another client pastes, which may be long
/// after the call returned. Pasting is a two-step handshake: `receive` starts
/// the transfer and hands back a pipe, and `pump` finishes it once the source
/// has written and closed its end.
///
/// Neither step may block, because the transfer can have to be served by this
/// same client: after a copy the compositor echoes the selection back to us, so
/// a paste in our own app is answered by our own `wl_data_source`.
pub const Clipboard = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    manager: *wl.DataDeviceManager,
    device: *wl.DataDevice,

    /// Serial of the most recent input event. `set_selection` is only honoured
    /// with a serial from a recent seat event, so input handlers feed them in.
    serial: u32 = 0,

    /// Our current selection, kept alive to answer late `send` requests.
    source: ?*wl.DataSource = null,
    source_text: std.ArrayListUnmanaged(u8) = .empty,

    /// The current incoming selection (`null` when there is none) and the mask
    /// of `mimes` it advertises.
    selection: ?*wl.DataOffer = null,
    selection_mask: u32 = 0,
    /// Mask accumulated by the offer most recently introduced by `data_offer`,
    /// committed when the `selection` event names it.
    incoming_mask: u32 = 0,

    /// In-flight `receive`, if any.
    pending_fd: ?std.posix.fd_t = null,
    pending_buf: std.ArrayListUnmanaged(u8) = .empty,
    on_receive: ?ReceiveCallback = null,
    receive_ctx: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *wl.Display,
        manager: *wl.DataDeviceManager,
        seat: *wl.Seat,
    ) !*Clipboard {
        const device = try manager.getDataDevice(seat);
        const self = try allocator.create(Clipboard);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .manager = manager,
            .device = device,
        };
        device.setListener(*Clipboard, deviceListener, self);
        return self;
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.pending_fd) |fd| _ = std.os.linux.close(fd);
        self.pending_buf.deinit(self.allocator);
        if (self.selection) |offer| offer.destroy();
        if (self.source) |source| source.destroy();
        if (self.device.getVersion() >= 2) {
            self.device.release();
        } else {
            @as(*wl.Proxy, @ptrCast(self.device)).destroy();
        }
        self.source_text.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Record the serial of an input event so `set_selection` is accepted.
    pub fn updateSerial(self: *Clipboard, serial: u32) void {
        self.serial = serial;
    }

    /// Publish `text` as the selection.
    pub fn setText(self: *Clipboard, text: []const u8) void {
        self.source_text.clearRetainingCapacity();
        self.source_text.appendSlice(self.allocator, text) catch return;

        if (self.source == null) {
            const source = self.manager.createDataSource() catch return;
            for (mimes) |mime| source.offer(mime);
            source.setListener(*Clipboard, sourceListener, self);
            self.source = source;
        }
        self.device.setSelection(self.source.?, self.serial);
        _ = self.display.flush();
    }

    /// Whether the current selection offers text we can read.
    pub fn hasText(self: *const Clipboard) bool {
        return self.selection != null and bestMimeFromMask(self.selection_mask) != null;
    }

    /// The read end of an in-flight transfer, to be added to the event loop's
    /// poll set. `null` when nothing is in flight.
    pub fn pollFd(self: *const Clipboard) ?std.posix.fd_t {
        return self.pending_fd;
    }

    /// Start reading the selection. Returns the read end of a pipe that the
    /// caller must poll and feed to `pump`, or `null` when there is nothing to
    /// read or a transfer is already in flight.
    pub fn receive(self: *Clipboard) ?std.posix.fd_t {
        if (self.pending_fd != null) return null;
        const offer = self.selection orelse return null;
        const mime = bestMimeFromMask(self.selection_mask) orelse return null;

        var fds: [2]std.posix.fd_t = undefined;
        if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return null;

        offer.receive(mime, fds[1]);
        // The write end must stay open (and valid) until the request has been
        // flushed: libwayland only hands the descriptor to the kernel when the
        // request is actually sent.
        if (self.display.flush() != .SUCCESS) {
            _ = std.os.linux.close(fds[1]);
            _ = std.os.linux.close(fds[0]);
            return null;
        }
        _ = std.os.linux.close(fds[1]);

        self.pending_fd = fds[0];
        self.pending_buf.clearRetainingCapacity();
        return fds[0];
    }

    /// Advance an in-flight receive. Call whenever `pollFd` is readable.
    pub fn pump(self: *Clipboard) void {
        const fd = self.pending_fd orelse return;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.finish(null);
                    return;
                },
            };
            if (n == 0) {
                self.finish(self.pending_buf.items);
                return;
            }
            self.pending_buf.appendSlice(self.allocator, buf[0..n]) catch {
                self.finish(null);
                return;
            };
        }
    }

    fn finish(self: *Clipboard, text: ?[]const u8) void {
        if (self.pending_fd) |fd| _ = std.os.linux.close(fd);
        self.pending_fd = null;
        if (self.on_receive) |callback| callback(self.receive_ctx, text);
    }

    /// Serve a `send` request from a client pasting our selection.
    fn writeSelection(self: *Clipboard, fd: std.posix.fd_t) void {
        defer _ = std.os.linux.close(fd);
        const text = self.source_text.items;
        var written: usize = 0;
        while (written < text.len) {
            const n = std.os.linux.write(fd, text.ptr + written, text.len - written);
            switch (std.os.linux.errno(n)) {
                .SUCCESS => written += n,
                .INTR => continue,
                else => return,
            }
        }
    }
};

fn deviceListener(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
    switch (event) {
        .data_offer => |e| {
            // The offer's `offer` events arrive before the `selection` event
            // that names it, so collect the mask now and commit it there.
            self.incoming_mask = 0;
            e.id.setListener(*Clipboard, offerListener, self);
        },
        .selection => |e| {
            if (self.selection) |previous| previous.destroy();
            self.selection = e.id;
            self.selection_mask = if (e.id != null) self.incoming_mask else 0;
        },
        // Drag-and-drop is not implemented.
        else => {},
    }
}

fn offerListener(_: *wl.DataOffer, event: wl.DataOffer.Event, self: *Clipboard) void {
    switch (event) {
        .offer => |e| {
            for (mimes, 0..) |mime, i| {
                if (std.mem.orderZ(u8, e.mime_type, mime) == .eq) {
                    self.incoming_mask |= @as(u32, 1) << @intCast(i);
                    break;
                }
            }
        },
        else => {},
    }
}

fn sourceListener(_: *wl.DataSource, event: wl.DataSource.Event, self: *Clipboard) void {
    switch (event) {
        .send => |e| self.writeSelection(e.fd),
        .cancelled => {
            if (self.source) |source| source.destroy();
            self.source = null;
        },
        // Drag-and-drop is not implemented.
        else => {},
    }
}

test "MIME mask picks the most preferred flavour" {
    const testing = std.testing;
    try testing.expectEqual(@as(?[*:0]const u8, null), bestMimeFromMask(0));
    // Bit 0 is the most preferred, bit 4 the least.
    try testing.expectEqualStrings("text/plain;charset=utf-8", std.mem.span(bestMimeFromMask(0b11111).?));
    try testing.expectEqualStrings("text/plain", std.mem.span(bestMimeFromMask(0b11110).?));
    try testing.expectEqualStrings("TEXT", std.mem.span(bestMimeFromMask(0b10000).?));
}

test "text MIME recognition" {
    const testing = std.testing;
    try testing.expect(isTextMime("text/plain"));
    try testing.expect(isTextMime("text/plain;charset=utf-8"));
    try testing.expect(isTextMime("UTF8_STRING"));
    try testing.expect(!isTextMime("image/png"));
    try testing.expect(!isTextMime(""));
}
