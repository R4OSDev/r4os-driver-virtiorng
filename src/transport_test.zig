//! Actual transport functions with PCI/MMIO/DMA peers, never host device I/O.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Transport = @import("transport.zig").Transport;
const Peer = struct {
    var api_bytes: [@sizeOf(a.DriverApi)]u8 align(8) = @splat(0);
    var config: [256]u8 = @splat(0);
    var mmio: [16384]u8 align(4096) = @splat(0);
    var dma: [8192]u8 align(4096) = @splat(0);
    var maps: u32 = 0;
    var unmaps: u32 = 0;
    var frees: u32 = 0;
    var reset_reads: u32 = 0;
    var waits: u32 = 0;
    var instant: u64 = 100;
    var deny_reset = false;
    fn setup() *const a.DriverApi {
        @memset(&api_bytes, 0);
        @memset(&config, 0);
        @memset(&mmio, 0);
        @memset(&dma, 0x77);
        maps = 0;
        unmaps = 0;
        frees = 0;
        reset_reads = 0;
        waits = 0;
        instant = 100;
        deny_reset = false;
        const api: *a.DriverApi = @ptrCast(&api_bytes);
        api.magic = a.driver_magic;
        api.version = a.driver_api_version;
        api.size = @sizeOf(a.DriverApi);
        api.resource_query = resources;
        api.gfx_memory_query = memory;
        api.pci_device_count = deviceCount;
        api.pci_device_at = deviceAt;
        api.pci_read_config32 = readConfig;
        api.pci_write_config32 = writeConfig;
        api.pci_enable_bus_master = enableMaster;
        api.alloc_dma_region = allocate;
        api.free_dma_region = free;
        api.wait_ticks = wait;
        putConfig(4, (1 << 20) | 6);
        config[0x34] = 0x40;
        cap(0x40, 0x50, 1, 0, 56);
        cap(0x50, 0x60, 3, 4096, 1);
        cap(0x60, 0, 2, 8192, 2);
        config[0x62] = 20;
        putConfig(0x70, 4);
        putConfig(0x20, 0xf0000000);
        store(u32, 4, 1);
        store(u16, 0x12, 1);
        store(u16, 0x18, 8);
        return api;
    }
    fn cap(at: usize, next: u8, kind: u8, offset: u32, bytes: u32) void {
        config[at] = 9;
        config[at + 1] = next;
        config[at + 2] = 16;
        config[at + 3] = kind;
        config[at + 4] = 4;
        putConfig(at + 8, offset);
        putConfig(at + 12, bytes);
    }
    fn putConfig(offset: usize, value: u32) void {
        std.mem.writeInt(u32, config[offset..][0..4], value, .little);
    }
    fn store(comptime T: type, offset: usize, value: T) void {
        @as(*volatile T, @ptrFromInt(@intFromPtr(&mmio) + offset)).* = value;
    }
    fn load(comptime T: type, offset: usize) T {
        return @as(*volatile T, @ptrFromInt(@intFromPtr(&mmio) + offset)).*;
    }
    fn resources(out: *a.DriverResourceApi) callconv(.c) i32 {
        out.* = .{ .now_ns = @intFromPtr(&now) };
        return a.driver_resource_ok;
    }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = .{ .mmio_map = @intFromPtr(&map), .mmio_unmap = @intFromPtr(&unmap) };
        return a.gfx_buffer_result_ok;
    }
    fn map(input: *const a.GfxMmioRequest, out: *a.GfxMmioWindow) callconv(.c) i32 {
        std.debug.assert(input.resource_base == 0xf0000000 and input.byte_length == 12288);
        maps += 1;
        out.* = .{ .handle = .{ .id = 1, .generation = 1 }, .cpu_address = @intFromPtr(&mmio), .physical_address = input.resource_base, .byte_length = input.byte_length };
        // Success is ONE. Returning zero here would reproduce the old test gap.
        return a.gfx_buffer_result_ok;
    }
    fn unmap(handle: *const a.GfxBufferHandle, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(handle.id == 1 and handle.generation == 1 and quiesced == 1);
        unmaps += 1;
        return a.gfx_buffer_result_ok;
    }
    fn deviceCount() callconv(.c) u32 {
        return 1;
    }
    fn deviceAt(index: u32, out: *a.PciDeviceInfo) callconv(.c) i32 {
        if (index != 0) return -1;
        out.* = .{ .vendor_id = 0x1af4, .device_id = 0x1044 };
        return 0;
    }
    fn readConfig(_: u8, _: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 {
        return std.mem.readInt(u32, config[offset..][0..4], .little);
    }
    fn writeConfig(_: u8, _: u8, _: u8, _: u8, offset: u16, value: u32) callconv(.c) i32 {
        putConfig(offset, value);
        return 0;
    }
    fn enableMaster(_: u8, _: u8, _: u8, _: u8, _: u32) callconv(.c) i32 {
        putConfig(4, (1 << 20) | 6);
        return 0;
    }
    fn allocate(bytes: u32, alignment: u32, out: *a.DmaBuffer) callconv(.c) i32 {
        std.debug.assert(bytes == dma.len and alignment == 4096);
        out.* = .{ .phys_addr = 0x100000, .virt_addr = @intFromPtr(&dma), .bytes = bytes, .alignment = alignment };
        return 0;
    }
    fn free(out: *a.DmaBuffer) callconv(.c) void {
        std.debug.assert(load(u8, 0x14) == 0 and readConfig(0, 0, 0, 0, 4) & 4 == 0 and out.phys_addr == 0x100000);
        frees += 1;
        out.* = .{};
    }
    fn now() callconv(.c) u64 {
        instant += 1_000_000;
        if (load(u8, 0x14) == 0) {
            reset_reads += 1;
            if (deny_reset) store(u8, 0x14, 15) else store(u16, 0x1c, 0);
        }
        return instant;
    }
    fn wait(_: u64) callconv(.c) void {
        waits += 1;
    }
};
test "actual discovery and release accept MMIO success one" {
    var transport: Transport = .{};
    try transport.discover(Peer.setup());
    try std.testing.expectEqual(@as(u32, 1), Peer.maps);
    try std.testing.expect(transport.release());
    try std.testing.expectEqual(@as(u32, 1), Peer.unmaps);
    try std.testing.expectEqual(@as(u32, 0), Peer.frees);
}
test "actual initialized queue needs reset and busmaster receipt before DMA and MMIO free" {
    var transport: Transport = .{};
    try transport.discover(Peer.setup());
    try transport.initialize();
    try std.testing.expect(transport.ready);
    try std.testing.expectEqual(@as(u16, 1), Peer.load(u16, 0x1c));
    try std.testing.expectEqual(@as(u16, 1), @as(*volatile u16, @ptrFromInt(@intFromPtr(&Peer.dma) + 0x200)).*);
    try std.testing.expectEqual(@as(u64, 0x100000), Peer.load(u64, 0x20));
    try std.testing.expect(transport.release());
    try std.testing.expect(transport.quiesced and !transport.ready);
    try std.testing.expectEqual(@as(u32, 1), Peer.frees);
    try std.testing.expectEqual(@as(u32, 1), Peer.unmaps);
}
test "failed physical reset retains allocation and mappings without a second reset attempt" {
    var transport: Transport = .{};
    try transport.discover(Peer.setup());
    try transport.initialize();
    Peer.deny_reset = true;
    try std.testing.expect(!transport.release());
    try std.testing.expect(!transport.quiesced and transport.stop_attempted);
    try std.testing.expectEqual(@as(u32, 0), Peer.frees);
    try std.testing.expectEqual(@as(u32, 0), Peer.unmaps);
    const before = Peer.reset_reads;
    Peer.deny_reset = false;
    try std.testing.expect(!transport.release());
    try std.testing.expectEqual(before, Peer.reset_reads);
}
