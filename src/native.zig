// Original Virtio 1.3 2D backend. Platform lifetime, CPU mappings, output
// identities and completion publication remain in their common R4OS owners.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("wire.zig");
const Transport = @import("transport.zig").Transport;
const Error = @import("transport.zig").Error;
const gfx = @import("r4gfx_outputs");
var api: ?*const a.DriverApi = null;
var gpu: *Transport = undefined;
var memory: r4os.driver_memory.Context = undefined;
var queues: r4os.driver_queue.Context = undefined;
var outputs: r4os.driver_outputs.Context = undefined;
var display: r4os.driver_display.Context = undefined;
var binding: a.GfxBackendBinding = .{};
var transition: a.GfxNativeState = .{};
var boot: a.GfxNativeBootInfo = .{};
var buffer: a.GfxBufferReference = .{};
var attachment: a.GfxDeviceLease = .{};
var initial_read: a.GfxDeviceLease = .{};
var bytes: u64 = 0;
var scanout: u32 = 0;
var resource_serial: u32 = 0;
var resource: u32 = 0;
var created = false;
var attached = false;
var scanout_active = false;
var fault_mode = false;
var frames: u64 = 0;
var transferred: u64 = 0;
var identities: [wire.max_scanouts]a.GfxOutputId = .{a.GfxOutputId{}} ** wire.max_scanouts;
var info: wire.DisplayReply = .{};
var publication: a.GfxOutputPublication = .{};
var edid: wire.EdidReply = .{};
var report: gfx.edid.Report = .{};
var irq_enabled = false;
var irq_routes: [9]u8 = .{0xff} ** 9;
var irq_count: usize = 0;
var changes: u64 = 0;

pub fn init(driver_api: *const a.DriverApi, transport: *Transport, fault: bool) Error!void {
    if (api != null) return error.Busy;
    api = driver_api; gpu = transport; fault_mode = fault;
    const ctx = context();
    memory = ctx.memory() orelse return error.Mapping;
    queues = ctx.graphicsQueue() orelse return error.UnsupportedFeatures;
    outputs = ctx.graphicsOutputs() orelse return error.UnsupportedFeatures;
    display = ctx.graphicsDisplay() orelse return error.UnsupportedFeatures;
    if (display.bootInfo(&boot) != a.gfx_output_ok or boot.format != a.gfx_buffer_format_xrgb8888 or boot.policy != 0) return error.UnsupportedFeatures;
    try gpu.discover(driver_api);
    // Virtio's VGA compatibility contract restores VGA on whole-device reset.
    // Admit only the same physical VGA device that supplied the boot image.
    // Firmware-active Virtio queues are rejected by initialize, not reset.
    if (gpu.pci.subclass != 0 or try gpu.framebufferBase() != boot.physical_address) return error.FirmwareOwned;
    bytes = @as(u64, boot.width) * boot.height * 4;
    if (boot.width == 0 or boot.height == 0 or bytes > 64 * 1024 * 1024 or bytes > boot.byte_length) return error.Invalid;
    try gpu.initialize(true);
    try gpu.getDisplayInfo(&info);
    var found = false;
    for (info.modes[0..gpu.num_scanouts], 0..) |mode, index| if (mode.enabled != 0) {
        scanout = @intCast(index); found = true; break;
    };
    if (!found) return error.NotFound;
    const adapter = 0x0100_0000 | (@as(u32, gpu.pci.bus) << 8) | (@as(u32, gpu.pci.device) << 3) | gpu.pci.function;
    const registration = a.GfxBackendRegistration{ .adapter_id = adapter, .milestone = a.gfx_queue_milestone_device_execution, .notify_callback = @intFromPtr(&notify) };
    if (queues.register(&registration, &binding) != a.gfx_queue_ok) return error.Rejected;
    gpu.config_notify = configEvent;
    try publishOutputs();
    const descriptor = a.GfxBufferDescriptor{ .byte_length = bytes, .width = boot.width, .height = boot.height,
        .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ @as(u64, boot.width) * 4, 0, 0, 0 },
        .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source | a.gfx_buffer_usage_scanout };
    if (memory.bufferCreate(&descriptor, &buffer) != a.gfx_buffer_result_ok) return error.NoMemory;
    if (resource_serial == std.math.maxInt(u32)) return error.Exhausted;
    resource_serial += 1; resource = resource_serial;
    const create = wire.Create{ .resource = resource, .width = boot.width, .height = boot.height };
    try command(.create_2d, std.mem.asBytes(&create));
    created = true;
    const attach_request = a.GfxDeviceRequest{ .adapter_id = binding.adapter_id, .device_generation = binding.device_generation,
        .access = a.gfx_device_access_backing, .byte_length = bytes };
    if (memory.deviceAcquire(&buffer.reference, &attach_request, &attachment) != a.gfx_buffer_result_ok) return error.Mapping;
    const storage = gpu.requestStorage();
    var offset: u64 = 0;
    var count: u32 = 0;
    while (offset < bytes) {
        if (count >= @import("transport.zig").max_backing_entries) return error.Invalid;
        var segment: a.GfxDmaSegment = .{};
        if (memory.deviceSegment(&attachment, offset, &segment) != a.gfx_buffer_result_ok or
            segment.byte_length == 0 or segment.byte_length > std.math.maxInt(u32) or segment.next_offset <= offset or
            segment.next_offset != offset + segment.byte_length or segment.next_offset > bytes) return error.Mapping;
        const entry = wire.Memory{ .address = segment.dma_address, .length = @intCast(segment.byte_length) };
        @memcpy(storage[@sizeOf(wire.Attach) + @as(usize, count) * @sizeOf(wire.Memory) ..][0..@sizeOf(wire.Memory)], std.mem.asBytes(&entry));
        count += 1; offset = segment.next_offset;
    }
    const attach = wire.Attach{ .resource = resource, .count = count };
    @memcpy(storage[0..@sizeOf(wire.Attach)], std.mem.asBytes(&attach));
    try command(.attach_backing, storage[0 .. @sizeOf(wire.Attach) + @as(usize, count) * @sizeOf(wire.Memory)]);
    attached = true;
    var native = a.GfxNativeRegistration{ .backend = binding, .output = identities[scanout], .reference = buffer.reference,
        .commit_callback = @intFromPtr(&commit), .restore_callback = @intFromPtr(&restore) };
    @memcpy(native.name[0..7], "VIRTGPU");
    if (display.prepare(&native, &transition) != a.gfx_output_ok) return error.Rejected;
    if (display.transition(transition.generation, 0, &transition) != a.gfx_output_ok or transition.outcome != a.gfx_output_outcome_applied) return error.Rejected;
    try registerInterrupts();
    configEvent(); // Catch an event arriving before interrupt admission.
    log("VIRTGPU native: OK adapter={x} scanout={d} mode={d}x{d} backing-pages={d} completion=device-execution vblank=unknown", .{ binding.adapter_id, scanout, boot.width, boot.height, count });
}
fn context() r4os.r4dev.DriverContext { return r4os.r4dev.DriverContext.init(api.?); }
fn registerInterrupts() Error!void {
    if (gpu.pci.interrupt_pin == 0) return error.UnsupportedFeatures;
    const ctx = context();
    var candidates: [9]u8 = .{gpu.pci.interrupt_line} ++ .{16,17,18,19,20,21,22,23};
    for (&candidates) |route| {
        if (route >= 32 or std.mem.indexOfScalar(u8, irq_routes[0..irq_count], route) != null) continue;
        if (ctx.irqRegister(route, interrupt, 0, a.irq_flag_shared | a.irq_flag_level_low) != 0) continue;
        irq_routes[irq_count] = route; irq_count += 1;
    }
    if (irq_count == 0) return error.UnsupportedFeatures;
    @atomicStore(bool, &irq_enabled, true, .release);
}
fn stopInterrupts() bool {
    @atomicStore(bool, &irq_enabled, false, .release);
    const ctx = context();
    // Unregister synchronizes with the runtime owner before any MMIO unmap.
    for (irq_routes[0..irq_count]) |*route| {
        if (route.* == 0xff) continue;
        if (ctx.irqUnregister(route.*, interrupt, 0) != 0) return false;
        route.* = 0xff;
    }
    irq_count = 0;
    gpu.config_notify = null;
    return true;
}
fn interrupt(_: u8, _: usize) callconv(.c) u32 {
    if (!@atomicLoad(bool, &irq_enabled, .acquire)) return 0;
    return if (gpu.acknowledgeInterrupt() != 0) a.irq_result_handled else 0;
}
fn configEvent() void { _ = display.schedule(&binding); }
fn refreshOutputs() Error!void {
    if (!gpu.ready) return;
    const snapshot = try gpu.config();
    if (snapshot.events & 1 == 0) return;
    if (snapshot.scanouts != gpu.num_scanouts) return error.DeviceLost;
    gpu.acknowledgeDisplayEvent(); // Clear before reading; a later event survives.
    try gpu.getDisplayInfo(&info);
    try publishOutputs();
    changes += 1;
    log("VIRTGPU display-change={d} generation={d} host-request={d}x{d} active-surface={d}x{d} irq-worker=retained", .{ changes, identities[scanout].connection_generation, info.modes[scanout].rectangle.width, info.modes[scanout].rectangle.height, boot.width, boot.height });
}
fn command(kind: wire.Command, payload: []const u8) Error!void {
    if (try gpu.execute(kind, payload, .ok) != .ok) return error.Rejected;
}
fn publishOutputs() Error!void {
    for (info.modes[0..gpu.num_scanouts], 0..) |mode, index| {
        publication = .{ .backend = binding, .info = .{
            .identity = .{ .adapter_id = binding.adapter_id, .connector_id = @intCast(index + 1), .device_generation = binding.device_generation },
            .connector_kind = a.gfx_output_kind_virtual, .possible_heads = 1, .possible_planes = 1, .possible_plls = 1,
            .limits = .{ .head_mask = 1, .plane_mask = 1, .pll_mask = 1, .max_width = boot.width, .max_height = boot.height } } };
        if (mode.enabled != 0) {
            publication.info.flags = a.gfx_output_flag_connected;
            // This stage supports only the boot-sized primary surface. Host
            // window dimensions and EDID modes are separate receiver facts.
            publication.info.mode_count = 1; publication.info.preferred_mode_id = 1;
            publication.modes[0] = .{ .mode_id = 1, .width = boot.width, .height = boot.height,
                .flags = a.gfx_output_mode_geometry_only | a.gfx_output_mode_preferred };
            if (gpu.accepted_features & wire.feature_edid != 0) {
                try gpu.getEdid(@intCast(index), &edid);
                publication.info.edid_bytes = edid.length;
                @memcpy(publication.edid[0..edid.length], edid.data[0..edid.length]);
                gfx.edid.parse(edid.data[0..edid.length], &report) catch { report = .{}; report.warnings = gfx.edid.Warning.malformed; };
                log("VIRTGPU output={d} host-request={d}x{d} edid={d} receiver-modes={d} warnings={x} source=fixed-boot-geometry", .{ index + 1, mode.rectangle.width, mode.rectangle.height, edid.length, report.mode_count, report.warnings });
            }
        }
        if (outputs.publish(&publication, &identities[index]) != a.gfx_output_ok) return error.Rejected;
    }
}
fn fullRect() wire.Rect { return .{ .width = boot.width, .height = boot.height }; }
fn upload(rectangle: wire.Rect, offset: u64) Error!void {
    const transfer = wire.Transfer{ .rectangle = rectangle, .offset = offset, .resource = resource };
    try command(.transfer_2d, std.mem.asBytes(&transfer));
    const flush = wire.Flush{ .rectangle = rectangle, .resource = resource };
    try command(.flush, std.mem.asBytes(&flush));
}
fn releaseInitialRead() bool {
    if (initial_read.lease.id == 0) return true;
    if (memory.deviceRelease(&initial_read, 1) != a.gfx_buffer_result_ok) return false;
    initial_read = .{};
    return true;
}
fn resetForBoot() bool {
    if (!gpu.reset()) return false;
    scanout_active = false;
    created = false; attached = false;
    return releaseInitialRead();
}
fn sameBoot(value: *const a.GfxNativeBootInfo) bool {
    return value.physical_address != 0 and value.physical_address == boot.physical_address and value.byte_length == boot.byte_length and
        value.width == boot.width and value.height == boot.height and value.pitch == boot.pitch and value.format == boot.format;
}
fn commit(_: u64, _: u64, saved: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    if (!sameBoot(saved) or !gpu.ready or !attached) return 2;
    const request = a.GfxDeviceRequest{ .adapter_id = binding.adapter_id, .device_generation = binding.device_generation, .byte_length = bytes };
    if (memory.deviceAcquire(&buffer.reference, &request, &initial_read) != a.gfx_buffer_result_ok) return 2;
    upload(fullRect(), 0) catch return if (resetForBoot()) 2 else 3;
    if (!releaseInitialRead()) return if (resetForBoot()) 2 else 3;
    const set = wire.Scanout{ .rectangle = fullRect(), .scanout = scanout, .resource = resource };
    command(.set_scanout, std.mem.asBytes(&set)) catch return if (resetForBoot()) 2 else 3;
    scanout_active = true;
    const flush = wire.Flush{ .rectangle = fullRect(), .resource = resource };
    command(.flush, std.mem.asBytes(&flush)) catch return if (resetForBoot()) 2 else 3;
    return 1;
}
fn restore(_: u64, _: u64, saved: *const a.GfxNativeBootInfo) callconv(.c) i32 {
    if (!sameBoot(saved) or !resetForBoot() or !releaseStorage()) return 0;
    log("VIRTGPU recovery: OK reset=acknowledged boot-vga=restored frames={d} transferred={d}", .{ frames, transferred });
    return 1;
}
fn notify(_: usize) callconv(.c) i32 {
    refreshOutputs() catch |err| {
        log("VIRTGPU display-change: error={s}", .{@errorName(err)});
        gpu.ready = false;
        // Do not invent fresh receiver data after a failed refresh. A later
        // presentation observes the failed transport and performs recovery.
        for (identities[0..gpu.num_scanouts]) |identity| _ = outputs.withdraw(&identity);
    };
    var job: a.GfxDriverJob = .{};
    const taken = queues.take(&binding, &job);
    if (taken == a.gfx_queue_error_busy or taken == a.gfx_queue_error_device_lost or taken == a.gfx_queue_error_stale) return 0;
    if (taken != a.gfx_queue_ok) return -1;
    var success = false;
    if (gpu.ready and job.operation == a.gfx_queue_operation_barrier) {
        gpu.getDisplayInfo(&info) catch return finish(&job, false);
        success = true;
    } else if (gpu.ready and scanout_active and job.operation == a.gfx_queue_operation_upload and
        std.meta.eql(job.source_buffer, buffer.buffer) and
        job.target_buffer.id == 0 and job.target_offset == 0)
    {
        const rectangle = wire.uploadRegion(boot.width, boot.height, job.source_offset, job.byte_length) catch return finish(&job, false);
        if (fault_mode and frames == 2) {
            gpu.inject_timeout = true;
            log("VIRTGPU fault: injected missing control completion; DMA remains retained until reset", .{});
        }
        upload(rectangle, job.source_offset) catch return finish(&job, false);
        frames += 1; transferred += @as(u64, rectangle.width) * rectangle.height * 4;
        success = true;
        if (frames <= 3 or frames % 16 == 0) log("VIRTGPU frame={d} bo={d}:{d} fence={d}:{d} completion=device-execution bytes={d}", .{ frames, buffer.buffer.id, buffer.buffer.generation, job.fence.timeline, job.fence.point, transferred });
    }
    return finish(&job, success);
}
fn finish(job: *const a.GfxDriverJob, success: bool) i32 {
    // A validated device error has completed physically. A timeout, bad used
    // entry or missing response cannot release the queue's source lease.
    const quiesced: u32 = @intFromBool(gpu.command_owner.pending == 0 and !gpu.command_owner.poisoned);
    return if (queues.complete(&job.fence, if (success) a.gfx_queue_result_complete else a.gfx_queue_result_failed, quiesced) == a.gfx_queue_ok) 0 else -1;
}
pub fn shutdown() bool {
    if (api == null) return true;
    const ctx = context();
    if (transition.retained != 0) {
        var current: a.GfxNativeBootInfo = .{};
        if (display.bootInfo(&current) != a.gfx_output_ok) return false;
        if (current.state != a.display_state_bootfb) {
            const operation: u32 = if (current.state == a.display_state_preparing) 1 else 2;
            const generation = if (operation == 1) transition.generation else current.generation;
            if (display.transition(generation, operation, &transition) != a.gfx_output_ok or transition.retained != 0) return false;
        } else transition = .{};
    }
    if (scanout_active) return false;
    // Explicit detach/unref on orderly teardown; any failed command still
    // requires reset ACK before attachment, BO or transport storage release.
    if (gpu.ready and attached) {
        const detach = wire.Resource{ .resource = resource };
        command(.detach_backing, std.mem.asBytes(&detach)) catch {};
    }
    if (gpu.ready and created) {
        const unref = wire.Resource{ .resource = resource };
        command(.unref, std.mem.asBytes(&unref)) catch {};
    }
    if (!resetForBoot()) return false;
    if (binding.device_generation != 0) {
        const deadline = ctx.tickCount() +| @as(u64, @max(ctx.timerFrequency(), 1));
        while (true) {
            const rc = queues.unregister(&binding, 1);
            if (rc == a.gfx_queue_ok or rc == a.gfx_queue_error_unsupported) { binding = .{}; break; }
            if (rc != a.gfx_queue_error_busy or ctx.tickCount() >= deadline) return false;
            ctx.waitTicks(1);
        }
    }
    if (!releaseStorage()) return false;
    api = null; resource = 0; frames = 0; transferred = 0; changes = 0; transition = .{};
    return true;
}
fn releaseStorage() bool {
    if (!stopInterrupts()) return false;
    if (attachment.lease.id != 0) {
        if (memory.deviceRelease(&attachment, 1) != a.gfx_buffer_result_ok) return false;
        attachment = .{};
    }
    if (buffer.reference.id != 0) {
        if (memory.bufferRelease(&buffer.reference) != a.gfx_buffer_result_ok) return false;
        buffer = .{};
    }
    if (!gpu.close()) return false;
    return true;
}
fn log(comptime format: []const u8, args: anytype) void {
    var storage: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&storage, format, args) catch return;
    context().logInfo(text.ptr);
}
