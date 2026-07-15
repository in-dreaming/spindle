const std = @import("std");
const CancelWait = @import("../sync/common.zig").CancelWait;
const park = @import("../platform/park.zig");
const SpinMutex = @import("../sync/spin_mutex.zig").SpinMutex;
pub const CancellationSource = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    registration_lock: SpinMutex = .{},
    registrations: ?*CancelWait.Registration = null,
    pub fn token(self: *CancellationSource) CancellationToken {
        return .{ .source = self };
    }
    /// Idempotently publishes cancellation. Waiters observe it through acquire loads.
    pub fn cancel(self: *CancellationSource) void {
        self.cancelled.store(true, .release);
        self.registration_lock.lock();
        defer self.registration_lock.unlock();
        var registration = self.registrations;
        self.registrations = null;
        while (registration) |current| {
            current.notify();
            registration = current.next;
        }
    }
};
pub const CancellationToken = struct {
    source: *const CancellationSource,
    pub fn isCancelled(self: CancellationToken) bool {
        return self.source.cancelled.load(.acquire);
    }
    pub fn waitView(self: CancellationToken) CancelWait {
        return .{ .cancelled = &self.source.cancelled, .context = @constCast(self.source), .register_fn = register, .unregister_fn = unregister };
    }
    fn register(context: ?*anyopaque, registration: *CancelWait.Registration) void {
        const source: *CancellationSource = @ptrCast(@alignCast(context.?));
        source.registration_lock.lock();
        defer source.registration_lock.unlock();
        if (source.cancelled.load(.acquire)) {
            park.wakeAll(registration.word);
            return;
        }
        registration.next = source.registrations;
        source.registrations = registration;
    }
    fn unregister(context: ?*anyopaque, registration: *CancelWait.Registration) void {
        const source: *CancellationSource = @ptrCast(@alignCast(context.?));
        source.registration_lock.lock();
        defer source.registration_lock.unlock();
        var cursor = &source.registrations;
        while (cursor.*) |current| {
            if (current == registration) {
                cursor.* = current.next;
                return;
            }
            cursor = &current.next;
        }
    }
};
