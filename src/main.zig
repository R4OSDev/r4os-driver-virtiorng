const r4os = @import("r4os");
const a = r4os.abi;
const Transport = @import("transport.zig").Transport;
const queue = @import("queue.zig");
comptime {
    asm (r4os.r4dev.driverEntriesAsm("virtrng_init", "virtrng_shutdown"));
}
var transport: Transport = .{};
var entropy: ?r4os.driver_entropy.Context = null;
var registration: u64 = 0;

export fn virtrng_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    const resources = ctx.resources() orelse return -1;
    entropy = resources.entropy() orelse return -1;
    transport.discover(api) catch |err| {
        ctx.logWarn(@errorName(err));
        return if (transport.release()) -1 else a.entropy_error_retained;
    };
    const backend = a.EntropyBackend{ .flags = a.entropy_source_flag_device | a.entropy_source_flag_virtual, .max_request_bytes = a.entropy_max_request_bytes, .context = @intFromPtr(&transport), .pci_address = @as(u32, transport.pci.bus) << 16 | @as(u32, transport.pci.device) << 8 | transport.pci.function, .vendor_id = transport.pci.vendor_id, .device_id = transport.pci.device_id, .read = @intFromPtr(&read) };
    const result = entropy.?.register(&backend, &registration);
    if (result != 0) return if (transport.release()) result else a.entropy_error_retained;
    // Registration pins this exact module before the first DMA-capable change.
    // The held init owner prevents read callbacks until initialization returns.
    transport.initialize() catch |err| {
        ctx.logWarn(@errorName(err));
        return if (transport.release()) -1 else a.entropy_error_retained;
    };
    ctx.logInfo("VIRTRNG modern queue0 ready; device-writable DMA, bounded used-length completion");
    return 0;
}
fn read(context: u64, data: [*]u8, bytes: u32, receipt: *a.EntropyDeviceReceipt) callconv(.c) i32 {
    if (context != @intFromPtr(&transport) or bytes == 0 or bytes > a.entropy_max_request_bytes)
        return a.entropy_error_invalid;
    if (!transport.ready) {
        @memset(data[0..bytes], 0);
        return a.entropy_error_unavailable;
    }
    return queue.fill(&transport.queue, &transport, data[0..bytes], receipt);
}
export fn virtrng_shutdown() callconv(.c) i32 {
    if (registration != 0) {
        if (entropy.?.unregister(registration) != 0) return a.entropy_error_stale;
        registration = 0;
    }
    if (transport.api == null) return 0;
    if (!transport.release()) return a.entropy_error_retained;
    if (transport.owned) {
        const ctx = r4os.r4dev.DriverContext.init(transport.api.?);
        ctx.logInfo("VIRTRNG shutdown: reset/busmaster readbacks accepted; DMA and MMIO released");
    }
    return 0;
}
