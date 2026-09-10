// Original R4OS implementation of protocol facts from OASIS Virtio 1.3,
// sections 2/4.1/5.7. No Linux or QEMU implementation is incorporated.
const std = @import("std");

pub const vendor: u16 = 0x1af4;
pub const device: u16 = 0x1050;
pub const feature_version_1: u64 = @as(u64, 1) << 32;
pub const feature_edid: u64 = 1 << 1;
pub const max_scanouts = 16;
pub const max_edid = 1024;
pub const fence_flag: u32 = 1;
pub const format_b8g8r8x8: u32 = 2;

pub const Command = enum(u32) {
    display_info = 0x0100,
    create_2d = 0x0101,
    unref = 0x0102,
    set_scanout = 0x0103,
    flush = 0x0104,
    transfer_2d = 0x0105,
    attach_backing = 0x0106,
    detach_backing = 0x0107,
    get_edid = 0x010a,
};
pub const Response = enum(u32) {
    ok = 0x1100,
    display_info = 0x1101,
    edid = 0x1104,
    unspecified = 0x1200,
    out_of_memory = 0x1201,
    invalid_scanout = 0x1202,
    invalid_resource = 0x1203,
    invalid_context = 0x1204,
    invalid_parameter = 0x1205,

    pub fn failed(self: Response) bool {
        return @intFromEnum(self) >= 0x1200;
    }
};
pub const Header = extern struct {
    kind: u32 = 0,
    flags: u32 = fence_flag,
    fence: u64 = 0,
    context: u32 = 0,
    ring: u8 = 0,
    padding: [3]u8 = .{0} ** 3,

    pub fn request(command: Command, serial: u64) Header {
        return .{ .kind = @intFromEnum(command), .fence = serial };
    }
};
pub const Rect = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn fits(self: Rect, width: u32, height: u32) bool {
        return self.width != 0 and self.height != 0 and self.x < width and
            self.y < height and self.width <= width - self.x and self.height <= height - self.y;
    }
};
pub const Create = extern struct { header: Header = .{}, resource: u32 = 0, format: u32 = format_b8g8r8x8, width: u32 = 0, height: u32 = 0 };
pub const Resource = extern struct { header: Header = .{}, resource: u32 = 0, padding: u32 = 0 };
pub const Scanout = extern struct { header: Header = .{}, rectangle: Rect = .{}, scanout: u32 = 0, resource: u32 = 0 };
pub const Flush = extern struct { header: Header = .{}, rectangle: Rect = .{}, resource: u32 = 0, padding: u32 = 0 };
pub const Transfer = extern struct { header: Header = .{}, rectangle: Rect = .{}, offset: u64 = 0, resource: u32 = 0, padding: u32 = 0 };
pub const Attach = extern struct { header: Header = .{}, resource: u32 = 0, count: u32 = 0 };
pub const Memory = extern struct { address: u64 = 0, length: u32 = 0, padding: u32 = 0 };
pub const EdidRequest = extern struct { header: Header = .{}, scanout: u32 = 0, padding: u32 = 0 };
pub const EdidReply = extern struct { header: Header = .{}, length: u32 = 0, padding: u32 = 0, data: [max_edid]u8 = .{0} ** max_edid };
pub const Mode = extern struct { rectangle: Rect = .{}, enabled: u32 = 0, flags: u32 = 0 };
pub const DisplayReply = extern struct { header: Header = .{}, modes: [max_scanouts]Mode = .{Mode{}} ** max_scanouts };
pub const Descriptor = extern struct { address: u64 = 0, length: u32 = 0, flags: u16 = 0, next: u16 = 0 };
pub const Used = extern struct { head: u32 = 0, length: u32 = 0 };
pub const Error = error{ UnsupportedFeatures, Invalid, Malformed, Stale, Busy, Exhausted };

// Only features backed by this implementation are acknowledged. In
// particular, virgl/blobs/context-init/packed-rings are never inferred.
pub fn features(offered: u64) Error!u64 {
    if (offered & feature_version_1 == 0) return error.UnsupportedFeatures;
    return offered & (feature_version_1 | feature_edid);
}

pub fn reply(bytes: []const u8, used: u32, serial: u64, expected: Response) Error!Response {
    if (serial == 0 or used < @sizeOf(Header) or used > bytes.len) return error.Malformed;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Header)]);
    if (header.fence != serial) return error.Stale;
    if (header.flags != fence_flag or header.context != 0 or header.ring != 0 or
        !std.mem.eql(u8, &header.padding, &.{ 0, 0, 0 })) return error.Malformed;
    const response = std.enums.fromInt(Response, header.kind) orelse return error.Malformed;
    if (response.failed()) return response;
    if (response != expected) return error.Malformed;
    const minimum: usize = switch (expected) {
        .ok => @sizeOf(Header),
        .display_info => @sizeOf(DisplayReply),
        .edid => @sizeOf(EdidReply),
        else => return error.Invalid,
    };
    if (used < minimum) return error.Malformed;
    return response;
}

// One command owns the shared DMA request/reply area until a validated used
// entry or acknowledged whole-device reset. Logical cancellation alone does
// not permit buffer reuse. The driver, not this model, proves reset status 0.
pub const CommandOwner = struct {
    serial: u64 = 0,
    pending: u64 = 0,
    used_index: u16 = 0,
    cancelled: bool = false,
    poisoned: bool = false,

    pub fn begin(self: *CommandOwner) Error!u64 {
        if (self.poisoned or self.pending != 0) return error.Busy;
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        self.serial += 1;
        self.pending = self.serial;
        self.cancelled = false;
        return self.serial;
    }
    pub fn cancel(self: *CommandOwner, serial: u64) Error!void {
        if (serial == 0 or serial != self.pending) return error.Stale;
        self.cancelled = true;
    }
    pub fn accept(self: *CommandOwner, index: u16, entry: Used, bytes: []const u8, expected: Response) Error!Response {
        if (self.poisoned or self.pending == 0) return error.Stale;
        if (index != self.used_index +% 1 or entry.head != 0) {
            self.poisoned = true;
            return error.Malformed;
        }
        const response = reply(bytes, entry.length, self.pending, expected) catch |err| {
            self.poisoned = true;
            return err;
        };
        self.used_index = index;
        self.pending = 0;
        return response;
    }
    pub fn resetAcknowledged(self: *CommandOwner) void {
        self.pending = 0;
        self.used_index = 0;
        self.cancelled = false;
        self.poisoned = false;
        // Fence IDs survive reset and never alias a former response.
    }
};

comptime {
    if (@sizeOf(Header) != 24 or @offsetOf(Header, "fence") != 8 or @sizeOf(Create) != 40 or
        @sizeOf(Scanout) != 48 or @sizeOf(Transfer) != 56 or @sizeOf(Memory) != 16 or
        @sizeOf(EdidReply) != 1056 or @sizeOf(DisplayReply) != 408 or @sizeOf(Descriptor) != 16)
        @compileError("Virtio 1.3 wire layout differs");
}

test "modern features and reply lengths never imply unsupported GPU capabilities" {
    const t = std.testing;
    try t.expectError(error.UnsupportedFeatures, features(0xffff_ffff));
    try t.expectEqual(feature_version_1 | feature_edid, try features(std.math.maxInt(u64)));
    var data = DisplayReply{ .header = .{ .kind = @intFromEnum(Response.display_info), .fence = 91 } };
    const bytes = std.mem.asBytes(&data);
    try t.expectError(error.Malformed, reply(bytes, 24, 91, .display_info));
    try t.expectEqual(Response.display_info, try reply(bytes, bytes.len, 91, .display_info));
    try t.expectError(error.Stale, reply(bytes, bytes.len, 90, .display_info));
    data.header.flags = 0;
    try t.expectError(error.Malformed, reply(bytes, bytes.len, 91, .display_info));
    data.header.flags = 1;
    data.header.kind = @intFromEnum(Response.out_of_memory);
    try t.expectEqual(Response.out_of_memory, try reply(bytes, 24, 91, .display_info));
    try t.expect(!Rect.fits(.{ .x = 0xffff_fff0, .width = 32, .height = 1 }, 1280, 720));
}

test "cancel and malformed DMA completion retain ownership until validated completion or reset" {
    const t = std.testing;
    var owner = CommandOwner{ .used_index = 65535 };
    const first = try owner.begin();
    try owner.cancel(first);
    try t.expectError(error.Busy, owner.begin());
    var header = Header{ .kind = @intFromEnum(Response.ok), .fence = first };
    try t.expectEqual(Response.ok, try owner.accept(0, .{ .head = 0, .length = 24 }, std.mem.asBytes(&header), .ok));
    try t.expect(owner.cancelled);
    try t.expectError(error.Stale, owner.accept(0, .{ .length = 24 }, std.mem.asBytes(&header), .ok));
    const second = try owner.begin();
    try t.expectError(error.Stale, owner.accept(1, .{ .length = 24 }, std.mem.asBytes(&header), .ok));
    try t.expect(owner.poisoned and owner.pending == second);
    try t.expectError(error.Busy, owner.begin());
    owner.resetAcknowledged();
    try t.expect(try owner.begin() > second);
    owner.resetAcknowledged();
    owner.serial = std.math.maxInt(u64);
    try t.expectError(error.Exhausted, owner.begin());
}
