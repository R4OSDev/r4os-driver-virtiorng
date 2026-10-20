//! Modern PCI Virtio entropy transport (VIRTIO 1.3, device ID 4).
//! No device-specific features/configuration; one split request queue.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const q = @import("queue.zig");
const Cap = struct { bar: u8 = 0, offset: u32 = 0, bytes: u32 = 0 };
const max_span = 1024 * 1024;
const ring_size: u16 = 8;
const available_offset = 0x200;
const used_offset = 0x400;
const data_offset = 0x1000;
const dma_bytes = 0x2000;
pub const Error = error{ NotFound, Invalid, Mapping, Rejected, NoMemory, FirmwareOwned, Retained };

pub const Transport = struct {
    api: ?*const a.DriverApi = null,
    resources: ?r4os.driver_resources.Context = null,
    memory: ?r4os.driver_memory.Context = null,
    pci: a.PciDeviceInfo = .{},
    windows: [6]a.GfxMmioWindow = @splat(.{}),
    caps: [4]Cap = @splat(.{}),
    common: u64 = 0,
    notify: u64 = 0,
    notify_multiplier: u32 = 0,
    queue_notify: u64 = 0,
    dma: a.DmaBuffer = .{},
    queue: q.State = .{},
    owned: bool = false,
    ready: bool = false,
    stop_attempted: bool = false,
    quiesced: bool = false,
    saved_command: ?u16 = null,

    fn context(self: *const Transport) r4os.r4dev.DriverContext {
        return r4os.r4dev.DriverContext.init(self.api.?);
    }
    pub fn discover(self: *Transport, api: *const a.DriverApi) Error!void {
        self.api = api;
        const ctx = self.context();
        self.resources = ctx.resources() orelse return error.Mapping;
        self.memory = ctx.memory() orelse return error.Mapping;
        var found = false;
        for (0..ctx.pciDeviceCount()) |index| {
            var pci: a.PciDeviceInfo = .{};
            if (ctx.pciDeviceAt(@intCast(index), &pci) != 0) continue;
            if (pci.vendor_id == 0x1af4 and (pci.device_id == 0x1044 or pci.device_id == 0x1005)) {
                self.pci = pci;
                found = true;
                break;
            }
        }
        if (!found) return error.NotFound;
        if (ctx.pciReadConfig32(self.pci, 4) & (1 << 20) == 0) return error.Invalid;
        var seen: [256]bool = @splat(false);
        var pointer: u16 = config8(&ctx, self.pci, 0x34);
        var count: u32 = 0;
        while (pointer != 0) {
            if (pointer < 0x40 or pointer > 0xfc or pointer & 3 != 0 or seen[pointer] or count >= 48) return error.Invalid;
            seen[pointer] = true;
            count += 1;
            const next = config8(&ctx, self.pci, pointer + 1);
            if (config8(&ctx, self.pci, pointer) == 9) {
                const length: u16 = config8(&ctx, self.pci, pointer + 2);
                const kind = config8(&ctx, self.pci, pointer + 3);
                if (length < 16 or pointer + length > 256) return error.Invalid;
                if (kind >= 1 and kind <= 3) {
                    if (self.caps[kind].bytes != 0) return error.Invalid;
                    const bar = config8(&ctx, self.pci, pointer + 4);
                    const offset = ctx.pciReadConfig32(self.pci, pointer + 8);
                    const bytes = ctx.pciReadConfig32(self.pci, pointer + 12);
                    if (bar >= 6 or bytes == 0 or offset >= max_span or bytes > max_span - offset) return error.Invalid;
                    self.caps[kind] = .{ .bar = bar, .offset = offset, .bytes = bytes };
                    if (kind == 2) {
                        if (length < 20) return error.Invalid;
                        self.notify_multiplier = ctx.pciReadConfig32(self.pci, pointer + 16);
                    }
                }
            }
            pointer = next;
        }
        if (self.caps[1].bytes < 56 or self.caps[2].bytes < 2 or self.caps[3].bytes < 1 or
            self.caps[1].offset & 7 != 0 or self.caps[2].offset & 1 != 0) return error.Invalid;
        var spans: [6]u64 = @splat(0);
        for (self.caps[1..], 0..) |cap, index| {
            for (self.caps[1 .. index + 1]) |prior| {
                if (prior.bar == cap.bar and cap.offset < prior.offset + prior.bytes and prior.offset < cap.offset + cap.bytes)
                    return error.Invalid;
            }
            spans[cap.bar] = @max(spans[cap.bar], @as(u64, cap.offset) + cap.bytes);
        }
        for (spans, 0..) |span, index| {
            if (span == 0) continue;
            const base = try barBase(&ctx, self.pci, @intCast(index));
            const bytes = std.mem.alignForward(u64, span, 4096);
            const request = a.GfxMmioRequest{ .resource_base = base, .resource_bytes = bytes, .byte_length = bytes, .cache_policy = a.gfx_buffer_cache_uncached };
            if (self.memory.?.mmioMap(&request, &self.windows[index]) != a.gfx_buffer_result_ok) return error.Mapping;
        }
        self.common = self.address(1);
        self.notify = self.address(2);
        // Do not reset or alter firmware-owned active queues during discovery.
        if (read(u8, self.common + 0x14) != 0) return error.FirmwareOwned;
    }
    pub fn initialize(self: *Transport) Error!void {
        const ctx = self.context();
        self.saved_command = @truncate(ctx.pciReadConfig32(self.pci, 4));
        self.owned = true;
        if (ctx.pciEnableBusMaster(self.pci, a.pci_enable_memory_space) != 0) return error.Mapping;
        write(u8, self.common + 0x14, 3);
        write(u32, self.common, 1);
        if (read(u32, self.common + 4) & 1 == 0) return error.Rejected;
        write(u32, self.common + 8, 0);
        write(u32, self.common + 12, 0);
        write(u32, self.common + 8, 1);
        write(u32, self.common + 12, 1);
        write(u8, self.common + 0x14, 11);
        if (read(u8, self.common + 0x14) != 11 or read(u16, self.common + 0x12) == 0) return error.Rejected;
        write(u16, self.common + 0x10, 0xffff);
        write(u16, self.common + 0x16, 0);
        if (read(u16, self.common + 0x18) < ring_size or read(u16, self.common + 0x1c) != 0) return error.Rejected;
        const offset = @as(u64, read(u16, self.common + 0x1e)) * self.notify_multiplier;
        if (offset > self.caps[2].bytes - 2 or (self.notify + offset) & 1 != 0) return error.Invalid;
        self.queue_notify = self.notify + offset;
        if (ctx.allocDmaRegion(dma_bytes, 4096, &self.dma) != 0) return error.NoMemory;
        if (self.dma.bytes < dma_bytes or self.dma.phys_addr == 0 or self.dma.virt_addr == 0 or
            self.dma.phys_addr & 4095 != 0 or self.dma.virt_addr & 4095 != 0) return error.Invalid;
        @memset(@as([*]u8, @ptrFromInt(self.dma.virt_addr))[0..dma_bytes], 0);
        write(u16, self.dma.virt_addr + available_offset, 1); // Suppress completion interrupts; bounded polling.
        write(u16, self.common + 0x18, ring_size);
        write(u16, self.common + 0x1a, 0xffff);
        write64(self.common + 0x20, self.dma.phys_addr);
        write64(self.common + 0x28, self.dma.phys_addr + available_offset);
        write64(self.common + 0x30, self.dma.phys_addr + used_offset);
        fence();
        write(u16, self.common + 0x1c, 1);
        if (read(u16, self.common + 0x1c) != 1) return error.Rejected;
        write(u8, self.common + 0x14, 15);
        if (read(u8, self.common + 0x14) != 15 or self.command() & 6 != 6) return error.Rejected;
        self.ready = true;
    }
    fn address(self: *const Transport, kind: usize) u64 {
        const cap = self.caps[kind];
        return self.windows[cap.bar].cpu_address + cap.offset;
    }
    pub fn now(self: *Transport) u64 {
        return self.resources.?.nowNs();
    }
    pub fn status(self: *Transport) u8 {
        return if (self.ready) read(u8, self.common + 0x14) else 0;
    }
    pub fn command(self: *Transport) u16 {
        const ctx = self.context();
        return @truncate(ctx.pciReadConfig32(self.pci, 4));
    }
    pub fn submit(self: *Transport, bytes: u32, index: u16) void {
        const base = self.dma.virt_addr;
        write(u64, base, self.dma.phys_addr + data_offset);
        write(u32, base + 8, bytes);
        write(u16, base + 12, 2); // Device-writable only, never NEXT/INDIRECT.
        write(u16, base + 14, 0);
        write(u16, base + available_offset + 4 + @as(u64, index % ring_size) * 2, 0);
        fence();
        write(u16, base + available_offset + 2, index +% 1);
        fence();
        write(u16, self.queue_notify, 0);
    }
    pub fn used(self: *Transport) q.Used {
        const base = self.dma.virt_addr + used_offset;
        const index = read(u16, base + 2);
        fence();
        const entry = base + 4 + @as(u64, self.queue.used % ring_size) * 8;
        return .{ .index = index, .id = read(u32, entry), .bytes = read(u32, entry + 4) };
    }
    pub fn copy(self: *Transport, out: []u8) void {
        const source: [*]const volatile u8 = @ptrFromInt(self.dma.virt_addr + data_offset);
        for (out, 0..) |*byte, i| byte.* = source[i];
    }
    pub fn wait(self: *Transport) void {
        const ctx = self.context();
        ctx.waitTicks(1);
    }
    pub fn stop(self: *Transport) bool {
        if (!self.owned or self.quiesced) return true;
        if (self.stop_attempted) return false;
        self.stop_attempted = true;
        self.ready = false;
        write(u8, self.common + 0x14, 0);
        const begin = self.now();
        var polls: u32 = 0;
        while (read(u8, self.common + 0x14) != 0) {
            const instant = self.now();
            if (polls >= 4096 or instant < begin or instant - begin >= a.entropy_max_window_ns) return false;
            polls += 1;
            self.wait();
        }
        const ctx = self.context();
        const value: u32 = self.command() & ~@as(u16, 4);
        if (ctx.pciWriteConfig32(self.pci, 4, value) != 0 or self.command() & 4 != 0) return false;
        self.quiesced = true;
        return true;
    }
    pub fn release(self: *Transport) bool {
        if (!self.stop()) return false;
        const ctx = self.context();
        if (self.dma.phys_addr != 0) {
            // Reset + bus-master readback preceded this exact allocation free.
            @memset(@as([*]u8, @ptrFromInt(self.dma.virt_addr))[0..self.dma.bytes], 0);
            ctx.freeDmaRegion(&self.dma);
            if (self.dma.phys_addr != 0) return false;
        }
        for (&self.windows) |*window| {
            if (window.cpu_address == 0) continue;
            if (self.memory.?.mmioUnmap(&window.handle, 1) != a.gfx_buffer_result_ok) return false;
            window.* = .{};
        }
        self.common = 0;
        self.notify = 0;
        if (self.saved_command) |saved| {
            if (ctx.pciWriteConfig32(self.pci, 4, saved) != 0 or self.command() != saved) return false;
            self.saved_command = null;
        }
        return true;
    }
};
fn config8(ctx: *const r4os.r4dev.DriverContext, pci: a.PciDeviceInfo, offset: u16) u8 {
    return @truncate(ctx.pciReadConfig32(pci, offset & ~@as(u16, 3)) >> @as(u5, @intCast((offset & 3) * 8)));
}
fn barBase(ctx: *const r4os.r4dev.DriverContext, pci: a.PciDeviceInfo, index: u8) Error!u64 {
    var prior: u8 = 0;
    while (prior < index) : (prior += 1) {
        const value = ctx.pciReadConfig32(pci, 0x10 + @as(u16, prior) * 4);
        if (value & 1 == 0 and (value >> 1) & 3 == 2) {
            prior += 1;
            if (prior == index) return error.Invalid;
        }
    }
    const offset: u16 = 0x10 + @as(u16, index) * 4;
    const raw = ctx.pciReadConfig32(pci, offset);
    if (raw == 0 or raw == 0xffff_ffff or raw & 1 != 0) return error.Invalid;
    const kind = (raw >> 1) & 3;
    if (kind != 0 and kind != 2) return error.Invalid;
    var base: u64 = raw & 0xffff_fff0;
    if (kind == 2) {
        if (index == 5) return error.Invalid;
        base |= @as(u64, ctx.pciReadConfig32(pci, offset + 4)) << 32;
    }
    if (base == 0 or base & 4095 != 0) return error.Invalid;
    return base;
}
fn read(comptime T: type, address: u64) T {
    return @as(*volatile T, @ptrFromInt(address)).*;
}
fn write(comptime T: type, address: u64, value: T) void {
    @as(*volatile T, @ptrFromInt(address)).* = value;
}
fn write64(address: u64, value: u64) void {
    write(u32, address, @truncate(value));
    write(u32, address + 4, @truncate(value >> 32));
}
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}
