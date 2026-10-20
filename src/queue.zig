//! Split-ring request policy, also exercised with a deterministic device peer.
//! Returned bytes only become visible after the exact used ID/length receipt.
const a = @import("r4os").abi;
pub const State = struct {
    available: u16 = 0,
    used: u16 = 0,
    generation: u64 = 0,
};
pub const Used = struct { index: u16, id: u32, bytes: u32 };

pub fn fill(state: *State, hw: anytype, out: []u8, receipt: *a.EntropyDeviceReceipt) i32 {
    const clock_source = receipt.clock_source;
    const clock_generation = receipt.clock_generation;
    receipt.* = .{ .clock_source = clock_source, .clock_generation = clock_generation, .flags = a.entropy_receipt_flag_virtual, .requested_bytes = @intCast(out.len), .available_index_before = state.available, .used_index_before = state.used };
    if (out.len == 0 or out.len > a.entropy_max_request_bytes or state.generation == ~@as(u64, 0))
        return a.entropy_error_invalid;
    state.generation += 1;
    receipt.request_generation = state.generation;
    receipt.begin_ns = hw.now();
    if (receipt.begin_ns == ~@as(u64, 0)) return fail(hw, out, receipt, a.entropy_error_timeout, false);
    receipt.flags |= a.entropy_receipt_flag_started;
    var done: usize = 0;
    var in_flight = false;
    var polls: u32 = 0;
    while (done < out.len) {
        const status = hw.status();
        const now = hw.now();
        if (status & 15 != 15 or status & 192 != 0)
            return fail(hw, out, receipt, a.entropy_error_device, in_flight);
        if (now < receipt.begin_ns or now == ~@as(u64, 0) or now - receipt.begin_ns >= a.entropy_max_window_ns)
            return fail(hw, out, receipt, a.entropy_error_timeout, in_flight);
        if (!in_flight) {
            // A used entry with no outstanding descriptor is stale/unowned.
            if (hw.used().index != state.used)
                return fail(hw, out, receipt, a.entropy_error_device, false);
            hw.submit(@intCast(out.len - done), state.available);
            state.available +%= 1;
            receipt.dma_submitted += 1;
            in_flight = true;
        }
        const used = hw.used();
        if (used.index != state.used) {
            const bytes: u32 = @intCast(out.len - done);
            if (used.index -% state.used != 1 or used.id != 0 or used.bytes == 0 or used.bytes > bytes)
                return fail(hw, out, receipt, a.entropy_error_device, true);
            // Device writes precede its used-index publication; transport
            // acquires that publication before this exact byte-bounded copy.
            hw.copy(out[done..][0..used.bytes]);
            done += used.bytes;
            state.used = used.index;
            in_flight = false;
            receipt.dma_completed += 1;
            receipt.completed_bytes = @intCast(done);
            receipt.last_used_length = used.bytes;
            receipt.last_descriptor = used.id;
            if (used.bytes < bytes) receipt.short_completions += 1;
            receipt.flags |= a.entropy_receipt_flag_used | a.entropy_receipt_flag_length_verified;
        } else {
            // Secondary finite guard if the functional clock stops advancing.
            polls += 1;
            if (polls > 4096) return fail(hw, out, receipt, a.entropy_error_timeout, true);
            hw.wait();
        }
    }
    receipt.end_ns = hw.now();
    receipt.available_index_after = state.available;
    receipt.used_index_after = state.used;
    receipt.device_status = hw.status();
    receipt.pci_command = hw.command();
    if (receipt.end_ns < receipt.begin_ns or receipt.end_ns == ~@as(u64, 0) or
        receipt.end_ns - receipt.begin_ns > a.entropy_max_window_ns or receipt.device_status & 192 != 0)
        return fail(hw, out, receipt, a.entropy_error_timeout, false);
    receipt.flags |= a.entropy_receipt_flag_within_budget;
    receipt.status = a.entropy_device_status_completed;
    return @intCast(done);
}
fn fail(hw: anytype, out: []u8, receipt: *a.EntropyDeviceReceipt, reason: i32, in_flight: bool) i32 {
    // Even a completed malformed entry closes this queue. A reset readback,
    // never elapsed time or cancelled admission, proves physical DMA stopped.
    _ = in_flight;
    receipt.end_ns = hw.now();
    @memset(out, 0);
    if (hw.stop()) {
        receipt.flags |= a.entropy_receipt_flag_quiesced;
        receipt.status = if (reason == a.entropy_error_timeout) a.entropy_device_status_timeout else a.entropy_device_status_lost;
        return reason;
    }
    receipt.flags |= a.entropy_receipt_flag_retained;
    receipt.status = a.entropy_device_status_retained;
    return a.entropy_error_retained;
}
