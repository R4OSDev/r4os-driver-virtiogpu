// Modern split-ring Virtio-PCI transport. DriverApi's wait-spanning owner
// serializes task callers. IRQ handlers must never call these RPC methods.
const std = @import("std");
const r4os = @import("r4os");
const wire = @import("wire.zig");
const a = r4os.abi;
pub const Error = wire.Error || error{ NotFound, Mapping, NoMemory, DeviceLost, Timeout, Rejected, FirmwareOwned };
const max_bar_span = 1024 * 1024;
pub const max_backing_entries = 16384; // 64 MB with page-bounded backing.
pub const request_capacity = @sizeOf(wire.Attach) + max_backing_entries * @sizeOf(wire.Memory);
const request_offset = 4096;
const response_offset = std.mem.alignForward(usize, request_offset + request_capacity, 4096);
const dma_bytes = response_offset + 4096;
const available_offset = 512;
const used_offset = 1024;
const ring_size: u16 = 16;
const response_capacity = @sizeOf(wire.EdidReply);
const Status = struct { const acknowledge = 1; const driver = 2; const ready = 4; const features = 8; const needs_reset = 64; const failed = 128; };
const Capability = struct { bar: u8 = 0, offset: u32 = 0, length: u32 = 0 };
const Config = struct { generation: u8, events: u32, scanouts: u32 };

pub const Transport = struct {
    phase: enum { idle, memory, discovery, mmio, features, queue, commands } = .idle,
    last_status: i32 = 0,
    last_address: u64 = 0,
    api: ?*const a.DriverApi = null,
    memory: ?r4os.driver_memory.Context = null,
    pci: a.PciDeviceInfo = .{},
    windows: [6]a.GfxMmioWindow = .{a.GfxMmioWindow{}} ** 6,
    capabilities: [5]Capability = .{Capability{}} ** 5,
    common: u64 = 0,
    device_config: u64 = 0,
    isr: u64 = 0,
    notify: u64 = 0,
    notify_multiplier: u32 = 0,
    queue_notify: u64 = 0,
    dma: a.DmaBuffer = .{},
    command_owner: wire.CommandOwner = .{},
    available_index: u16 = 0,
    accepted_features: u64 = 0,
    num_scanouts: u32 = 0,
    owned: bool = false,
    ready: bool = false,
    response_bytes: u32 = 0,
    inject_timeout: bool = false,
    config_notify: ?*const fn () void = null,
    saved_pci_command: ?u16 = null,

    pub fn framebufferBase(self: *const Transport) Error!u64 {
        const ctx = self.context();
        return barBase(&ctx, self.pci, 0);
    }

    fn context(self: *const Transport) r4os.r4dev.DriverContext {
        return r4os.r4dev.DriverContext.init(self.api.?);
    }
    fn readConfig8(ctx: *const r4os.r4dev.DriverContext, pci: a.PciDeviceInfo, offset: u16) u8 {
        return @truncate(ctx.pciReadConfig32(pci, offset & ~@as(u16, 3)) >> @as(u5, @intCast((offset & 3) * 8)));
    }
    fn barBase(ctx: *const r4os.r4dev.DriverContext, pci: a.PciDeviceInfo, index: u8) Error!u64 {
        if (index >= 6) return error.Invalid;
        var prior: u8 = 0;
        while (prior < index) : (prior += 1) {
            const value = ctx.pciReadConfig32(pci, 0x10 + @as(u16, prior) * 4);
            if (value & 1 == 0 and (value >> 1) & 3 == 2) {
                prior += 1;
                if (prior == index) return error.Invalid; // Upper half is not another BAR.
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
        if (base == 0) return error.Invalid;
        return base;
    }

    // Discovery performs only config reads and owner-bound CPU mappings.
    // No BAR sizing write, reset or scanout operation is hidden here.
    pub fn discover(self: *Transport, api: *const a.DriverApi) Error!void {
        if (self.api != null) return error.Busy;
        const ctx = r4os.r4dev.DriverContext.init(api);
        self.api = api;
        self.phase = .memory;
        self.memory = ctx.memory() orelse return error.Mapping;
        self.phase = .discovery;
        var found = false;
        for (0..ctx.pciDeviceCount()) |index| {
            var pci: a.PciDeviceInfo = .{};
            if (ctx.pciDeviceAt(@intCast(index), &pci) != 0) continue;
            if (pci.vendor_id != wire.vendor or pci.device_id != wire.device or pci.class_code != 3) continue;
            self.pci = pci;
            found = true;
            break;
        }
        if (!found) return error.NotFound;
        if (ctx.pciReadConfig32(self.pci, 4) & (1 << 20) == 0) return error.Invalid;
        var seen: [256]bool = .{false} ** 256;
        var pointer: u16 = readConfig8(&ctx, self.pci, 0x34);
        var count: usize = 0;
        while (pointer != 0) {
            if (pointer < 0x40 or pointer > 0xfc or pointer & 3 != 0 or seen[pointer] or count >= 48) return error.Invalid;
            seen[pointer] = true;
            count += 1;
            const next: u16 = readConfig8(&ctx, self.pci, pointer + 1);
            if (readConfig8(&ctx, self.pci, pointer) == 9) {
                const length: u16 = readConfig8(&ctx, self.pci, pointer + 2);
                const kind = readConfig8(&ctx, self.pci, pointer + 3);
                if (length < 16 or pointer + length > 256) return error.Invalid;
                if (kind >= 1 and kind <= 4) {
                    if (self.capabilities[kind].length != 0) return error.Invalid;
                    const bar = readConfig8(&ctx, self.pci, pointer + 4);
                    const offset = ctx.pciReadConfig32(self.pci, pointer + 8);
                    const bytes = ctx.pciReadConfig32(self.pci, pointer + 12);
                    if (bar >= 6 or bytes == 0 or offset >= max_bar_span or bytes > max_bar_span - offset) return error.Invalid;
                    self.capabilities[kind] = .{ .bar = bar, .offset = offset, .length = bytes };
                    if (kind == 2) {
                        if (length < 20) return error.Invalid;
                        self.notify_multiplier = ctx.pciReadConfig32(self.pci, pointer + 16);
                    }
                }
            }
            pointer = next;
        }
        if (self.capabilities[1].length < 56 or self.capabilities[2].length < 2 or self.capabilities[3].length < 1 or
            self.capabilities[4].length < 16 or self.capabilities[1].offset & 7 != 0 or self.capabilities[4].offset & 3 != 0) return error.Invalid;
        var spans: [6]u64 = .{0} ** 6;
        for (self.capabilities[1..], 0..) |cap, index| {
            for (self.capabilities[1 .. index + 1]) |prior| {
                if (prior.bar == cap.bar and cap.offset < prior.offset + prior.length and prior.offset < cap.offset + cap.length) return error.Invalid;
            }
            spans[cap.bar] = @max(spans[cap.bar], @as(u64, cap.offset) + cap.length);
        }
        for (spans, 0..) |span, index| {
            if (span == 0) continue;
            const base = try barBase(&ctx, self.pci, @intCast(index));
            const bytes = std.mem.alignForward(u64, span, 4096);
            // MMIO capabilities are bounded separately from framebuffer BAR0.
            // Source limits describe only the requested capability aperture.
            const request = a.GfxMmioRequest{ .resource_base = base, .resource_bytes = bytes, .byte_length = bytes,
                .cache_policy = a.gfx_buffer_cache_uncached };
            self.phase = .mmio;
            self.last_address = base;
            self.last_status = self.memory.?.mmioMap(&request, &self.windows[index]);
            if (self.last_status != a.gfx_buffer_result_ok) return error.Mapping;
        }
        self.common = self.address(1);
        self.notify = self.address(2);
        self.isr = self.address(3);
        self.device_config = self.address(4);
    }
    fn address(self: *const Transport, kind: usize) u64 {
        const cap = self.capabilities[kind];
        return self.windows[cap.bar].cpu_address + cap.offset;
    }

    pub fn initialize(self: *Transport, allow_edid: bool) Error!void {
        if (self.common == 0 or self.owned) return error.Invalid;
        const ctx = self.context();
        self.phase = .features;
        // A firmware-owned queue/scanout must not be reset during discovery.
        // This first driver stage handles a quiescent VGA-compatible device.
        if (read(u8, self.common + 0x14) != 0) return error.FirmwareOwned;
        self.saved_pci_command = @truncate(ctx.pciReadConfig32(self.pci, 4));
        self.last_status = ctx.pciEnableBusMaster(self.pci, a.pci_enable_memory_space);
        if (self.last_status != 0) return error.Mapping;
        self.owned = true;
        write(u8, self.common + 0x14, Status.acknowledge | Status.driver);
        write(u32, self.common, 0);
        const low = read(u32, self.common + 4);
        write(u32, self.common, 1);
        const high = read(u32, self.common + 4);
        self.accepted_features = try wire.features(@as(u64, low) | (@as(u64, high) << 32));
        if (!allow_edid) self.accepted_features &= ~wire.feature_edid;
        write(u32, self.common + 8, 0);
        write(u32, self.common + 12, @truncate(self.accepted_features));
        write(u32, self.common + 8, 1);
        write(u32, self.common + 12, @truncate(self.accepted_features >> 32));
        write(u8, self.common + 0x14, Status.acknowledge | Status.driver | Status.features);
        if (read(u8, self.common + 0x14) & Status.features == 0) return error.UnsupportedFeatures;
        if (read(u16, self.common + 0x12) < 2) return error.Invalid;
        self.phase = .queue;
        write(u16, self.common + 0x10, 0xffff); // No MSI-X configuration vector.
        write(u16, self.common + 0x16, 0);
        if (read(u16, self.common + 0x18) < ring_size or read(u16, self.common + 0x1c) != 0) return error.Invalid;
        const notify_index = read(u16, self.common + 0x1e);
        const notify_offset = @as(u64, notify_index) * self.notify_multiplier;
        if (notify_offset > self.capabilities[2].length - 2 or (self.notify + notify_offset) & 1 != 0) return error.Invalid;
        self.queue_notify = self.notify + notify_offset;
        if (ctx.allocDmaRegion(dma_bytes, 4096, &self.dma) != 0) return error.NoMemory;
        if (self.dma.bytes < dma_bytes or self.dma.virt_addr == 0 or self.dma.phys_addr == 0 or
            self.dma.phys_addr & 4095 != 0 or self.dma.virt_addr & 4095 != 0) return error.Invalid;
        @memset(self.storage()[0..dma_bytes], 0);
        write(u16, self.dma.virt_addr + available_offset, 1); // Bounded polled control RPC; suppress used interrupts.
        write(u16, self.common + 0x18, ring_size);
        write(u16, self.common + 0x1a, 0xffff);
        write64(self.common + 0x20, self.dma.phys_addr);
        write64(self.common + 0x28, self.dma.phys_addr + available_offset);
        write64(self.common + 0x30, self.dma.phys_addr + used_offset);
        barrier();
        write(u16, self.common + 0x1c, 1);
        if (read(u16, self.common + 0x1c) != 1) return error.Rejected;
        write(u8, self.common + 0x14, Status.acknowledge | Status.driver | Status.features | Status.ready);
        if (read(u8, self.common + 0x14) != Status.acknowledge | Status.driver | Status.features | Status.ready) return error.DeviceLost;
        self.ready = true;
        const snapshot = try self.config();
        if (snapshot.scanouts == 0 or snapshot.scanouts > wire.max_scanouts) return error.Invalid;
        self.num_scanouts = snapshot.scanouts;
        self.phase = .commands;
    }
    pub fn config(self: *const Transport) Error!Config {
        if (self.device_config == 0) return error.Invalid;
        for (0..4) |_| {
            const generation = read(u8, self.common + 0x15);
            const events = read(u32, self.device_config);
            const scanouts = read(u32, self.device_config + 8);
            barrier();
            if (generation == read(u8, self.common + 0x15)) return .{ .generation = generation, .events = events, .scanouts = scanouts };
        }
        return error.Busy;
    }
    pub fn acknowledgeDisplayEvent(self: *Transport) void {
        write(u32, self.device_config + 4, 1);
    }
    pub fn acknowledgeInterrupt(self: *Transport) u8 {
        const bits = read(u8, self.isr); // Read-to-clear deasserts shared INTx.
        if (bits & 2 != 0) if (self.config_notify) |notify_config| notify_config();
        return bits;
    }
    fn storage(self: *Transport) []u8 {
        const pointer: [*]u8 = @ptrFromInt(self.dma.virt_addr);
        return pointer[0..self.dma.bytes];
    }
    pub fn requestStorage(self: *Transport) []u8 {
        return self.storage()[request_offset .. request_offset + request_capacity];
    }
    pub fn response(self: *Transport) []const u8 {
        return self.storage()[response_offset .. response_offset + self.response_bytes];
    }

    // Buffers are borrowed only until the next command. The wire owner holds
    // the DMA area on timeout/malformed completion; close needs reset ACK.
    pub fn execute(self: *Transport, command: wire.Command, input: []const u8, expected: wire.Response) Error!wire.Response {
        if (!self.ready or input.len < @sizeOf(wire.Header) or input.len > request_capacity) return error.Invalid;
        const serial = try self.command_owner.begin();
        const request = self.requestStorage();
        if (request.ptr != input.ptr) @memcpy(request[0..input.len], input);
        const header = wire.Header.request(command, serial);
        @memcpy(request[0..@sizeOf(wire.Header)], std.mem.asBytes(&header));
        @memset(self.storage()[response_offset .. response_offset + response_capacity], 0);
        const descriptors: *[ring_size]wire.Descriptor = @ptrFromInt(self.dma.virt_addr);
        descriptors[0] = .{ .address = self.dma.phys_addr + request_offset, .length = @intCast(input.len), .flags = 1, .next = 1 };
        descriptors[1] = .{ .address = self.dma.phys_addr + response_offset, .length = response_capacity, .flags = 2 };
        write(u16, self.dma.virt_addr + available_offset + 4 + @as(u64, self.available_index % ring_size) * 2, 0);
        barrier();
        self.available_index +%= 1;
        write(u16, self.dma.virt_addr + available_offset + 2, self.available_index);
        barrier();
        write(u16, self.queue_notify, 0);
        const ctx = self.context();
        const deadline = ctx.tickCount() +| @as(u64, @max(ctx.timerFrequency(), 1)) * 2;
        var spins: u32 = 0;
        while (true) {
            const index = read(u16, self.dma.virt_addr + used_offset + 2);
            if (index != self.command_owner.used_index and !self.inject_timeout) {
                barrier();
                const entry_address = self.dma.virt_addr + used_offset + 4 + @as(u64, self.command_owner.used_index % ring_size) * @sizeOf(wire.Used);
                const entry = wire.Used{ .head = read(u32, entry_address), .length = read(u32, entry_address + 4) };
                const result = self.command_owner.accept(index, entry, self.storage()[response_offset .. response_offset + response_capacity], expected) catch |err| {
                    self.ready = false;
                    return err;
                };
                self.response_bytes = entry.length;
                _ = self.acknowledgeInterrupt();
                return result;
            }
            if (read(u8, self.common + 0x14) & (Status.needs_reset | Status.failed) != 0) {
                self.ready = false;
                return error.DeviceLost;
            }
            if (ctx.tickCount() >= deadline) {
                self.command_owner.cancel(serial) catch {};
                self.ready = false;
                return error.Timeout;
            }
            if (spins < 128) {
                spins += 1;
                asm volatile ("pause");
            } else ctx.waitTicks(1);
        }
    }
    pub fn getDisplayInfo(self: *Transport, output: *wire.DisplayReply) Error!void {
        const request = wire.Header{};
        if (try self.execute(.display_info, std.mem.asBytes(&request), .display_info) != .display_info) return error.Rejected;
        @memcpy(std.mem.asBytes(output), self.response()[0..@sizeOf(wire.DisplayReply)]);
        for (output.modes) |mode| {
            if (mode.enabled > 1 or mode.flags != 0 or (mode.enabled == 1 and (mode.rectangle.width == 0 or mode.rectangle.height == 0))) return error.Malformed;
        }
    }
    pub fn getEdid(self: *Transport, scanout: u32, output: *wire.EdidReply) Error!void {
        if (self.accepted_features & wire.feature_edid == 0) return error.UnsupportedFeatures;
        if (scanout >= self.num_scanouts) return error.Invalid;
        const request = wire.EdidRequest{ .scanout = scanout };
        if (try self.execute(.get_edid, std.mem.asBytes(&request), .edid) != .edid) return error.Rejected;
        @memcpy(std.mem.asBytes(output), self.response()[0..@sizeOf(wire.EdidReply)]);
        try wire.normalizeEdid(output);
    }

    // Caller must hold display takeover/recovery when a native scanout is
    // active. Status-zero proves DMA stop; restoration of the particular boot
    // display is a separate display-owner decision, never assumed here.
    pub fn reset(self: *Transport) bool {
        if (!self.owned) return true;
        self.ready = false;
        write(u8, self.common + 0x14, 0);
        const ctx = self.context();
        const deadline = ctx.tickCount() +| @as(u64, @max(ctx.timerFrequency(), 1));
        while (read(u8, self.common + 0x14) != 0) {
            if (ctx.tickCount() >= deadline) return false;
            ctx.waitTicks(1);
        }
        barrier();
        self.command_owner.resetAcknowledged();
        self.owned = false;
        self.available_index = 0;
        return true;
    }
    pub fn close(self: *Transport) bool {
        if (self.api == null) return true;
        if (!self.reset()) return false;
        const ctx = self.context();
        if (self.dma.virt_addr != 0) {
            ctx.freeDmaRegion(&self.dma);
            self.dma = .{};
        }
        var complete = true;
        if (self.memory) |memory| {
            for (&self.windows) |*window| {
                if (window.handle.id == 0) continue;
                if (memory.mmioUnmap(&window.handle, 1) == a.gfx_buffer_result_ok) window.* = .{} else complete = false;
            }
            if (memory.collect() != a.gfx_buffer_result_ok) complete = false;
        }
        if (complete) {
            if (self.saved_pci_command) |command_| {
                // Upper status half is write-one-to-clear: never echo it.
                if (ctx.pciWriteConfig32(self.pci, 4, command_) != 0) return false;
                if (@as(u16, @truncate(ctx.pciReadConfig32(self.pci, 4))) != command_) return false;
            }
            const serial = self.command_owner.serial;
            self.* = .{};
            self.command_owner.serial = serial;
        }
        return complete;
    }
};

fn read(comptime T: type, address: u64) T {
    const pointer: *volatile T = @ptrFromInt(address);
    return pointer.*;
}
fn write(comptime T: type, address: u64, value: T) void {
    const pointer: *volatile T = @ptrFromInt(address);
    pointer.* = value;
}
fn write64(address: u64, value: u64) void {
    write(u32, address, @truncate(value));
    write(u32, address + 4, @truncate(value >> 32));
}
fn barrier() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}
