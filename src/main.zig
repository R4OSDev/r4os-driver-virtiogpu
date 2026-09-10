const std = @import("std");
const r4os = @import("r4os");
const wire = @import("wire.zig");
const transport = @import("transport.zig");
const native = @import("native.zig");
var device: transport.Transport = .{};
var driver_api: ?*const r4os.abi.DriverApi = null;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("virtgpu_init", "virtgpu_shutdown"));
}

export fn virtgpu_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) return -1;
    driver_api = api;
    const mode = std.mem.span(ctx.getOption("VIRTGPU", "mode"));
    if (!std.ascii.eqlIgnoreCase(mode, "probe")) {
        const fault = std.ascii.eqlIgnoreCase(mode, "timeout");
        if (mode.len != 0 and !fault and !std.ascii.eqlIgnoreCase(mode, "native")) return -2;
        native.init(api, &device, fault) catch |err| {
            log("VIRTGPU native: error={s} phase={s} status={d}", .{ @errorName(err), @tagName(device.phase), device.last_status });
            _ = native.shutdown();
            return -3;
        };
        return 0;
    }
    probe(api) catch |err| {
        log("VIRTGPU transport probe: error={s} phase={s} status={d} address={x}", .{ @errorName(err), @tagName(device.phase), device.last_status, device.last_address });
        // Failed-load shutdown must prove reset before the loader can reclaim
        // DMA/MMIO. Its nonzero result retains the module and its resources.
        return -3;
    };
    if (!device.close()) return -4;
    ctx.logInfo("VIRTGPU transport probe: OK queue=control fenced=yes scanout=untouched reset=acknowledged");
    return 0;
}

export fn virtgpu_shutdown() callconv(.c) i32 {
    if (!native.shutdown()) return -1;
    return if (device.close()) 0 else -1;
}

fn probe(api: *const r4os.abi.DriverApi) transport.Error!void {
    try device.discover(api);
    try device.initialize(true);
    var info: wire.DisplayReply = .{};
    try device.getDisplayInfo(&info);
    log("VIRTGPU transport: pci={x}:{x}.{x} features={x} scanouts={d}", .{
        device.pci.bus, device.pci.device, device.pci.function, device.accepted_features, device.num_scanouts,
    });
    for (info.modes[0..device.num_scanouts], 0..) |mode, index| {
        if (mode.enabled == 0) continue;
        log("VIRTGPU scanout={d} host-size={d}x{d}", .{ index, mode.rectangle.width, mode.rectangle.height });
        if (device.accepted_features & wire.feature_edid != 0) {
            var edid: wire.EdidReply = .{};
            try device.getEdid(@intCast(index), &edid);
            log("VIRTGPU scanout={d} edid-bytes={d}", .{ index, edid.length });
        }
    }
}

fn log(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, format, args) catch return;
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return);
    ctx.logInfo(text.ptr);
}
