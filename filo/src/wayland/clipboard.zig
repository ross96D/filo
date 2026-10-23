const std = @import("std");

const ev = @import("zio").ev;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Context = @import("../context.zig").Context;

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
    /// The globals the clipboard's callbacks reach: the allocator for its
    /// buffers, the loop for the transfer probe, and the connection (its data
    /// device manager, device, and display).
    ctx: *Context,
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
    /// Watches `pending_fd` while a transfer is in flight.
    poll: ev.PipePoll = .init(-1, .read),

    pub fn init(ctx: *Context, seat: *wl.Seat) !*Clipboard {
        const device = try ctx.conn.data_device_manager.getDataDevice(seat);
        const self = try ctx.allocator.create(Clipboard);
        self.* = .{
            .ctx = ctx,
            .device = device,
        };
        device.setListener(*Clipboard, deviceListener, self);
        return self;
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.pending_fd) |fd| _ = std.os.linux.close(fd);
        self.pending_buf.deinit(self.ctx.allocator);
        if (self.selection) |offer| offer.destroy();
        if (self.source) |source| source.destroy();
        if (self.device.getVersion() >= 2) {
            self.device.release();
        } else {
            @as(*wl.Proxy, @ptrCast(self.device)).destroy();
        }
        self.source_text.deinit(self.ctx.allocator);
        self.ctx.allocator.destroy(self);
    }

    /// Record the serial of an input event so `set_selection` is accepted.
    pub fn updateSerial(self: *Clipboard, serial: u32) void {
        self.serial = serial;
    }

    /// Publish `text` as the selection.
    pub fn setText(self: *Clipboard, text: []const u8) void {
        self.source_text.clearRetainingCapacity();
        self.source_text.appendSlice(self.ctx.allocator, text) catch return;

        if (self.source == null) {
            const source = self.ctx.conn.data_device_manager.createDataSource() catch return;
            for (mimes) |mime| source.offer(mime);
            source.setListener(*Clipboard, sourceListener, self);
            self.source = source;
        }
        self.device.setSelection(self.source.?, self.serial);
        _ = self.ctx.conn.display.flush();
    }

    /// Whether the current selection offers text we can read.
    pub fn hasText(self: *const Clipboard) bool {
        return self.selection != null and bestMimeFromMask(self.selection_mask) != null;
    }

    /// Start reading the selection. Returns false when there is nothing to
    /// read or a transfer is already in flight; the transfer then completes
    /// from the event loop.
    pub fn receive(self: *Clipboard) bool {
        if (self.pending_fd != null) return false;
        const offer = self.selection orelse return false;
        const mime = bestMimeFromMask(self.selection_mask) orelse return false;

        var fds: [2]std.posix.fd_t = undefined;
        if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return false;

        offer.receive(mime, fds[1]);
        // The write end must stay open (and valid) until the request has been
        // flushed: libwayland only hands the descriptor to the kernel when the
        // request is actually sent.
        if (self.ctx.conn.display.flush() != .SUCCESS) {
            // TODO 3: maybe we could do better if it fails with EWOULDBLOCK or EAGAIN
            _ = std.os.linux.close(fds[1]);
            _ = std.os.linux.close(fds[0]);
            return false;
        }
        _ = std.os.linux.close(fds[1]);

        self.pending_fd = fds[0];
        self.pending_buf.clearRetainingCapacity();
        // Any event retires the transfer: readable, end-of-file (the source
        // closed without writing, i.e. empty text), or an error.
        self.poll = .init(fds[0], .read);
        self.poll.c.userdata = self;
        self.poll.c.callback = onReadable;
        self.ctx.loop.add(&self.poll.c);
        return true;
    }

    fn onReadable(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Clipboard = @ptrCast(@alignCast(c.userdata.?));
        self.pump();
    }

    /// Advance an in-flight receive until it would block.
    fn pump(self: *Clipboard) void {
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
            self.pending_buf.appendSlice(self.ctx.allocator, buf[0..n]) catch {
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
