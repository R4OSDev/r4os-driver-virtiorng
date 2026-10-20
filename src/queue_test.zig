const std = @import("std");
const q = @import("queue.zig");
const a = @import("r4os").abi;
test {
    _ = @import("transport_test.zig");
}
const Peer = struct {
    mode: enum { short, delayed, overlength, wrong_id, double_used, timeout, stopped_clock, retained } = .short,
    instant: u64 = 100,
    index: u16 = 65535,
    length: u32 = 0,
    submitted: u32 = 0,
    copied: u32 = 0,
    waits: u32 = 0,
    resets: u32 = 0,
    pub fn now(self: *Peer) u64 {
        return self.instant;
    }
    pub fn status(_: *Peer) u8 {
        return 15;
    }
    pub fn command(_: *Peer) u16 {
        return 6;
    }
    pub fn submit(self: *Peer, bytes: u32, _: u16) void {
        self.submitted += 1;
        self.length = if (self.mode == .short) @min(bytes, 7) else bytes;
        if (self.mode == .overlength) self.length += 1;
        if (self.mode != .delayed and self.mode != .timeout and self.mode != .stopped_clock and self.mode != .retained)
            self.index +%= if (self.mode == .double_used) @as(u16, 2) else 1;
    }
    pub fn used(self: *Peer) q.Used {
        return .{ .index = self.index, .id = if (self.mode == .wrong_id) 9 else 0, .bytes = self.length };
    }
    pub fn copy(self: *Peer, out: []u8) void {
        self.copied += @intCast(out.len);
        @memset(out, 0x53);
    }
    pub fn wait(self: *Peer) void {
        self.waits += 1;
        if (self.mode != .stopped_clock) self.instant += a.entropy_max_window_ns / 4;
        if (self.mode == .delayed and self.waits == 2) self.index +%= 1;
    }
    pub fn stop(self: *Peer) bool {
        self.resets += 1;
        return self.mode != .retained;
    }
};
test "short used lengths copy only completed bytes across index wrap" {
    var peer: Peer = .{};
    var state: q.State = .{ .available = 65535, .used = 65535 };
    var receipt: a.EntropyDeviceReceipt = .{ .clock_source = 2, .clock_generation = 1 };
    var out: [17]u8 = @splat(0x77);
    try std.testing.expectEqual(@as(i32, 17), q.fill(&state, &peer, &out, &receipt));
    try std.testing.expectEqual(@as(u64, 3), receipt.dma_completed);
    try std.testing.expectEqual(@as(u64, 2), receipt.short_completions);
    try std.testing.expectEqual(@as(u16, 2), state.used);
    try std.testing.expectEqual(@as(u32, 17), peer.copied);
    try std.testing.expectEqual(@as(u32, 0), peer.resets);
}
test "delayed used entry waits before copying" {
    var peer: Peer = .{ .mode = .delayed };
    var state: q.State = .{ .available = 65535, .used = 65535 };
    var receipt: a.EntropyDeviceReceipt = .{};
    var out: [17]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 17), q.fill(&state, &peer, &out, &receipt));
    try std.testing.expectEqual(@as(u32, 2), peer.waits);
}
test "malformed completions never copy; timeout and failed stop retain exact DMA" {
    for ([_]Peer{ .{ .mode = .overlength }, .{ .mode = .wrong_id }, .{ .mode = .double_used }, .{ .mode = .timeout }, .{ .mode = .stopped_clock }, .{ .mode = .retained } }) |initial| {
        var peer = initial;
        var state: q.State = .{ .available = 65535, .used = 65535 };
        var receipt: a.EntropyDeviceReceipt = .{};
        var out: [17]u8 = @splat(0x77);
        try std.testing.expect(q.fill(&state, &peer, &out, &receipt) < 0);
        try std.testing.expectEqual(@as(u32, 0), peer.copied);
        try std.testing.expectEqual(@as(u32, 1), peer.resets);
        try std.testing.expect(peer.waits <= 4097);
        for (out) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        const expected = if (peer.mode == .retained) a.entropy_receipt_flag_retained else a.entropy_receipt_flag_quiesced;
        try std.testing.expect(receipt.flags & expected != 0);
    }
}
