//! Additional Virtio 2D scanouts. Each output owns two host resources. Guest
//! image pages stay pinned by their actual queue job until TRANSFER and
//! DETACH have completed; neither a CPU copy nor a vblank claim is invented.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const wire = @import("wire.zig");
const transport = @import("transport.zig");
const Error = transport.Error;
const capacity = a.gfx_output_max_assignments;
pub const Context = struct {
    gpu: *transport.Transport,
    memory: *r4os.driver_memory.Context,
    queue: *r4os.driver_queue.Context,
    display: *r4os.driver_display.Context,
    binding: *const a.GfxBackendBinding,
    serial: *u32,
};
const Output = struct {
    target: a.GfxOutputTarget = .{},
    width: u32 = 0,
    height: u32 = 0,
    resources: [2]u32 = @splat(0),
    created: [2]bool = @splat(false),
    attached: [2]bool = @splat(false),
    displayed: ?u1 = null,
    active: bool = false,
    primary: bool = false,
    reset: bool = false,
    initial: a.GfxBufferReference = .{},
    mapping: a.GfxBufferMap = .{},
    backing: a.GfxDeviceLease = .{},
    reading: a.GfxDeviceLease = .{},
    source: ?a.GfxFence = null,
    frames: u64 = 0,
};
var slots: [capacity]Output = @splat(.{});

pub fn adoptPrimary(ctx: Context, identity: a.GfxOutputId, head: u32, generation: u64, width: u32, height: u32) Error!void {
    if (!ctx.display.supportsOutputs()) return;
    if (head >= slots.len or slots[head].target.connector_id != 0) return error.Invalid;
    const output = &slots[head];
    output.* = .{ .width = width, .height = height, .primary = true,
        .target = .{ .adapter_id = identity.adapter_id, .connector_id = identity.connector_id,
            .device_generation = identity.device_generation, .connection_generation = identity.connection_generation,
            .head_id = head, .display_generation = generation } };
    for (0..2) |index| {
        if (ctx.serial.* == std.math.maxInt(u32)) return error.Exhausted;
        ctx.serial.* += 1; output.resources[index] = ctx.serial.*; output.created[index] = true;
        try command(ctx, .create_2d, std.mem.asBytes(&wire.Create{ .resource = output.resources[index], .width = width, .height = height }));
    }
    const info: a.DisplayPresentationInfo = .{ .flags = a.display_presentation_info_native | a.display_presentation_info_active | a.display_presentation_info_system_source,
        .head_id = head, .backend = ctx.binding.*, .display_generation = generation, .sequence = 1,
        .width = width, .height = height, .format = a.gfx_buffer_format_xrgb8888, .policies = 7, .buffer_count = 2, .plane_count = 1 };
    try displayResult(ctx, "primary-info", ctx.display.presentationInfo(&info));
    output.active = true;
}
pub fn primaryPresented(head: u32) bool { return head < slots.len and slots[head].primary and slots[head].displayed != null; }
pub fn primaryRestored(head: u32) void { if (head < slots.len and slots[head].primary) slots[head].displayed = null; }

fn command(ctx: Context, kind: wire.Command, bytes: []const u8) Error!void {
    const reply = ctx.gpu.execute(kind, bytes, .ok) catch |err| {
        log(ctx, "VIRTGPU output command: operation={s} error={s}", .{ @tagName(kind), @errorName(err) });
        return err;
    };
    if (reply != .ok) return error.Rejected;
}
fn displayResult(ctx: Context, operation: []const u8, result: i32) Error!void {
    if (result == a.gfx_output_ok) return;
    log(ctx, "VIRTGPU output error: operation={s} result={d}", .{ operation, result });
    return error.Rejected;
}
fn rectangle(output: *const Output) wire.Rect { return .{ .width = output.width, .height = output.height }; }
fn detach(ctx: Context, output: *Output, index: usize) Error!void {
    if (!output.attached[index]) return;
    try command(ctx, .detach_backing, std.mem.asBytes(&wire.Resource{ .resource = output.resources[index] }));
    output.attached[index] = false;
}
fn releaseInitial(ctx: Context, output: *Output) Error!void {
    if (output.attached[0] or output.attached[1]) return error.Busy;
    if (output.mapping.lease.id != 0) {
        if (ctx.memory.bufferUnmap(&output.mapping.lease) != a.gfx_buffer_result_ok) return error.Mapping;
        output.mapping = .{};
    }
    if (output.reading.lease.id != 0) {
        if (ctx.memory.deviceRelease(&output.reading, 1) != a.gfx_buffer_result_ok) return error.Mapping;
        output.reading = .{};
    }
    if (output.backing.lease.id != 0) {
        if (ctx.memory.deviceRelease(&output.backing, 1) != a.gfx_buffer_result_ok) return error.Mapping;
        output.backing = .{};
    }
    if (output.initial.reference.id != 0) {
        if (ctx.memory.bufferRelease(&output.initial.reference) != a.gfx_buffer_result_ok) return error.Mapping;
        output.initial = .{};
    }
}
fn attach(ctx: Context, output: *Output, index: usize, pitch: u64, fence: ?a.GfxFence) Error!void {
    if (output.attached[index] or pitch < @as(u64, output.width) * 4) return error.Invalid;
    const storage = ctx.gpu.requestStorage();
    var count: u32 = 0;
    // Virtio 2D backing is packed. Page fragments are concatenated row by
    // row, excluding producer pitch padding, without reading its pixels.
    for (0..output.height) |row| {
        var column: u64 = 0;
        while (column < @as(u64, output.width) * 4) {
            if (count == transport.max_backing_entries) return error.Invalid;
            const offset = @as(u64, row) * pitch + column;
            var segment: a.GfxDmaSegment = .{};
            const rc = if (fence) |source| ctx.queue.segment(&source, 0, offset, std.math.maxInt(u64), &segment)
                else ctx.memory.deviceSegment(&output.backing, offset, &segment);
            if (rc != a.gfx_buffer_result_ok or segment.byte_length == 0 or segment.next_offset <= offset or
                segment.next_offset != offset + segment.byte_length) return error.Mapping;
            const length: u32 = @intCast(@min(segment.byte_length, @as(u64, output.width) * 4 - column));
            const item: wire.Memory = .{ .address = segment.dma_address, .length = length };
            @memcpy(storage[@sizeOf(wire.Attach) + @as(usize, count) * @sizeOf(wire.Memory) ..][0..@sizeOf(wire.Memory)], std.mem.asBytes(&item));
            count += 1; column += length;
        }
    }
    const request: wire.Attach = .{ .resource = output.resources[index], .count = count };
    @memcpy(storage[0..@sizeOf(wire.Attach)], std.mem.asBytes(&request));
    // Latch ownership before publication; an uncertain reply requires reset.
    output.attached[index] = true;
    try command(ctx, .attach_backing, storage[0 .. @sizeOf(wire.Attach) + @as(usize, count) * @sizeOf(wire.Memory)]);
}
fn transfer(ctx: Context, output: *Output, index: usize) Error!void {
    try command(ctx, .transfer_2d, std.mem.asBytes(&wire.Transfer{ .rectangle = rectangle(output), .resource = output.resources[index] }));
}
fn show(ctx: Context, output: *Output, index: u1) Error!void {
    try command(ctx, .set_scanout, std.mem.asBytes(&wire.Scanout{ .rectangle = rectangle(output), .scanout = output.target.head_id,
        .resource = output.resources[index] }));
    output.displayed = index;
    try command(ctx, .flush, std.mem.asBytes(&wire.Flush{ .rectangle = rectangle(output), .resource = output.resources[index] }));
}
fn setup(ctx: Context, output: *Output, identity: a.GfxOutputId, head: u32, width: u32, height: u32) Error!void {
    const bytes = @as(u64, width) * height * 4;
    if (width == 0 or height == 0 or width > 65536 or height > 65536 or bytes > 64 * 1024 * 1024) return error.Invalid;
    output.width = width; output.height = height;
    const registration: a.GfxAdditionalOutput = .{ .backend = ctx.binding.*, .output = identity, .head_id = head,
        .width = width, .height = height, .format = a.gfx_buffer_format_xrgb8888 };
    try displayResult(ctx, "register", ctx.display.outputRegister(&registration, &output.target));
    const descriptor: a.GfxBufferDescriptor = .{ .byte_length = bytes, .width = width, .height = height,
        .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1, .plane_pitches = .{ @as(u64, width) * 4, 0, 0, 0 },
        .usage = a.gfx_buffer_usage_cpu_read | a.gfx_buffer_usage_cpu_write | a.gfx_buffer_usage_transfer_source };
    if (ctx.memory.bufferCreate(&descriptor, &output.initial) != a.gfx_buffer_result_ok) return error.NoMemory;
    if (ctx.memory.bufferMap(&output.initial.reference, a.gfx_buffer_map_write, 0, bytes, &output.mapping) != a.gfx_buffer_result_ok or
        output.mapping.cpu_address == 0 or output.mapping.byte_length < bytes) return error.Mapping;
    @memset(@as([*]u8, @ptrFromInt(output.mapping.cpu_address))[0..bytes], 0);
    if (ctx.memory.bufferUnmap(&output.mapping.lease) != a.gfx_buffer_result_ok) return error.Mapping;
    output.mapping = .{};
    var request: a.GfxDeviceRequest = .{ .adapter_id = ctx.binding.adapter_id, .device_generation = ctx.binding.device_generation,
        .access = a.gfx_device_access_backing, .byte_length = bytes };
    if (ctx.memory.deviceAcquire(&output.initial.reference, &request, &output.backing) != a.gfx_buffer_result_ok) return error.Mapping;
    request.access = 0; // GfxDeviceRequest access0: device read, separate from backing retention.
    if (ctx.memory.deviceAcquire(&output.initial.reference, &request, &output.reading) != a.gfx_buffer_result_ok) return error.Mapping;
    for (0..2) |index| {
        if (ctx.serial.* == std.math.maxInt(u32)) return error.Exhausted;
        ctx.serial.* += 1; output.resources[index] = ctx.serial.*;
        // A timed-out CREATE can still have allocated a host resource.
        output.created[index] = true;
        try command(ctx, .create_2d, std.mem.asBytes(&wire.Create{ .resource = output.resources[index], .width = width, .height = height }));
        try attach(ctx, output, index, @as(u64, width) * 4, null);
        try transfer(ctx, output, index);
        // SET_SCANOUT requires attached backing even after the first
        // transfer. Keep the initial visible resource attached through its
        // fenced activation, then release the guest pages after DETACH.
        if (index != 0) try detach(ctx, output, index);
    }
    try show(ctx, output, 0);
    try detach(ctx, output, 0);
    try releaseInitial(ctx, output);
    try displayResult(ctx, "activate", ctx.display.outputTransition(&output.target, 0, false));
    output.active = true;
    const info: a.DisplayPresentationInfo = .{ .flags = a.display_presentation_info_native | a.display_presentation_info_active | a.display_presentation_info_system_source,
        .head_id = head, .backend = ctx.binding.*, .display_generation = output.target.display_generation, .sequence = 2,
        .width = width, .height = height, .format = a.gfx_buffer_format_xrgb8888, .policies = 7, .buffer_count = 2, .plane_count = 1 };
    try displayResult(ctx, "presentation-info", ctx.display.presentationInfo(&info));
    log(ctx, "VIRTGPU output-active head={d} connector={d} mode={d}x{d} generation={d} resources=2 visibility=unknown", .{ head, identity.connector_id, width, height, output.target.display_generation });
}
fn close(ctx: Context, output: *Output) Error!bool {
    if (output.target.connector_id == 0) return true;
    if (output.active) {
        const rc = ctx.display.outputTransition(&output.target, 1, false);
        if (rc != a.gfx_output_ok and rc != a.gfx_output_error_stale) return error.Rejected;
        output.active = false;
    }
    if (output.displayed != null and !output.reset) {
        try command(ctx, .set_scanout, std.mem.asBytes(&wire.Scanout{ .scanout = output.target.head_id }));
        output.displayed = null;
    }
    const rc = ctx.display.outputTransition(&output.target, 2, true);
    if (rc == a.gfx_output_error_busy) return false;
    if (rc != a.gfx_output_ok and rc != a.gfx_output_error_stale) return error.Rejected;
    for (0..2) |index| if (output.created[index]) {
        try detach(ctx, output, index);
        try command(ctx, .unref, std.mem.asBytes(&wire.Resource{ .resource = output.resources[index] }));
        output.created[index] = false;
    };
    try releaseInitial(ctx, output);
    output.* = .{};
    return true;
}
pub fn reconcile(ctx: Context, info: *const wire.DisplayReply, identities: []const a.GfxOutputId, primary: u32) Error!void {
    if (!ctx.display.supportsOutputs() or !ctx.gpu.ready) return;
    for (info.modes[0..@min(identities.len, capacity)], 0..) |mode, index| {
        if (index == primary) {
            if (slots[index].primary) slots[index].target.connection_generation = identities[index].connection_generation;
            continue;
        }
        const output = &slots[index];
        const identity = identities[index];
        const same = output.active and mode.enabled != 0 and output.width == mode.rectangle.width and output.height == mode.rectangle.height and
            output.target.adapter_id == identity.adapter_id and output.target.connector_id == identity.connector_id and
            output.target.device_generation == identity.device_generation and output.target.connection_generation == identity.connection_generation;
        if (same) continue;
        if (!try close(ctx, output)) continue;
        if (mode.enabled != 0) try setup(ctx, output, identity, @intCast(index), mode.rectangle.width, mode.rectangle.height);
    }
}
pub fn present(ctx: Context, job: *const a.GfxDriverJob) Error!bool {
    if (job.operation != a.gfx_queue_operation_present or job.display_target.connector_id == 0 or job.display_target.head_id >= slots.len) return false;
    const output = &slots[job.display_target.head_id];
    if (!output.active or !std.meta.eql(output.target, job.display_target) or job.source_offset != 0 or job.target_offset != 0 or
        job.target_buffer.id != 0 or job.byte_length != @as(u64, output.width) * 4 or job.row_count != output.height or
        job.source_pitch < job.byte_length or output.source != null) return false;
    const index: u1 = if (output.displayed) |current| current ^ 1 else 0;
    output.source = job.fence;
    errdefer {
        if (ctx.gpu.ready) detach(ctx, output, index) catch {};
        if (!output.attached[index]) output.source = null;
    }
    try attach(ctx, output, index, job.source_pitch, job.fence);
    try transfer(ctx, output, index);
    try show(ctx, output, index);
    try detach(ctx, output, index);
    output.source = null; output.frames += 1;
    if (output.frames <= 3) log(ctx, "VIRTGPU output-frame head={d} frame={d} fence={d}:{d} source-detached=yes", .{ output.target.head_id, output.frames, job.fence.timeline, job.fence.point });
    return true;
}
pub fn sourceHeld(fence: a.GfxFence) bool {
    for (&slots) |*output| if (output.source) |source| if (std.meta.eql(source, fence)) return true;
    return false;
}
pub fn resetAcknowledged(ctx: Context) void {
    for (&slots) |*output| if (output.target.connector_id != 0) {
        if (!output.primary) _ = ctx.display.outputTransition(&output.target, 1, false);
        output.active = false; output.displayed = null; output.created = @splat(false); output.attached = @splat(false);
        output.source = null; output.reset = true;
    };
}
pub fn releaseAfterReset(ctx: Context) bool {
    var complete = true;
    for (&slots) |*output| if (output.target.connector_id != 0) {
        if (!output.reset) return false;
        releaseInitial(ctx, output) catch return false;
        if (output.primary) { output.* = .{}; continue; }
        // Queue-owned source leases retire separately through the existing
        // backend reset/unregister path. This catalog owns no such lease.
        const rc = ctx.display.outputTransition(&output.target, 2, true);
        if (rc == a.gfx_output_error_busy) { complete = false; continue; }
        if (rc != a.gfx_output_ok and rc != a.gfx_output_error_stale) return false;
        output.* = .{};
    };
    return complete;
}
fn log(ctx: Context, comptime format: []const u8, args: anytype) void {
    var bytes: [256]u8 = undefined;
    const message = std.fmt.bufPrintZ(&bytes, format, args) catch return;
    r4os.r4dev.DriverContext.init(ctx.gpu.api.?).logInfo(message.ptr);
}
