const std = @import("std");

/// Compact event payload usable by all lower runtime layers without importing upper-level semantics.
pub const Event = struct {
    monotonic_ns: u64,
    kind: []const u8,
    value: i64 = 0,
};

/// Allocation-free event outlet. A null sink is intentionally a no-op.
pub const EventSink = struct {
    ptr: *anyopaque,
    emit_fn: *const fn (ptr: *anyopaque, event: Event) void,

    pub fn emit(self: ?EventSink, event: Event) void {
        if (self) |sink| sink.emit_fn(sink.ptr, event);
    }
};

/// Fixed-capacity event ring. Full rings reject new events rather than overwriting unread data.
pub const RingSink = struct {
    mutex: std.atomic.Mutex = .unlocked,
    events: []Event,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,

    pub fn init(events: []Event) RingSink {
        return .{ .events = events };
    }
    pub fn sink(self: *RingSink) EventSink {
        return .{ .ptr = self, .emit_fn = emitEvent };
    }

    pub fn emitEvent(ptr: *anyopaque, event: Event) void {
        const self: *RingSink = @ptrCast(@alignCast(ptr));
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.len == self.events.len) {
            self.dropped += 1;
            return;
        }
        if (self.events.len == 0) {
            self.dropped += 1;
            return;
        }
        self.events[(self.head + self.len) % self.events.len] = event;
        self.len += 1;
    }

    /// Removes the oldest event. The returned event aliases its original static fields.
    pub fn pop(self: *RingSink) ?Event {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const result = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.len -= 1;
        return result;
    }

    pub fn droppedCount(self: *RingSink) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.dropped;
    }
};

/// NDJSON file sink. Event kind must be a static trusted identifier; it is JSON escaped before writing.
pub const NdjsonSink = struct {
    mutex: std.atomic.Mutex = .unlocked,
    file: std.fs.File,

    pub fn sink(self: *NdjsonSink) EventSink {
        return .{ .ptr = self, .emit_fn = emitEvent };
    }

    pub fn emitEvent(ptr: *anyopaque, event: Event) void {
        const self: *NdjsonSink = @ptrCast(@alignCast(ptr));
        lock(&self.mutex);
        defer self.mutex.unlock();
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{{\"monotonic_ns\":{d},\"kind\":\"", .{event.monotonic_ns}) catch return;
        for (event.kind) |byte| switch (byte) {
            '"', '\\' => {
                writer.writeByte('\\') catch return;
                writer.writeByte(byte) catch return;
            },
            0x00...0x1f => writer.print("\\u{X:0>4}", .{byte}) catch return,
            else => writer.writeByte(byte) catch return,
        };
        writer.print("\",\"value\":{d}}}\n", .{event.value}) catch return;
        self.file.writeAll(writer.buffered()) catch {};
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

test "ring sink reports full queue without overwriting" {
    var storage: [1]Event = undefined;
    var ring = RingSink.init(&storage);
    const sink = ring.sink();
    sink.emit(.{ .monotonic_ns = 1, .kind = "first" });
    sink.emit(.{ .monotonic_ns = 2, .kind = "second" });
    try std.testing.expectEqual(@as(u64, 1), ring.droppedCount());
    try std.testing.expectEqualStrings("first", ring.pop().?.kind);
}
